import Foundation

/// The one thing standing between a lost passphrase and an unrecoverable vault.
///
/// Decision 08 is "recovery phrase only, shown once at setup, no vendor involvement". This
/// is that secret, rendered as nine groups of four Crockford Base32 characters:
///
///     K3M9-A7QP-2FTV-8XZR-5JW4-H6NB-CD1S-90GY-E2AK
///
/// **Why groups of characters rather than BIP-39 words.** A word list is only unambiguous
/// if everyone agrees which list; a counsellor writing this on paper in 2026 and typing it
/// back in 2033 needs the app to still know. Crockford's alphabet needs no external list,
/// excludes the four characters people actually mistranscribe (`I`, `L`, `O`, `U`), and
/// carries a checksum, so a mistyped key is rejected at the point of typing rather than
/// after an eight-second scrypt derivation returns "wrong passphrase".
///
/// **How it is used.** The key is not a second copy of the vault key and never encodes it.
/// It is a high-entropy passphrase for a *second* masterkey file — the same audited
/// lock/unlock path as the user's own passphrase, with no bespoke cryptography anywhere in
/// the recovery route. See `VaultBootstrap`.
public struct RecoveryKey: Hashable, Sendable {
    /// 160 bits. Far past anything brute-forceable, and short enough to write down without
    /// making an error.
    public static let entropyBytes = 20
    public static let groupSize = 4
    public static let groupCount = 9

    /// The 20 bytes of entropy, without the checksum.
    public let entropy: [UInt8]

    /// The form shown to the user and typed back in.
    public var formatted: String {
        let characters = Array(CrockfordBase32.encode(entropy + Self.checksum(entropy)))
        return stride(from: 0, to: characters.count, by: Self.groupSize)
            .map { String(characters[$0..<min($0 + Self.groupSize, characters.count)]) }
            .joined(separator: "-")
    }

    /// What is actually handed to the key-derivation function. Hyphens and case are
    /// presentation, so they are stripped — someone typing it back in lower case with the
    /// hyphens left out must still get into their vault.
    public var passphrase: String {
        formatted.replacingOccurrences(of: "-", with: "")
    }

    public init() {
        var generator = SystemRandomNumberGenerator()
        // Apple's system generator is the platform CSPRNG (getentropy/arc4random). This is
        // the one place in the app where the quality of the randomness is the whole
        // security of the recovery route, so it is deliberately not `Int.random` on a
        // seeded generator or anything else convenient.
        self.entropy = (0..<Self.entropyBytes).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
    }

    public init(entropy: [UInt8]) throws {
        guard entropy.count == Self.entropyBytes else {
            throw VaultError.recoveryKeyMalformed("a recovery key is \(Self.entropyBytes) bytes, not \(entropy.count)")
        }
        self.entropy = entropy
    }

    /// Parses a key as typed, in any combination of case, spacing and hyphenation.
    public init(typed input: String) throws {
        let cleaned = input.filter { !$0.isWhitespace && $0 != "-" }
        guard !cleaned.isEmpty else {
            throw VaultError.recoveryKeyMalformed("nothing was entered")
        }
        let expectedCharacters = Self.groupSize * Self.groupCount
        guard cleaned.count == expectedCharacters else {
            throw VaultError.recoveryKeyMalformed("a recovery key is \(expectedCharacters) characters, and this one is \(cleaned.count)")
        }

        let bytes = try CrockfordBase32.decode(cleaned)
        guard bytes.count == Self.entropyBytes + 2 else {
            throw VaultError.recoveryKeyMalformed("it is the wrong length once decoded")
        }

        let entropy = Array(bytes.prefix(Self.entropyBytes))
        let checksum = Array(bytes.suffix(2))
        guard checksum == Self.checksum(entropy) else {
            throw VaultError.recoveryKeyMalformed("there is a typo in it — the check characters do not match")
        }
        self.entropy = entropy
    }

    /// CRC-16/CCITT-FALSE. Not a security control — it exists so that a single wrong
    /// character is caught immediately instead of presenting as an unrecoverable vault.
    static func checksum(_ bytes: [UInt8]) -> [UInt8] {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return [UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }
}
