import Foundation
import CryptoKit
import CryptomatorCryptoLib
import NotesVaultCore

/// The `vault.cryptomator` claims, as this app cares about them.
public struct VaultConfiguration: Sendable, Equatable {
    public static let supportedFormat = 8

    public let format: Int
    public let shorteningThreshold: Int
    public let cipherCombo: String
    public let jti: String

    var scheme: CryptorScheme {
        cipherCombo == "SIV_CTRMAC" ? .sivCtrMac : .sivGcm
    }
}

/// An unlocked vault. Holding one of these is what "the vault is open" means.
///
/// The masterkey is held for the lifetime of the session and zeroed by the library's own
/// `deinit` when it is released, so locking the vault is `session = nil` and nothing else.
public final class VaultSession {
    public let engine: VaultCryptoEngine
    public let configuration: VaultConfiguration
    private let masterkey: Masterkey

    init(masterkey: Masterkey, configuration: VaultConfiguration) {
        self.masterkey = masterkey
        self.configuration = configuration
        self.engine = CryptomatorEngine(cryptor: Cryptor(masterkey: masterkey, scheme: configuration.scheme))
    }
}

/// Creating and opening vaults: the masterkey files, the vault config, and the recovery
/// route.
public enum VaultBootstrap {
    /// Cryptomator's own default. Deliberately not lowered — this is the only thing between
    /// a stolen laptop and a client's clinical record, and a second of setup latency is a
    /// price worth paying once.
    public static let scryptCostParam = 32768

    // MARK: - Detection

    public static func isVault(_ files: VaultFileStore) -> Bool {
        files.fileExists(at: [VaultLayout.masterkeyFilename]) && files.fileExists(at: [VaultLayout.vaultConfigFilename])
    }

    public static func hasRecoveryKey(_ files: VaultFileStore) -> Bool {
        files.fileExists(at: [VaultLayout.recoveryMasterkeyFilename])
    }

    // MARK: - Creating

    /// Creates a new vault and returns the open session plus the recovery key.
    ///
    /// The recovery key is returned exactly once and never stored anywhere it could be read
    /// back — what lands on disk is a *second masterkey file* wrapped with it, which proves
    /// nothing about the key itself. Decision 08: if the counsellor loses both the
    /// passphrase and this key, the notes are gone, and no amount of contacting us changes
    /// that. The onboarding screen says so in those words.
    public static func createVault(
        in files: VaultFileStore,
        passphrase: String
    ) throws -> (session: VaultSession, recoveryKey: RecoveryKey) {
        guard !isVault(files) else {
            throw VaultError.vaultAlreadyExists(URL(fileURLWithPath: "."))
        }

        let masterkey = try Masterkey.createNew()
        let configuration = VaultConfiguration(
            format: VaultConfiguration.supportedFormat,
            shorteningThreshold: VaultLayout.shorteningThreshold,
            cipherCombo: "SIV_GCM",
            jti: UUID().uuidString
        )

        let masterkeyData = try MasterkeyFile.lock(
            masterkey: masterkey,
            vaultVersion: configuration.format,
            passphrase: passphrase,
            pepper: [UInt8](),
            scryptCostParam: scryptCostParam
        )
        let recoveryKey = RecoveryKey()
        let recoveryData = try MasterkeyFile.lock(
            masterkey: masterkey,
            vaultVersion: configuration.format,
            passphrase: recoveryKey.passphrase,
            pepper: [UInt8](),
            scryptCostParam: scryptCostParam
        )

        let configData = try encodeConfiguration(configuration, signingWith: masterkey)

        // Order matters. The config is written last, and `isVault` requires it, so a write
        // interrupted halfway leaves a folder that reads as "not a vault yet" rather than
        // as a vault whose masterkey is missing.
        try files.write(masterkeyData, at: [VaultLayout.masterkeyFilename], overwrite: false)
        try files.write(recoveryData, at: [VaultLayout.recoveryMasterkeyFilename], overwrite: false)
        try files.write(configData, at: [VaultLayout.vaultConfigFilename], overwrite: false)

        let session = VaultSession(masterkey: masterkey, configuration: configuration)
        let store = VaultStore(engine: session.engine, files: files, deviceName: DeviceIdentity.current)
        try store.prepareStructure()

        return (session, recoveryKey)
    }

