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
        if rememberBookmark {
            try VaultBookmark.store(url)
        }
        files = fileStore
        folderName = url.lastPathComponent
        phase = VaultBootstrap.isVault(fileStore) ? .locked : .createVault
    }

    public func forgetFolder() {
        lock()
        VaultBookmark.clear()
        files = nil
        folderName = nil
        phase = .chooseFolder
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
              let configuration = try? VaultBootstrap.decodeConfiguration(configData),
              let passphrase = KeychainStore.passphrase(
                vaultID: configuration.jti,
                reason: "Unlock your clinical notes"
              ) else { return }
        await unlock(passphrase: passphrase)
    }

    /// Drops the key and everything derived from it. Folder access is kept — it is
    /// permission to a folder, not to its contents, and re-acquiring it on every unlock
    /// would mean re-prompting for a folder the counsellor already chose.
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
        lastContactOverride: Date?
    ) async {
        guard let store else { return }
        let event = ClientMetadataEvent(
            client: code,
            device: store.deviceName,
            status: status,
            retentionBasis: retentionBasis,
            lastContactOverride: lastContactOverride
        )
        await run("Saving…") {
            try store.write(event: event)
        } then: { [weak self] _ in
            Task { await self?.refreshIndex(force: true) }
        }
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
        await run("Removing \(code)…") {
            try store.destroyEverything(for: code)
        } then: { [weak self] _ in
            Task { await self?.refreshIndex(force: true) }
        }
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
