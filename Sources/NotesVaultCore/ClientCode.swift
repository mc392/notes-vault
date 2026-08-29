import Foundation

/// A client identifier.
///
/// Principle 02: the app never stores a real name, address or contact detail. The
/// code→identity mapping lives in the counsellor's own password manager, outside this
/// app entirely (decision 09). The type exists so that "never store a name" is enforced
/// by the compiler at every call site rather than by everyone remembering.
///
/// The charset is the same one GroundWork already runs its data model on: upper-case
/// letters and digits, e.g. `SM2`. It is deliberately narrow — a code that cannot contain
/// a space or a punctuation mark cannot quietly become "Sarah M (Tues 9am)".
public struct ClientCode: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public static let minLength = 2
    public static let maxLength = 12

    public let rawValue: String

    public var description: String { rawValue }

    /// Normalises then validates. Trailing/leading space and lower case are corrected
    /// rather than rejected — that is a typing slip, not a different client.
    public init(_ input: String) throws {
        let normalised = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard normalised.count >= Self.minLength else {
            throw VaultError.invalidClientCode(input, reason: "must be at least \(Self.minLength) characters")
        }
        guard normalised.count <= Self.maxLength else {
            throw VaultError.invalidClientCode(input, reason: "must be at most \(Self.maxLength) characters")
        }
        guard normalised.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            throw VaultError.invalidClientCode(input, reason: "use letters and numbers only — no names, spaces or punctuation")
        }
        // `_client` is our own reserved prefix for the per-client metadata log, and a
        // leading digit-only code is fine but a code that collides with a reserved
        // folder name is not.
        guard !normalised.hasPrefix("_") else {
            throw VaultError.invalidClientCode(input, reason: "cannot start with an underscore")
        }
        self.rawValue = normalised
    }

    /// For decoding values that were already validated on the way in.
    public init(validated rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: ClientCode, rhs: ClientCode) -> Bool {
        lhs.rawValue.localizedStandardCompare(rhs.rawValue) == .orderedAscending
    }
}