    // MARK: - Opening

    public static func open(_ files: VaultFileStore, passphrase: String) throws -> VaultSession {
        try open(files, masterkeyFile: VaultLayout.masterkeyFilename, passphrase: passphrase)
    }

    /// Opens the vault with the recovery key instead of the passphrase.
    public static func open(_ files: VaultFileStore, recoveryKey: RecoveryKey) throws -> VaultSession {
        guard hasRecoveryKey(files) else {
            throw VaultError.folderUnavailable("this vault has no recovery key file")
        }
        return try open(files, masterkeyFile: VaultLayout.recoveryMasterkeyFilename, passphrase: recoveryKey.passphrase)
    }

    private static func open(_ files: VaultFileStore, masterkeyFile: String, passphrase: String) throws -> VaultSession {
        guard isVault(files) else {
            throw VaultError.notAVault(URL(fileURLWithPath: "."))
        }

        let configData = try files.read(at: [VaultLayout.vaultConfigFilename])
        let configuration = try decodeConfiguration(configData)
        guard configuration.format == VaultConfiguration.supportedFormat else {
            throw VaultError.unsupportedVaultFormat(configuration.format)
        }

        let masterkeyFileData = try files.read(at: [masterkeyFile])
        let masterkey: Masterkey
        do {
            masterkey = try MasterkeyFile.withContentFromData(data: masterkeyFileData)
                .unlock(passphrase: passphrase, pepper: [UInt8]())
        } catch MasterkeyFileError.invalidPassphrase {
            throw VaultError.wrongPassphrase
        } catch {
            throw VaultError.cryptoFailure("the masterkey file could not be read: \(error.localizedDescription)")
        }

        // The config is signed with the masterkey, so a tampered `vault.cryptomator` — one
        // that downgrades the cipher, say — fails here rather than being obeyed.
        try verifySignature(of: configData, with: masterkey)

        return VaultSession(masterkey: masterkey, configuration: configuration)
    }

    // MARK: - Passphrase management

    /// Changes the passphrase. The recovery key is unaffected by design — it wraps the same
    /// masterkey independently, so someone who changes their passphrase does not silently
    /// invalidate the piece of paper in their safe.
    public static func changePassphrase(in files: VaultFileStore, current: String, new: String) throws {
        let data = try files.read(at: [VaultLayout.masterkeyFilename])
        let updated: Data
        do {
            updated = try MasterkeyFile.changePassphrase(
                masterkeyFileData: data,
                oldPassphrase: current,
                newPassphrase: new,
                pepper: [UInt8](),
                scryptCostParam: scryptCostParam
            )
        } catch MasterkeyFileError.invalidPassphrase {
            throw VaultError.wrongPassphrase
        }
        try files.write(updated, at: [VaultLayout.masterkeyFilename], overwrite: true)
    }

    /// Sets a new passphrase using the recovery key — the whole point of having one.
    public static func resetPassphrase(in files: VaultFileStore, recoveryKey: RecoveryKey, newPassphrase: String) throws {
        guard hasRecoveryKey(files) else {
            throw VaultError.folderUnavailable("this vault has no recovery key file")
        }
        let recoveryData = try files.read(at: [VaultLayout.recoveryMasterkeyFilename])
        let masterkey: Masterkey
        do {
            masterkey = try MasterkeyFile.withContentFromData(data: recoveryData)
                .unlock(passphrase: recoveryKey.passphrase, pepper: [UInt8]())
        } catch MasterkeyFileError.invalidPassphrase {
            throw VaultError.recoveryKeyMalformed("that key does not open this vault")
        }

        let configuration = try decodeConfiguration(try files.read(at: [VaultLayout.vaultConfigFilename]))
        let rewrapped = try MasterkeyFile.lock(
            masterkey: masterkey,
            vaultVersion: configuration.format,
            passphrase: newPassphrase,
            pepper: [UInt8](),
            scryptCostParam: scryptCostParam
        )
        try files.write(rewrapped, at: [VaultLayout.masterkeyFilename], overwrite: true)
    }

