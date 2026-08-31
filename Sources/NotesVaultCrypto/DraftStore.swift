import Foundation
import CryptoKit
import NotesVaultCore

/// Where a half-written note lives until it is saved.
///
/// Modelled on `IndexStore`, and for the same reasons: it is written outside the vault
/// folder, into Application Support, encrypted with the per-device index key that never
/// leaves this device's keychain, and every failure is soft. A draft is a convenience —
/// a keychain hiccup must cost the counsellor an autosave, never the ability to write a
/// note.
///
/// Two things are stricter here than in the index. The filename is a hash rather than
/// anything readable, because the index's filename says only which vault it belongs to
/// while a draft's would otherwise have to say which *client* — and a client code in a
/// filename in Application Support is exactly the kind of thing this app promises not to
/// leave lying about. And on iOS the file is written with complete protection rather than
/// after-first-unlock: no sync daemon ever needs to read this one, so the strictest class
/// available is simply the right one.
///
/// What is *not* here is a plaintext fallback. If the index key cannot be had, the draft
/// is held in memory for the rest of the run and never touches the disk.
///
/// `Sendable` because `AppModel` hands it to the vault queue: a URL and a way of asking for
/// a key, neither of which is state that two threads could disagree about.
public struct DraftStore: Sendable {
    private let directory: URL
    private let keyForVault: @Sendable (String) -> SymmetricKey?

    public init?() {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }

        let directory = support
            .appendingPathComponent("NotesVault", isDirectory: true)
            .appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        self.init(directory: directory, key: { KeychainStore.indexKey(vaultID: $0) })
    }

    /// The injectable form. Tests use it to stay off the real keychain and out of the real
    /// Application Support folder.
    init(directory: URL, key: @escaping @Sendable (String) -> SymmetricKey?) {
        self.directory = directory
        self.keyForVault = key
    }

    // MARK: - Storing

    @discardableResult
    public func save(_ draft: NoteDraft, vaultID: String) -> Bool {
        let slot = Self.slot(vaultID: vaultID, client: draft.client, correcting: draft.correcting)

        guard let key = keyForVault(vaultID) else {
            HeldDrafts.set(draft, for: slot)
            return false
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let plaintext = try? encoder.encode(draft),
              let sealed = try? AES.GCM.seal(plaintext, using: key).combined else { return false }

        do {
            #if os(iOS)
            try sealed.write(to: fileURL(slot), options: [.atomic, .completeFileProtection])
            #else
            try sealed.write(to: fileURL(slot), options: [.atomic])
            #endif
            // The in-memory copy was a stand-in for this file; now that it exists, the
            // file is the one source.
            HeldDrafts.remove(slot)
            return true
        } catch {
            return false
        }
    }

    public func load(vaultID: String, client: ClientCode, correcting: NoteID?) -> NoteDraft? {
        let slot = Self.slot(vaultID: vaultID, client: client, correcting: correcting)

        if let key = keyForVault(vaultID),
           let sealed = try? Data(contentsOf: fileURL(slot)),
           let box = try? AES.GCM.SealedBox(combined: sealed),
           let plaintext = try? AES.GCM.open(box, using: key) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let draft = try? decoder.decode(NoteDraft.self, from: plaintext) { return draft }
        }
        return HeldDrafts.get(slot)
    }

    public func clear(vaultID: String, client: ClientCode, correcting: NoteID?) {
        let slot = Self.slot(vaultID: vaultID, client: client, correcting: correcting)
        HeldDrafts.remove(slot)
        try? FileManager.default.removeItem(at: fileURL(slot))
    }

    /// Every draft for one vault.
    ///
    /// Deliberately not per-client: the filename is a hash that includes the note being
    /// corrected, so the drafts belonging to one client cannot be picked out without
    /// knowing every note ID they might correct. Destroying a client is rare, confirmed by
    /// typing the code out in full, and clearing a colleague's half-written note along with
    /// it is the safe direction to err in — a draft that outlived a destruction would not
    /// be.
    public func clearAll(vaultID: String) {
        let prefix = Self.filePrefix(vaultID: vaultID)
        HeldDrafts.removeAll(withPrefix: prefix)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Naming

    private func fileURL(_ slot: String) -> URL {
        directory.appendingPathComponent("\(slot).draft")
    }

    /// The vault's `jti` — a random identifier from its own config file, saying nothing
    /// about the counsellor or their clients — followed by a hash of the vault, the client
    /// code and the note being corrected. The prefix is what makes `clearAll` possible; the
    /// hash is what keeps the client code out of the filename.
    private static func slot(vaultID: String, client: ClientCode, correcting: NoteID?) -> String {
        let identity = "\(vaultID)|\(client.rawValue)|\(correcting?.rawValue ?? "new")"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return filePrefix(vaultID: vaultID) + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func filePrefix(vaultID: String) -> String {
        "\(vaultID)-"
    }
}

/// Drafts for a run where the index key could not be had.
///
/// The alternative to holding these in memory is writing them in the clear, which this app
/// does not do — so a counsellor whose keychain is misbehaving still gets autosave for as
/// long as the app is running, and gets nothing readable on disk either way.
///
/// Reached from the vault queue and from the main actor, hence the lock.
private enum HeldDrafts {
    private static let lock = NSLock()
    private static var storage: [String: NoteDraft] = [:]

    static func set(_ draft: NoteDraft, for slot: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[slot] = draft
    }

    static func get(_ slot: String) -> NoteDraft? {
        lock.lock()
        defer { lock.unlock() }
        return storage[slot]
    }

    static func remove(_ slot: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[slot] = nil
    }

    static func removeAll(withPrefix prefix: String) {
        lock.lock()
        defer { lock.unlock() }
        for slot in storage.keys where slot.hasPrefix(prefix) {
            storage[slot] = nil
        }
    }
}
