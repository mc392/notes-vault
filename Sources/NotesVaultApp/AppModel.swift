import Foundation
import SwiftUI
import NotesVaultCore
import NotesVaultCrypto

/// The one object the UI talks to.
///
/// Every vault operation is funnelled through a single serial queue. That is not just
/// tidiness: the vault is append-only and two concurrent writers picking the same filename
/// would be the one way to lose a note. Serialising here means the app cannot race itself,
/// and the only remaining concurrency is between *devices*, which the file format already
/// handles by never overwriting.
@MainActor
public final class AppModel: ObservableObject {
    public enum Phase: Equatable {
        /// Working out what we have — resolving the bookmark, checking for a vault.
        case starting
        /// No folder chosen yet, or the chosen one is gone.
        case chooseFolder
        /// A folder is chosen but has no vault in it.
        case createVault
        /// A vault is there and needs unlocking.
        case locked
        /// A vault has just been created and the recovery key has not been written down yet.
        case revealRecoveryKey
        case unlocked
    }

    @Published public private(set) var phase: Phase = .starting
    @Published public private(set) var index = VaultIndex.empty
    @Published public private(set) var issues: [VaultIssue] = []
    @Published public private(set) var folderName: String?
    @Published public private(set) var busyMessage: String?
    @Published public var errorMessage: String?
    @Published public private(set) var pendingRecoveryKey: RecoveryKey?
    @Published public var retentionPolicy = RetentionPolicy.bacpDefault {
        didSet { persistRetentionPolicy() }
    }
    /// Which extra fields the note screen offers. A device setting, like the retention
    /// policy — turning a field on never writes anything to the vault.
    @Published public var noteFields = NoteFieldSettings.default {
        didSet { persistNoteFields() }
    }

    /// The name this device writes into every note it creates.
    public var deviceDisplayName: String { DeviceIdentity.current }

    public var biometricsAvailable: Bool { KeychainStore.biometricsAvailable }
    public var biometricsEnrolled: Bool {
        guard let vaultID else { return false }
        return KeychainStore.hasStoredPassphrase(vaultID: vaultID)
    }

    private var files: FileSystemVaultStore?
    private var session: VaultSession?
    private var store: VaultStore?
    private var indexStore: IndexStore?
    private var vaultID: String?
    /// Autosaved, unsaved notes. Created once and kept for the life of the app: it holds
    /// no vault state of its own, and unlike the index it must survive a lock — the drafts
    /// are encrypted with the index key, which survives one too.
    private let draftStore = DraftStore()

    private static let queue = DispatchQueue(label: "com.charlottebloor.groundworknotes.vault", qos: .userInitiated)
    private static let retentionKey = "retention.policy"
    private static let noteFieldsKey = "note.fields"

    public init() {
        loadRetentionPolicy()
        loadNoteFields()
    }

    // MARK: - Lifecycle

    public func start() async {
        phase = .starting
        do {
            guard let url = try VaultBookmark.resolve() else {
                phase = .chooseFolder
                return
            }
            try attach(to: url, rememberBookmark: false)
        } catch {
            report(error)
            phase = .chooseFolder
        }
    }

    /// Called with the URL the document picker returned.
    public func chooseFolder(_ url: URL) {
        do {
            try attach(to: url, rememberBookmark: true)
        } catch {
            report(error)
            phase = .chooseFolder
        }
    }

    private func attach(to url: URL, rememberBookmark: Bool) throws {
        let fileStore = try FileSystemVaultStore(root: url)

        // The picker will happily walk into a vault's own encrypted folders, which look
        // empty and reasonable from the inside. Creating a vault in one of those buries it
        // where the counsellor will never look, so refuse before anything is written — and
        // before the folder is remembered as theirs.
        let verdict = VaultFolderCheck.assess(
            folderName: url.lastPathComponent,
            pathComponents: url.pathComponents,
            contents: (try? fileStore.contentsOfDirectory(at: [])) ?? []
        )
        if case let .insideAnotherVault(reason) = verdict {
            throw VaultError.folderInsideAnotherVault(url.lastPathComponent, reason: reason)
        }

        if rememberBookmark {
            try VaultBookmark.store(url)
        }
        files = fileStore
        folderName = url.lastPathComponent
        phase = verdict == .existingVault ? .locked : .createVault
    }