    /// Issues a fresh recovery key, invalidating the old one. Used when a counsellor thinks
    /// the written copy has been seen by someone else.
    public static func regenerateRecoveryKey(in files: VaultFileStore, passphrase: String) throws -> RecoveryKey {
        let data = try files.read(at: [VaultLayout.masterkeyFilename])
        let masterkey: Masterkey
        do {
            masterkey = try MasterkeyFile.withContentFromData(data: data).unlock(passphrase: passphrase, pepper: [UInt8]())
        } catch MasterkeyFileError.invalidPassphrase {
            throw VaultError.wrongPassphrase
        }

        let configuration = try decodeConfiguration(try files.read(at: [VaultLayout.vaultConfigFilename]))
        let recoveryKey = RecoveryKey()
        let recoveryData = try MasterkeyFile.lock(
            masterkey: masterkey,
            vaultVersion: configuration.format,
            passphrase: recoveryKey.passphrase,
            pepper: [UInt8](),
            scryptCostParam: scryptCostParam
        )
        try files.write(recoveryData, at: [VaultLayout.recoveryMasterkeyFilename], overwrite: true)
        return recoveryKey
    }

    // MARK: - vault.cryptomator (a JWS with HS256)

    static func encodeConfiguration(_ configuration: VaultConfiguration, signingWith masterkey: Masterkey) throws -> Data {
        let header: [String: Any] = [
            "kid": "masterkeyfile:\(VaultLayout.masterkeyFilename)",
            "typ": "JWT",
            "alg": "HS256"
        ]
        let payload: [String: Any] = [
            "format": configuration.format,
            "shorteningThreshold": configuration.shorteningThreshold,
            "jti": configuration.jti,
            "cipherCombo": configuration.cipherCombo
        ]

        let headerSegment = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]).urlSafeBase64String()
        let payloadSegment = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).urlSafeBase64String()
        let signingInput = "\(headerSegment).\(payloadSegment)"
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: SymmetricKey(data: Data(masterkey.rawKey))))

        return Data("\(signingInput).\(signature.urlSafeBase64String())".utf8)
    }

    /// Readable without the key: the config is *signed*, not encrypted, so the app can find
    /// out which vault this is (and therefore which keychain items belong to it) before
    /// anyone has typed a passphrase.
    public static func decodeConfiguration(_ data: Data) throws -> VaultConfiguration {
        guard let token = String(data: data, encoding: .utf8) else {
            throw VaultError.notAVault(URL(fileURLWithPath: VaultLayout.vaultConfigFilename))
        }
        let segments = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard segments.count == 3, let payloadData = Data(urlSafeBase64: String(segments[1])) else {
            throw VaultError.notAVault(URL(fileURLWithPath: VaultLayout.vaultConfigFilename))
        }
        guard let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let format = payload["format"] as? Int else {
            throw VaultError.notAVault(URL(fileURLWithPath: VaultLayout.vaultConfigFilename))
        }

        return VaultConfiguration(
            format: format,
            shorteningThreshold: payload["shorteningThreshold"] as? Int ?? VaultLayout.shorteningThreshold,
            cipherCombo: payload["cipherCombo"] as? String ?? "SIV_GCM",
            jti: payload["jti"] as? String ?? ""
        )
    }

    static func verifySignature(of data: Data, with masterkey: Masterkey) throws {
        guard let token = String(data: data, encoding: .utf8) else {
            throw VaultError.notAVault(URL(fileURLWithPath: VaultLayout.vaultConfigFilename))
        }
        let segments = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard segments.count == 3, let signature = Data(urlSafeBase64: String(segments[2])) else {
            throw VaultError.notAVault(URL(fileURLWithPath: VaultLayout.vaultConfigFilename))
        }
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        let expected = HMAC<SHA256>.authenticationCode(for: signingInput, using: SymmetricKey(data: Data(masterkey.rawKey)))
        guard Data(expected) == signature else {
            throw VaultError.cryptoFailure("the vault configuration file has been altered and does not match this vault's key")
        }
    }
}

extension Data {
    /// Base64url, unpadded — the JWS encoding. Named distinctly so it can never be confused
    /// with a similarly named helper in the crypto library.
    func urlSafeBase64String() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(urlSafeBase64 string: String) {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded) else { return nil }
        self = data
    }
}
