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
///
/// Split across files by area, because at a thousand lines nobody could hold it in their
/// head. This file is the state, the lifecycle and the plumbing; the rest are extensions:
///
/// - `AppModel+Access`: unlocking, the checks, the passphrase and the recovery key;
/// - `AppModel+Notes`: the index, notes, drafts, clients and predicted sessions;
/// - `AppModel+Sync`: GroundWork's schedule file;
/// - `AppModel+Transfer`: import, export and destruction;
/// - `AppModel+Settings`: the device settings and where they are kept.
///
/// Swift only lets an extension in another file see what is at least `internal`, so the
/// stored state below is `internal` rather than `private`. The app is one module and
/// nothing outside it can see any of this either way.
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

    /// Why the vault is locked, which is the only thing that makes the unlock screen say
    /// anything other than "Unlock". A failed check has to look different from a quiet
    /// timeout, or a counsellor cannot tell "you left it a while" from "somebody tried".
    public enum LockReason: Equatable, Sendable {
        /// Locked on purpose, or never unlocked yet.
        case manual
        /// The app was away long enough that the key was dropped.
        case away
        /// Face ID, Touch ID or the passcode was asked for and did not pass.
        case checkFailed
        /// The device has no biometry and no passcode, so it cannot be asked at all.
        case checkUnavailable

        /// Whether the unlock screen may offer — and start — the biometric unlock.
        ///
        /// After a failed check it may not: the whole point of failing is that the next way
        /// in is the passphrase, and offering the same check again would make the failure
        /// cost nothing.
        public var allowsBiometricUnlock: Bool {
            self == .manual || self == .away
        }
    }

    @Published public internal(set) var phase: Phase = .starting
    @Published public internal(set) var lockReason: LockReason = .manual
    /// When the last check passed, when the app went away, whether a check is on screen,
    /// and whether the shield is up. The rules live in `PresenceTracker`, where they are
    /// tested; `AppModel+Access` asks the device and does what it says.
    @Published var presence = PresenceTracker()
    @Published public internal(set) var index = VaultIndex.empty {
        didSet { recomputeDerived() }
    }
    @Published public internal(set) var issues: [VaultIssue] = []
    @Published public internal(set) var folderName: String?
    @Published public internal(set) var busyMessage: String?
    @Published public var errorMessage: String?
    @Published public internal(set) var pendingRecoveryKey: RecoveryKey?
    @Published public var retentionPolicy = RetentionPolicy.bacpDefault {
        didSet {
            Self.saveSetting(retentionPolicy, key: Self.retentionKey)
            recomputeRetention()
        }
    }
    /// Which extra fields the note screen offers. A device setting, like the retention
    /// policy — turning a field on never writes anything to the vault.
    @Published public var noteFields = NoteFieldSettings.default {
        didSet { Self.saveSetting(noteFields, key: Self.noteFieldsKey) }
    }
    /// The templates the note screen offers, built-in and the counsellor's own. A device
    /// setting for the same reason as the fields: writing one never touches the vault.
    @Published public var noteTemplates = NoteTemplateSettings.default {
        didSet { Self.saveSetting(noteTemplates, key: Self.noteTemplatesKey) }
    }
    /// When the app asks for a check. Changed through `setReopenGrace`, which asks for one
    /// first — a lock setting anybody can loosen is not a lock setting.
    @Published public internal(set) var lockPolicy = LockPolicy.default

    /// Whether this device holds the passphrase behind Face ID for the open vault.
    ///
    /// Stored rather than computed, and this is not a performance question. It is read from
    /// screens' `body`, which SwiftUI runs again whenever anything on that screen changes —
    /// so a computed property here is a keychain query on every redraw, against an item the
    /// keychain guards with a check. One stale reading of this is a wrong caption; one
    /// keychain query too many is a Face ID prompt nobody asked for, in a loop as long as
    /// the screen keeps redrawing. It is refreshed at the moments it can change.
    @Published public internal(set) var biometricsEnrolled = false

    // MARK: - Worked out from the index

    /// Every client's outstanding sessions, worked out once when the index or the day
    /// changes rather than on every redraw of every screen that shows a count.
    @Published public private(set) var outstanding: [ClientCode: [PredictedSession]] = [:]
    /// The retention review, likewise: the badge on the tab bar used to run the whole
    /// review every time the main screen redrew.
    @Published public private(set) var retentionReview: [RetentionAssessment] = []

    public var retentionNeedingAttention: [RetentionAssessment] {
        retentionReview.filter(\.needsAttention)
    }

    /// Both depend on today's date as well as on the index, so this also runs whenever the
    /// app comes back on screen — a list left open overnight must not show yesterday's.
    func recomputeDerived() {
        outstanding = SessionPrediction.expectedForEveryClient(in: index)
        recomputeRetention()
    }

    private func recomputeRetention() {
        retentionReview = RetentionEngine.review(clients: index.clients, policy: retentionPolicy)
    }

    // MARK: - Vault state

    var files: FileSystemVaultStore?
    var session: VaultSession?
    var store: VaultStore?
    var indexStore: IndexStore?
    /// The open folder's vault identifier. Read when the folder is attached — before any
    /// unlock — because it is what finds this vault's Face ID item on a cold launch.
    var vaultID: String?
    /// Autosaved, unsaved notes. Created once and kept for the life of the app: it holds
    /// no vault state of its own, and unlike the index it must survive a lock — the drafts
    /// are encrypted with the index key, which survives one too.
    let draftStore = DraftStore()
    /// Revoked by every lock and every new session. See `run`.
    var sessionToken = SessionToken()
    /// A reissued recovery key waiting to be typed back before it is written. See
    /// `AppModel+Access`.
    var pendingReissue: PreparedRecoveryKey?

    static let queue = DispatchQueue(label: "com.charlottebloor.groundworknotes.vault", qos: .userInitiated)

    public init() {
        loadSettings()
        recomputeDerived()
    }

    // MARK: - Lifecycle

    public func start() async {
        phase = .starting
        // Before anything else touches the vault, so there is nothing of this run's to
        // sweep up by mistake.
        await run(nil, sessionBound: false) {
            PlaintextScratch.sweepLeftovers()
        } then: { _ in }

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
        // Read now, not at the first unlock. It used to be set only by an unlock, so on a
        // cold launch the app did not know which keychain item was this vault's: the
        // unlock screen never offered Face ID and the launch never started it, and the
        // biometric unlock only ever worked after locking a vault already opened that run.
        vaultID = verdict == .existingVault ? Self.readVaultID(from: fileStore) : nil
        refreshBiometricsEnrolled()
        phase = verdict == .existingVault ? .locked : .createVault
    }

    public func forgetFolder() {
        lock()
        let forgotten = vaultID ?? files.flatMap(Self.readVaultID)
        if let forgotten {
            KeychainStore.forget(vaultID: forgotten)
            // The index cache and any drafts are ciphertext under the key just deleted, so
            // they are unreadable already — but "forgets this vault" should leave nothing
            // of it behind, readable or not.
            IndexStore(vaultID: forgotten)?.discard()
            if let draftStore {
                Self.queue.async { draftStore.clearAll(vaultID: forgotten) }
            }
        }
        files?.relinquish()
        VaultBookmark.clear()
        files = nil
        indexStore = nil
        vaultID = nil
        folderName = nil
        phase = .chooseFolder
        refreshBiometricsEnrolled()
    }

    /// The vault's `jti`, read without the key — the config is signed rather than
    /// encrypted. Nil if the folder has no vault in it or the read fails.
    static func readVaultID(from files: FileSystemVaultStore) -> String? {
        guard let configData = try? files.read(at: [VaultLayout.vaultConfigFilename]),
              let configuration = try? VaultBootstrap.decodeConfiguration(configData) else { return nil }
        return configuration.jti
    }

    func refreshBiometricsEnrolled() {
        guard let vaultID else {
            biometricsEnrolled = false
            return
        }
        biometricsEnrolled = KeychainStore.hasStoredPassphrase(vaultID: vaultID)
    }

    // MARK: - Locking

    /// Drops the key and everything derived from it. Folder access is kept — it is
    /// permission to a folder, not to its contents, and re-acquiring it on every unlock
    /// would mean re-prompting for a folder the counsellor already chose.
    ///
    /// Deliberately does *not* call `files.relinquish()`: unlocking again reuses the same
    /// `FileSystemVaultStore`, and there is no re-acquire path — relinquishing here would
    /// leave a locked vault unable to unlock again without choosing the folder afresh.
    /// `relinquish()` is only called from `forgetFolder()`, where the store is discarded too.
    public func lock(reason: LockReason = .manual) {
        // First, so that anything still running for the session being closed — a rebuild,
        // an import, a sync — stops, and anything that finishes anyway is thrown away
        // rather than putting the client list back into a locked app.
        sessionToken.revoke()
        sessionToken = SessionToken()

        lockReason = reason
        presence.forgetCheck()
        session = nil
        store = nil
        index = .empty
        issues = []
        // A reissued key that was never typed back goes too. Nothing is lost by it: the
        // key was never written, so the old one is still the one that works.
        pendingRecoveryKey = nil
        pendingReissue = nil
        if phase == .unlocked { phase = .locked }
        // The vault identifier survives a lock, so the unlock screen still knows whether it
        // may offer the Face ID button — but the item itself may have been removed by a
        // failed check, so this is asked again rather than assumed.
        refreshBiometricsEnrolled()
    }

    func adopt(session: VaultSession, files: FileSystemVaultStore) {
        sessionToken.revoke()
        sessionToken = SessionToken()
        self.session = session
        self.vaultID = session.configuration.jti
        self.store = VaultStore(engine: session.engine, files: files, deviceName: DeviceIdentity.current)
        self.indexStore = IndexStore(vaultID: session.configuration.jti)
        refreshBiometricsEnrolled()
    }

    // MARK: - Plumbing

    /// Runs vault work off the main thread on the shared serial queue, with a busy message
    /// and one error path. Errors surface as `errorMessage`; nothing is swallowed — except
    /// from a session that has ended.
    ///
    /// **`sessionBound`**, the default, ties the result to the session that asked for it.
    /// If the vault is locked while the work runs, the result is dropped and `handle` is
    /// never called. Without this a rebuild started just before a lock finished just after
    /// it and put the whole client list back into a locked app. Only work that is not about
    /// an open session — the passphrase files, the schedule file's bookmark — passes false.
    ///
    /// Returns whether `handle` ran, which is to say whether the work succeeded and still
    /// counts. Callers that need to know if something was saved ask this rather than
    /// inspecting `errorMessage`, which may be holding an error from something else.
    @discardableResult
    func run<T>(
        _ message: String?,
        sessionBound: Bool = true,
        _ work: @escaping () throws -> T,
        then handle: @escaping (T) -> Void
    ) async -> Bool {
        let token = sessionToken
        // Only a message this call put up is this call's to take down: a quiet read landing
        // in the middle of a save must not clear "Saving…" from under it.
        if let message { busyMessage = message }
        defer { if message != nil, busyMessage == message { busyMessage = nil } }

        do {
            let value: T = try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    continuation.resume(with: Result { try work() })
                }
            }
            if sessionBound && token.isRevoked { return false }
            handle(value)
            return true
        } catch {
            // A failure in a session that has since been locked is nobody's to read now —
            // and is usually the lock itself, stopping the work.
            if sessionBound && token.isRevoked { return false }
            report(error)
            return false
        }
    }

    func report(_ error: Error) {
        // `VaultError` is a `LocalizedError`, so this is already its own wording.
        errorMessage = error.localizedDescription
    }
}

/// Whether the session that started some work is still the open one.
///
/// A class, not a flag on `AppModel`, so that work on the vault queue can hold the one for
/// *its* session and ask it from there: `AppModel` is main-actor state and the queue cannot
/// read it. Locking revokes the current token and makes a new one, so every piece of work
/// started before the lock sees the revocation, and nothing started after it does.
final class SessionToken: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false

    var isRevoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return revoked
    }

    func revoke() {
        lock.lock()
        revoked = true
        lock.unlock()
    }
}