    public func forgetFolder() {
        lock()
        if let files, let vaultID = Self.readVaultID(from: files) {
            KeychainStore.forget(vaultID: vaultID)
        }
        files?.relinquish()
        VaultBookmark.clear()
        files = nil
        folderName = nil
        phase = .chooseFolder
    }

    /// The vault's `jti`, read the same non-secret way `unlockWithBiometrics` does — the
    /// config is signed rather than encrypted, so this needs no key. Nil if the folder has
    /// no vault in it or the read fails, in which case there is nothing to forget.
    private static func readVaultID(from files: FileSystemVaultStore) -> String? {
        guard let configData = try? files.read(at: [VaultLayout.vaultConfigFilename]),
              let configuration = try? VaultBootstrap.decodeConfiguration(configData) else { return nil }
        return configuration.jti
    }

    // MARK: - Creating and unlocking

    public func createVault(passphrase: String) async {
        guard let files else { return }
        await run("Creating the vault…") {
            try VaultBootstrap.createVault(in: files, passphrase: passphrase)
        } then: { [weak self] created in
            guard let self else { return }
            self.adopt(session: created.session, files: files)
            self.pendingRecoveryKey = created.recoveryKey
            self.phase = .revealRecoveryKey
        }
    }

    /// The counsellor has confirmed they have written the recovery key down. It is dropped
    /// from memory here and there is no way back to it — which is the point.
    public func acknowledgeRecoveryKey() {
        pendingRecoveryKey = nil
        phase = .unlocked
        Task { await refreshIndex(force: true) }
    }

    public func unlock(passphrase: String, rememberWithBiometrics: Bool = false) async {
        guard let files else { return }
        await run("Unlocking…") {
            try VaultBootstrap.open(files, passphrase: passphrase)
        } then: { [weak self] session in
            guard let self else { return }
            self.adopt(session: session, files: files)
            if rememberWithBiometrics {
                KeychainStore.storePassphrase(passphrase, vaultID: session.configuration.jti)
            }
            self.phase = .unlocked
            Task { await self.refreshIndex(force: false) }
        }
    }

    /// Unlocks using the passphrase held behind Face ID / Touch ID.
    ///
    /// Needs the vault's identifier before it can find the keychain item, and that lives in
    /// the vault config — which is readable without the key, because it is signed rather
    /// than encrypted.
    public func unlockWithBiometrics() async {
        guard let files else { return }
        guard let configData = try? files.read(at: [VaultLayout.vaultConfigFilename]),
              let configuration = try? VaultBootstrap.decodeConfiguration(configData) else {
            errorMessage = "The vault folder couldn't be read — check it's still where you left it."
            return
        }

        switch KeychainStore.passphrase(vaultID: configuration.jti, reason: "Unlock your clinical notes") {
        case .value(let passphrase):
            await unlock(passphrase: passphrase)
        case .cancelled:
            // Declining is a normal choice — the passphrase field is still right there.
            break
        case .unavailable:
            errorMessage = "Face ID unlock isn't set up any more on this device — use your passphrase, then turn it back on from the unlock screen."
            KeychainStore.remove(.passphrase, vaultID: configuration.jti)
        }
    }

    /// Drops the key and everything derived from it. Folder access is kept — it is
    /// permission to a folder, not to its contents, and re-acquiring it on every unlock
    /// would mean re-prompting for a folder the counsellor already chose.
    ///
    /// Deliberately does *not* call `files.relinquish()`: unlocking again reuses the same
    /// `FileSystemVaultStore`, and there is no re-acquire path — relinquishing here would
    /// leave a locked vault unable to unlock again without choosing the folder afresh.
    /// `relinquish()` is only called from `forgetFolder()`, where the store is discarded too.
    public func lock() {
        session = nil
        store = nil
        index = .empty
        issues = []
        if phase == .unlocked { phase = .locked }
    }

    private func adopt(session: VaultSession, files: FileSystemVaultStore) {
        self.session = session
        self.vaultID = session.configuration.jti
        self.store = VaultStore(engine: session.engine, files: files, deviceName: DeviceIdentity.current)
        self.indexStore = IndexStore(vaultID: session.configuration.jti)
    }

    // MARK: - Index

