import Foundation

/// Where things sit inside a Cryptomator vault (format 8).
///
/// The whole point of this layer is that the *decrypted* view — `Vault/SM2/2026-06-14T0930-iphone.note`
/// — and the *stored* view — `d/D7/F3K...` holding `9a1c4e2b.c9r` — are computed from each
/// other, and only the second one ever reaches iCloud. Folder names, filenames, dates and
/// client codes are all inside the encryption boundary.
public struct VaultLayout {
    /// The root directory's ID is the empty string, by the format's definition.
    public static let rootDirectoryID = Data()

    /// Cryptomator's default. Longer ciphertext names get shortened into `.c9s` directories
    /// by full implementations; this app never generates a name anywhere near the limit
    /// (a client code plus a timestamp is well under 40 characters), so it guards instead
    /// of implementing shortening it would never exercise and could never test properly.
    public static let shorteningThreshold = 220

    public static let contentExtension = "c9r"
    public static let directoryMarker = "dir.c9r"
    public static let masterkeyFilename = "masterkey.cryptomator"
    public static let recoveryMasterkeyFilename = "masterkey.recovery.cryptomator"
    public static let vaultConfigFilename = "vault.cryptomator"
    public static let dataDirectory = "d"

    public let engine: VaultCryptoEngine

    public init(engine: VaultCryptoEngine) {
        self.engine = engine
    }

    /// `["d", "D7", "F3KQ8..."]` — a two-character shard so no single directory ends up
    /// holding thousands of entries, which is what the format shards for.
    public func directoryPath(for directoryID: Data) throws -> [String] {
        let hash = try engine.hashedDirectoryID(directoryID)
        guard hash.count > 2 else {
            throw VaultError.cryptoFailure("the directory hash came back too short to shard")
        }
        let shard = String(hash.prefix(2))
        let rest = String(hash.dropFirst(2))
        return [Self.dataDirectory, shard, rest]
    }

    public func rootPath() throws -> [String] {
        try directoryPath(for: Self.rootDirectoryID)
    }

    /// The stored name for one cleartext path component, `.c9r` included.
    public func ciphertextName(for cleartext: String, in directoryID: Data) throws -> String {
        let encrypted = try engine.encryptFilename(cleartext, directoryID: directoryID)
        let full = "\(encrypted).\(Self.contentExtension)"
        guard full.count <= Self.shorteningThreshold else {
            throw VaultError.nameTooLongForVault(cleartext)
        }
        return full
    }

    /// The reverse. Returns nil for anything that is not one of ours — `.c9s` shortened
    /// names written by Cryptomator itself, a stray `.DS_Store`, a sync conflict copy —
    /// so a foreign file in the vault is skipped rather than crashing a listing.
    public func cleartextName(for storedName: String, in directoryID: Data) -> String? {
        guard storedName.hasSuffix(".\(Self.contentExtension)") else { return nil }
        let base = String(storedName.dropLast(Self.contentExtension.count + 1))
        guard !base.isEmpty else { return nil }
        return try? engine.decryptFilename(base, directoryID: directoryID)
    }

    /// Path to a file held directly in a directory.
    public func filePath(named cleartext: String, in directoryID: Data) throws -> [String] {
        try directoryPath(for: directoryID) + [ciphertextName(for: cleartext, in: directoryID)]
    }

    /// Path to the `dir.c9r` marker that names a subdirectory's own ID.
    public func directoryMarkerPath(forChildNamed cleartext: String, in parentID: Data) throws -> [String] {
        try directoryPath(for: parentID) + [ciphertextName(for: cleartext, in: parentID), Self.directoryMarker]
    }

    /// A fresh directory ID. Cryptomator uses a UUID string; matching that keeps the vault
    /// openable by Cryptomator's own clients, which is the escape hatch that makes
    /// principle 05 (no lock-in) real rather than a claim.
    public static func newDirectoryID() -> Data {
        Data(UUID().uuidString.utf8)
    }
}
