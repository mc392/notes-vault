import Foundation
import CryptoKit
import NotesVaultCore

/// The encrypted on-device index cache.
///
/// It holds client codes, dates and word counts — no note bodies — and it is encrypted
/// with a key that never leaves this device's keychain. That matters: the index is the one
/// file this app writes *outside* the vault, so it is the one place where "the app stores
/// nothing readable" could quietly stop being true.
///
/// Everything here treats failure as routine. A missing, stale or corrupt index costs a
/// rebuild, never a note, so nothing in this file throws into the UI — it returns nil and
/// the caller rebuilds.
public struct IndexStore {
    private let vaultID: String
    private let fileURL: URL

    public init?(vaultID: String) {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }

        let directory = support.appendingPathComponent("NotesVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        self.vaultID = vaultID
        // The vault's `jti` is a random identifier from its own config file. It says
        // nothing about the counsellor, the folder or the clients — so an index filename
        // sitting in Application Support leaks nothing on its own.
        self.fileURL = directory.appendingPathComponent("\(vaultID).index")
    }

    public func load() -> VaultIndex? {
        guard let key = KeychainStore.indexKey(vaultID: vaultID),
              let sealed = try? Data(contentsOf: fileURL),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plaintext = try? AES.GCM.open(box, using: key) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let index = try? decoder.decode(VaultIndex.self, from: plaintext) else { return nil }
        guard index.version == VaultIndex.formatVersion else { return nil }
        return index
    }

    @discardableResult
    public func save(_ index: VaultIndex) -> Bool {
        guard let key = KeychainStore.indexKey(vaultID: vaultID) else { return false }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let plaintext = try? encoder.encode(index),
              let sealed = try? AES.GCM.seal(plaintext, using: key).combined else { return false }

        do {
            #if os(iOS)
            try sealed.write(to: fileURL, options: [.atomic, .completeFileProtection])
            #else
            try sealed.write(to: fileURL, options: [.atomic])
            #endif
            return true
        } catch {
            return false
        }
    }

    public func discard() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
