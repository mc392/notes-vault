import Foundation

/// Everything the layout layer needs from cryptography, and nothing more.
///
/// This protocol is why `NotesVaultCore` has no crypto dependency. The real implementation
/// (`NotesVaultCrypto`) wraps Cryptomator's audited library; the tests use a transparent
/// double. That split means the vault layout, the note format and the retention rules can
/// all be tested exhaustively without scrypt taking a second per case — and, more
/// importantly, that nothing in this module can quietly grow its own cryptography.
public protocol VaultCryptoEngine: AnyObject {
    /// Cryptomator's directory hash: a deterministic 32-character Base32 string derived
    /// from the directory ID. Not a secret, but not reversible either — it is what stops
    /// the folder tree in iCloud from having the same *shape* as the real one.
    func hashedDirectoryID(_ directoryID: Data) throws -> String

    /// Encrypts one path component. The directory ID is mixed in, so the same client code
    /// encrypts to a different name in a different folder.
    func encryptFilename(_ cleartext: String, directoryID: Data) throws -> String
    func decryptFilename(_ ciphertext: String, directoryID: Data) throws -> String

    func encryptContent(_ plaintext: Data) throws -> Data
    func decryptContent(_ ciphertext: Data) throws -> Data
}

/// The filesystem, as narrow an interface as the store can get away with.
///
/// Paths are arrays of components relative to the vault root, so nothing in this module
/// handles a `URL`, a security-scoped bookmark or a file coordinator — all of which are
/// platform concerns that belong in the app layer. It also means the entire store can be
/// exercised against an in-memory double in tests, including the failure paths that are
/// almost impossible to trigger against a real iCloud folder.
public protocol VaultFileStore: AnyObject {
    func directoryExists(at path: [String]) -> Bool
    func fileExists(at path: [String]) -> Bool
    /// Names of the immediate children, in no guaranteed order.
    func contentsOfDirectory(at path: [String]) throws -> [String]
    func createDirectory(at path: [String]) throws
    func read(at path: [String]) throws -> Data
    /// Must refuse to overwrite when `overwrite` is false. The whole vault is append-only,
    /// so every note write passes false — a store that silently overwrote would destroy
    /// the property the format depends on.
    func write(_ data: Data, at path: [String], overwrite: Bool) throws
    func remove(at path: [String]) throws
}
