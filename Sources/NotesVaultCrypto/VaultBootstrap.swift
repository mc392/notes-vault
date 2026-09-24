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

/// A recovery key that has been made but not yet written into the vault.
///
/// `masterkeyFile` is the vault's masterkey wrapped under the new key — ciphertext, like
/// every other masterkey file, so holding it in memory holds nothing the key itself does
/// not. Until `VaultBootstrap.installRecoveryKey` writes it, the old key is the one that
/// works.
public struct PreparedRecoveryKey: Sendable {
    public let key: RecoveryKey
    let masterkeyFile: Data
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

        let masterkeyData = try wrap(masterkey, format: configuration.format, passphrase: passphrase)
        let recoveryKey = RecoveryKey()
        let recoveryData = try wrap(masterkey, format: configuration.format, passphrase: recoveryKey.passphrase)

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

        let masterkey = try unwrap(
            try files.read(at: [masterkeyFile]),
            passphrase: passphrase,
            refusal: masterkeyFile == VaultLayout.recoveryMasterkeyFilename
                ? .recoveryKeyMalformed("that key does not open this vault")
                : .wrongPassphrase
        )

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
        } catch {
            throw VaultError.cryptoFailure("the passphrase could not be changed: \(error.localizedDescription)")
        }
        try files.write(updated, at: [VaultLayout.masterkeyFilename], overwrite: true)
    }

    /// Sets a new passphrase using the recovery key — the whole point of having one.
    public static func resetPassphrase(in files: VaultFileStore, recoveryKey: RecoveryKey, newPassphrase: String) throws {
        guard hasRecoveryKey(files) else {
            throw VaultError.folderUnavailable("this vault has no recovery key file")
        }
        let masterkey = try unwrap(
            try files.read(at: [VaultLayout.recoveryMasterkeyFilename]),
            passphrase: recoveryKey.passphrase,
            refusal: .recoveryKeyMalformed("that key does not open this vault")
        )
        let configuration = try decodeConfiguration(try files.read(at: [VaultLayout.vaultConfigFilename]))
        let rewrapped = try wrap(masterkey, format: configuration.format, passphrase: newPassphrase)
        try files.write(rewrapped, at: [VaultLayout.masterkeyFilename], overwrite: true)
    }

    /// Issues a fresh recovery key, invalidating the old one, in one step.
    ///
    /// The app does not use this: it prepares the key, shows it, and installs it only once
    /// it has been typed back — see `prepareRecoveryKey`. This is the same two steps back
    /// to back, for callers with nobody to show a key to.
    public static func regenerateRecoveryKey(in files: VaultFileStore, passphrase: String) throws -> RecoveryKey {
        let prepared = try prepareRecoveryKey(in: files, passphrase: passphrase)
        try installRecoveryKey(prepared, in: files)
        return prepared.key
    }

    /// Makes a new recovery key and the masterkey file it opens, and writes nothing.
    ///
    /// Reissuing used to write the new file straight away, which retired the old key before
    /// the counsellor had copied the new one down — so a lock, a crash or a closed sheet in
    /// between left a vault whose only recovery key had been on screen for a moment and
    /// nowhere else. Now the old key keeps working until `installRecoveryKey` runs, which
    /// the app does only after the new one has been typed back. Abandoning a prepared key
    /// costs nothing: it opens a file that was never written.
    public static func prepareRecoveryKey(in files: VaultFileStore, passphrase: String) throws -> PreparedRecoveryKey {
        let masterkey = try unwrap(
            try files.read(at: [VaultLayout.masterkeyFilename]),
            passphrase: passphrase,
            refusal: .wrongPassphrase
        )
        let configuration = try decodeConfiguration(try files.read(at: [VaultLayout.vaultConfigFilename]))
        let key = RecoveryKey()
        return PreparedRecoveryKey(
            key: key,
            masterkeyFile: try wrap(masterkey, format: configuration.format, passphrase: key.passphrase)
        )
    }

    /// Writes a prepared recovery key's masterkey file, which is the moment the old key
    /// stops working.
    public static func installRecoveryKey(_ prepared: PreparedRecoveryKey, in files: VaultFileStore) throws {
        try files.write(prepared.masterkeyFile, at: [VaultLayout.recoveryMasterkeyFilename], overwrite: true)
    }

    // MARK: - Masterkey files

    /// Opens a masterkey file. `refusal` is what a wrong passphrase or key is reported as,
    /// because "wrong passphrase" is the wrong thing to tell someone typing a recovery key.
    private static func unwrap(_ data: Data, passphrase: String, refusal: VaultError) throws -> Masterkey {
        do {
            return try MasterkeyFile.withContentFromData(data: data).unlock(passphrase: passphrase, pepper: [UInt8]())
        } catch MasterkeyFileError.invalidPassphrase {
            throw refusal
        } catch {
            throw VaultError.cryptoFailure("the masterkey file could not be read: \(error.localizedDescription)")
        }
    }

    /// Wraps the masterkey under a passphrase, at the production scrypt cost.
    private static func wrap(_ masterkey: Masterkey, format: Int, passphrase: String) throws -> Data {
        do {
            return try MasterkeyFile.lock(
                masterkey: masterkey,
                vaultVersion: format,
                passphrase: passphrase,
                pepper: [UInt8](),
                scryptCostParam: scryptCostParam
            )
        } catch {
            throw VaultError.cryptoFailure("the masterkey file could not be written: \(error.localizedDescription)")
        }
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
        let segments = try jwsSegments(of: data)
        guard let payloadData = Data(urlSafeBase64: String(segments[1])),
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let format = payload["format"] as? Int else {
            throw notAVaultConfig
        }
        // The `jti` names the keychain items and the local files that belong to this vault.
        // A config without one used to be read as an empty string, which every such vault
        // would then have shared — one vault's Face ID passphrase offered to another's.
        // Every real Cryptomator vault has one, so a config without it is not one.
        guard let jti = payload["jti"] as? String, !jti.isEmpty else {
            throw notAVaultConfig
        }

        return VaultConfiguration(
            format: format,
            shorteningThreshold: payload["shorteningThreshold"] as? Int ?? VaultLayout.shorteningThreshold,
            cipherCombo: payload["cipherCombo"] as? String ?? "SIV_GCM",
            jti: jti
        )
    }

    static func verifySignature(of data: Data, with masterkey: Masterkey) throws {
        let segments = try jwsSegments(of: data)
        guard let signature = Data(urlSafeBase64: String(segments[2])) else {
            throw notAVaultConfig
        }
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        // CryptoKit's comparison rather than `==`: it takes the same time however many
        // leading bytes match, so how long a rejection takes says nothing about the key.
        guard HMAC<SHA256>.isValidAuthenticationCode(
            signature,
            authenticating: signingInput,
            using: SymmetricKey(data: Data(masterkey.rawKey))
        ) else {
            throw VaultError.cryptoFailure("the vault configuration file has been altered and does not match this vault's key")
        }
    }

    /// The three dot-separated parts of the token.
    private static func jwsSegments(of data: Data) throws -> [Substring] {
        guard let token = String(data: data, encoding: .utf8) else { throw notAVaultConfig }
        let segments = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard segments.count == 3 else { throw notAVaultConfig }
        return segments
    }

    private static var notAVaultConfig: VaultError {
        .notAVault(URL(fileURLWithPath: VaultLayout.vaultConfigFilename))
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