    /// Loads the cached index, then rebuilds from the vault.
    ///
    /// Cache first so the list is on screen immediately, rebuild always so it is right —
    /// another device may have added notes since this one last looked, and there is no
    /// server to tell us. The rebuild replaces the cache when it finishes.
    public func refreshIndex(force: Bool) async {
        guard let store else { return }

        if !force, let cached = indexStore?.load() {
            index = cached
        }

        await run("Reading the vault…") {
            try store.rebuildIndex()
        } then: { [weak self] result in
            guard let self else { return }
            self.index = result.index
            self.issues = result.issues
            self.indexStore?.save(result.index)
        }
    }

    // MARK: - Notes

    public func addNote(
        client: ClientCode,
        sessionDate: Date,
        template: NoteTemplate,
        body: String,
        fieldValues: [String: String] = [:],
        supersedes: NoteID? = nil
    ) async {
        guard let store else { return }
        let note = NoteRecord(
            client: client,
            session: sessionDate,
            written: Date(),
            device: store.deviceName,
            template: template,
            supersedes: supersedes,
            extraHeaders: noteFields.headers(from: fieldValues),
            body: body
        )
        await run("Saving…") {
            _ = try store.write(note: note)
        } then: { [weak self] _ in
            Task { await self?.refreshIndex(force: true) }
        }
    }

    public func readNote(_ entry: NoteIndexEntry) async -> NoteRecord? {
        guard let store else { return nil }
        var result: NoteRecord?
        await run(nil) {
            try store.readNote(client: entry.client, filename: entry.filename)
        } then: { note in
            result = note
        }
        return result
    }

    // MARK: - Drafts

    /// Everything the editor does with a half-written note goes through here, so views
    /// never reach into the crypto module themselves — and so all three calls can be
    /// no-ops the moment the vault is locked.
    ///
    /// Saving is fire-and-forget onto the vault queue rather than awaited: it happens as
    /// the counsellor types, and a draft is never worth a pause between two keystrokes.
    /// The queue is serial, so a save enqueued just before a clear still lands first and
    /// the clear still wins.
    public func saveDraft(_ draft: NoteDraft) {
        guard store != nil, let vaultID, let draftStore else { return }
        Self.queue.async { draftStore.save(draft, vaultID: vaultID) }
    }

    public func loadDraft(client: ClientCode, correcting: NoteID?) async -> NoteDraft? {
        guard store != nil, let vaultID, let draftStore else { return nil }
        var draft: NoteDraft?
        await run(nil) {
            draftStore.load(vaultID: vaultID, client: client, correcting: correcting)
        } then: { found in
            draft = found
        }
        return draft
    }

    public func clearDraft(client: ClientCode, correcting: NoteID?) {
        guard store != nil, let vaultID, let draftStore else { return }
        Self.queue.async { draftStore.clear(vaultID: vaultID, client: client, correcting: correcting) }
    }

    // MARK: - Clients

    public func createClient(_ code: ClientCode) async {
        guard let store else { return }
        let event = ClientMetadataEvent(
            client: code,
            device: store.deviceName,
            status: .active,
            retentionBasis: .adult
        )
        await run("Adding \(code)…") {
            try store.write(event: event)
        } then: { [weak self] _ in
            Task { await self?.refreshIndex(force: true) }
        }
    }

    public func updateClient(
        _ code: ClientCode,
        status: ClientStatus,
        retentionBasis: RetentionBasis,
        lastContactOverride: Date?,
        schedule: SessionSchedule?,
        seriesStart: Date?
    ) async {
        guard let store else { return }
        let event = ClientMetadataEvent(
            client: code,
            device: store.deviceName,
            status: status,
            retentionBasis: retentionBasis,
            lastContactOverride: lastContactOverride,
            schedule: schedule,
            seriesStart: seriesStart
        )
        await run("Saving…") {
            try store.write(event: event)
        } then: { [weak self] _ in
            Task { await self?.refreshIndex(force: true) }
        }
    }

    // MARK: - Predicted sessions

    /// The sessions this client should have had since their last note, and has not.
    ///
    /// Computed entirely from the vault — the notes already stored and the cadence in the
    /// client's metadata — so it is right on a Mac that has never been in contact with
    /// GroundWork, as long as iCloud has brought the vault across. See
    /// `docs/schedule-sync.md`.
    public func predictedSessions(for code: ClientCode) -> [Date] {
        SessionPrediction.expected(for: code, in: index)
    }

