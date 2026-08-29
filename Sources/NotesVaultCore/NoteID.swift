import Foundation

/// A 128-bit identifier: 48 bits of millisecond timestamp followed by 80 random bits,
/// rendered as 26 Crockford Base32 characters.
///
/// Time-ordered on purpose. The vault is an append-only log spread across several devices
/// with no coordinating server, so an ID that sorts by creation time lets a correction be
/// tied to the note it corrects without anything having to agree on a sequence number.
public struct NoteID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public static let length = 26

    public let rawValue: String

    public var description: String { rawValue }

    /// The first four characters, which is enough to disambiguate two notes written in the
    /// same minute on the same device and short enough to live in a filename.
    public var shortSuffix: String { String(rawValue.suffix(4)) }

    public init(generatedAt date: Date = Date()) {
        var bytes = [UInt8](repeating: 0, count: 16)

        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1000).rounded())
        for offset in 0..<6 {
            bytes[offset] = UInt8((milliseconds >> UInt64(8 * (5 - offset))) & 0xFF)
        }
        for offset in 6..<16 {
            bytes[offset] = UInt8.random(in: UInt8.min...UInt8.max)
        }

        // 16 bytes is 128 bits, which is 25.6 Base32 characters — the encoder emits 26 and
        // the last one carries two bits of padding. Trimming would break round-tripping.
        self.rawValue = CrockfordBase32.encode(bytes)
    }

    public init(_ rawValue: String) throws {
        let normalised = rawValue.trimmingCharacters(in: .whitespaces).uppercased()
        guard normalised.count == Self.length else {
            throw VaultError.malformedNote("note id \"\(rawValue)\" is not \(Self.length) characters")
        }
        _ = try CrockfordBase32.decode(normalised)
        self.rawValue = normalised
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: NoteID, rhs: NoteID) -> Bool { lhs.rawValue < rhs.rawValue }
}
