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
        guard let directory = SealedLocalFile.directory() else { return nil }
        self.vaultID = vaultID
        // The vault's `jti` is a random identifier from its own config file. It says
        // nothing about the counsellor, the folder or the clients — so an index filename
        // sitting in Application Support leaks nothing on its own.
        self.fileURL = directory.appendingPathComponent("\(vaultID).index")
    }

    public func load() -> VaultIndex? {
        guard let key = KeychainStore.indexKey(vaultID: vaultID),
              let index = SealedLocalFile.read(VaultIndex.self, from: fileURL, key: key),
              index.version == VaultIndex.formatVersion else { return nil }
        return index
    }

    @discardableResult
    public func save(_ index: VaultIndex) -> Bool {
        guard let key = KeychainStore.indexKey(vaultID: vaultID) else { return false }
        return SealedLocalFile.write(index, to: fileURL, key: key)
    }

    public func discard() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