    // MARK: - Schedule sync

    public var rosterFileName: String? { RosterBookmark.storedDisplayName }
    public var rosterLastSync: Date? { RosterBookmark.lastSync }

    /// Called with the file the picker returned. Remembers it, then reads it — choosing the
    /// file and syncing it are one action as far as the counsellor is concerned.
    public func chooseRosterFile(_ url: URL) async -> RosterSyncPlan? {
        do {
            try RosterBookmark.store(url)
        } catch {
            report(error)
            return nil
        }
        return await planScheduleSync()
    }

    public func forgetRosterFile() {
        RosterBookmark.clear()
        objectWillChange.send()
    }

    /// Reads the roster and works out what would change. Writes nothing.
    ///
    /// Split from `applyScheduleSync` on purpose: a sync can end a client, which starts a
    /// retention clock, so it is shown before it happens rather than reported afterwards.
    public func planScheduleSync() async -> RosterSyncPlan? {
        guard let store else { return nil }
        let url: URL?
        do {
            url = try RosterBookmark.resolve()
        } catch {
            report(error)
            return nil
        }
        guard let url else { return nil }

        let device = store.deviceName
        var plan: RosterSyncPlan?
        await run("Reading GroundWork's schedules…") { () -> RosterSyncPlan in
            let roster = try ScheduleRoster.parse(try RosterBookmark.read(url))
            let current = try store.allCurrentMetadata()
            var built = RosterSync.plan(
                roster: roster,
                existing: current.events,
                knownClients: Array(current.events.keys),
                device: device
            )
            if !current.issues.isEmpty {
                built = RosterSyncPlan(
                    changes: built.changes,
                    unchanged: built.unchanged,
                    untouched: built.untouched,
                    issues: built.issues + current.issues
                )
            }
            return built
        } then: { result in
            plan = result
        }
        return plan
    }

    /// Writes an approved plan. One metadata event per client that actually changed.
    @discardableResult
    public func applyScheduleSync(_ plan: RosterSyncPlan) async -> Int {
        guard let store, !plan.isEmpty else {
            RosterBookmark.lastSync = Date()
            return 0
        }
        var written = 0

        await run("Updating \(plan.changes.count) client\(plan.changes.count == 1 ? "" : "s")…") { () -> Int in
            var count = 0
            for change in plan.changes {
                try store.write(event: change.event)
                count += 1
            }
            return count
        } then: { count in
            written = count
        }

        if written > 0 {
            RosterBookmark.lastSync = Date()
            await refreshIndex(force: true)
        }
        return written
    }

    // MARK: - Retention

    public var retentionReview: [RetentionAssessment] {
        RetentionEngine.review(clients: index.clients, policy: retentionPolicy)
    }

    public var retentionNeedingAttention: [RetentionAssessment] {
        retentionReview.filter(\.needsAttention)
    }

    /// Destroys every note for one client. Only ever reached through `DestroyClientView`,
    /// which requires the code to be typed out in full first.
    public func destroy(client code: ClientCode) async {
        guard let store else { return }
        // A destroyed client whose half-written note survived in Application Support would
        // make a liar of the destruction promise, so the drafts go with the notes.
        let drafts = draftStore
        let vaultID = self.vaultID
        await run("Removing \(code)…") {
            try store.destroyEverything(for: code)
            if let drafts, let vaultID { drafts.clearAll(vaultID: vaultID) }
        } then: { [weak self] _ in
            Task { await self?.refreshIndex(force: true) }
        }
    }

    // MARK: - Import

    /// Codes already in this vault, so the import screen can offer an existing client
    /// rather than inventing a second code for somebody who is already here.
    public var existingClientCodes: [ClientCode] { index.clients.map(\.code) }

    /// Writes an approved import plan into the vault.
    ///
    /// Goes through the same serial queue as every other write, so an import cannot race
    /// a note being saved on the other tab — and through `ImportRunner`, which uses the
    /// ordinary `VaultStore` write path rather than one of its own.
    public func runImport(
        plan: ImportPlan,
        progress: @escaping (Int, Int) -> Void
    ) async -> ImportReport? {
        guard let store else { return nil }
        let existing = Set(index.clients.map(\.code))
        var report: ImportReport?

        // No busy message: the import screen shows its own progress, note by note, and a
        // modal spinner over the top of it would hide the one thing worth watching.
        await run(nil) { () -> ImportReport in
            ImportRunner.run(plan: plan, store: store, existingClients: existing) { step in
                progress(step.completed, step.total)
            }
        } then: { result in
            report = result
        }

        if report != nil {
            await refreshIndex(force: true)
        }
        return report
    }

