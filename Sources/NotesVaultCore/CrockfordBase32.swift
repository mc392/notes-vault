import Foundation

/// Crockford's Base32 — the alphabet without `I`, `L`, `O` or `U`.
///
/// Used for two things that a human has to copy correctly under pressure: the recovery
/// key (written on paper at setup, typed back after losing a device) and note IDs.
/// `I`/`1`, `O`/`0` and `L`/`1` are the transcription errors people actually make, so the
/// alphabet excludes them and the decoder folds them back rather than rejecting the input.
/// `U` is excluded so that no accidental obscenity appears in a key the user has to read
/// aloud to support.
public enum CrockfordBase32 {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Big-endian, 5 bits per character, no padding.
    public static func encode(_ bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity((bytes.count * 8 + 4) / 5)
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 31])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 {
            out.append(alphabet[(buffer << (5 - bits)) & 31])
        }
        return out
    }

    /// Hyphens and spaces are ignored, case is folded, and the four confusable letters are
    /// mapped to the digit they were mistaken for. Anything else is a real error and is
    /// reported rather than silently dropped — a recovery key that decodes to *nearly* the
    /// right bytes is worse than one that refuses.
    public static func decode(_ text: String) throws -> [UInt8] {
        var out: [UInt8] = []
        var buffer = 0
        var bits = 0

        for character in text.uppercased() {
            if character == "-" || character == " " { continue }

            let value: Int
            switch character {
            case "O": value = 0
            case "I", "L": value = 1
            default:
                guard let index = alphabet.firstIndex(of: character) else {
                    throw VaultError.recoveryKeyMalformed("\"\(character)\" isn't a character used in recovery keys")
                }
                value = index
            }

            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
            buffer &= (1 << bits) - 1
        }

        // Whatever is left over must be zero padding. If it isn't, the string is a
        // character short or a character long — which is exactly the mistake we want to
        // catch before telling someone their vault is unrecoverable.
        guard buffer == 0 else {
            throw VaultError.recoveryKeyMalformed("it looks like a character is missing or mistyped")
        }
        return out
    }
}