    // MARK: - Export

    /// Writes the whole vault out as plain files into a folder the user picked.
    public func export(to destination: URL) async -> Int {
        guard let store else { return 0 }
        var written = 0

        await run("Exporting…") { () -> (Int, [VaultIssue]) in
            let accessed = destination.startAccessingSecurityScopedResource()
            defer { if accessed { destination.stopAccessingSecurityScopedResource() } }

            let root = destination.appendingPathComponent("GroundWork Notes Export \(VaultDate.filenameStamp(Date()))", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            var count = 0
            let issues = try store.exportPlaintext { components, data in
                var url = root
                for component in components.dropLast() {
                    url = url.appendingPathComponent(component, isDirectory: true)
                }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try data.write(to: url.appendingPathComponent(components[components.count - 1]), options: .atomic)
                count += 1
            }
            return (count, issues)
        } then: { [weak self] result in
            written = result.0
            self?.issues = result.1
        }
        return written
    }

    // MARK: - Passphrase

    public func changePassphrase(current: String, new: String) async -> Bool {
        guard let files else { return false }
        var succeeded = false
        await run("Changing the passphrase…") {
            try VaultBootstrap.changePassphrase(in: files, current: current, new: new)
        } then: { _ in
            succeeded = true
        }
        if succeeded, let vaultID, KeychainStore.hasStoredPassphrase(vaultID: vaultID) {
            KeychainStore.storePassphrase(new, vaultID: vaultID)
        }
        return succeeded
    }

    public func resetPassphrase(recoveryKey: RecoveryKey, newPassphrase: String) async -> Bool {
        guard let files else { return false }
        var succeeded = false
        await run("Restoring access…") {
            try VaultBootstrap.resetPassphrase(in: files, recoveryKey: recoveryKey, newPassphrase: newPassphrase)
        } then: { _ in
            succeeded = true
        }
        return succeeded
    }

    public func regenerateRecoveryKey(passphrase: String) async {
        guard let files else { return }
        await run("Issuing a new recovery key…") {
            try VaultBootstrap.regenerateRecoveryKey(in: files, passphrase: passphrase)
        } then: { [weak self] key in
            self?.pendingRecoveryKey = key
        }
    }

    public func dismissRecoveryKey() {
        pendingRecoveryKey = nil
    }

    // MARK: - Plumbing

    /// Runs vault work off the main thread on the shared serial queue, with a busy message
    /// and one error path. Errors surface as `errorMessage`; nothing is swallowed.
    private func run<T>(
        _ message: String?,
        _ work: @escaping () throws -> T,
        then handle: @escaping (T) -> Void
    ) async {
        busyMessage = message
        defer { busyMessage = nil }
        do {
            let value: T = try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    continuation.resume(with: Result { try work() })
                }
            }
            handle(value)
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        if let vaultError = error as? VaultError {
            errorMessage = vaultError.errorDescription
        } else {
            errorMessage = error.localizedDescription
        }
    }

    private func loadRetentionPolicy() {
        guard let data = UserDefaults.standard.data(forKey: Self.retentionKey),
              let stored = try? JSONDecoder().decode(RetentionPolicy.self, from: data) else { return }
        retentionPolicy = stored
    }

    private func persistRetentionPolicy() {
        guard let data = try? JSONEncoder().encode(retentionPolicy) else { return }
        UserDefaults.standard.set(data, forKey: Self.retentionKey)
    }

    private func loadNoteFields() {
        guard let data = UserDefaults.standard.data(forKey: Self.noteFieldsKey),
              let stored = try? JSONDecoder().decode(NoteFieldSettings.self, from: data) else { return }
        // Normalised so a built-in added in a later version appears for someone who has
        // already saved their settings once.
        noteFields = stored.normalised()
    }

    private func persistNoteFields() {
        guard let data = try? JSONEncoder().encode(noteFields) else { return }
        UserDefaults.standard.set(data, forKey: Self.noteFieldsKey)
    }
}
