import Foundation

public enum ClientStatus: String, CaseIterable, Codable, Sendable {
    case active
    case paused
    case ended

    public var displayName: String {
        switch self {
        case .active: return "Active"
        case .paused: return "Paused"
        case .ended: return "Ended"
        }
    }

    /// Only an ended client has a retention clock running. Paused is deliberately not
    /// ended — the same call GroundWork makes in `defaultEndedStatuses`, and for the same
    /// reason: a paused client may come back, and flagging their notes for destruction
    /// would be actively wrong.
    public var startsRetentionClock: Bool { self == .ended }
}

/// What determines how long this client's notes must be kept.
///
/// The app stores no date of birth. For a client seen as a minor the counsellor enters the
/// birth date once in a picker and the app keeps only the date they reach 25 — the figure
/// the retention rule actually needs. One less identifying field in the vault, and no
/// chance of the arithmetic being done wrong at review time years later.
public enum RetentionBasis: Hashable, Sendable, Codable {
    case adult
    case minor(reaches25On: Date)

    public var isMinor: Bool {
        if case .minor = self { return true }
        return false
    }

    /// Stored as `adult` or `minor:2041-05-02T00:00:00Z`.
    public var encodedString: String {
        switch self {
        case .adult:
            return "adult"
        case let .minor(reaches25On):
            return "minor:\(VaultDate.utcString(reaches25On))"
        }
    }

    public init(encoded: String) throws {
        let trimmed = encoded.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "adult" {
            self = .adult
            return
        }
        guard trimmed.hasPrefix("minor:") else {
            throw VaultError.malformedNote("\"\(encoded)\" is not a retention basis")
        }
        let dateText = String(encoded.trimmingCharacters(in: .whitespaces).dropFirst("minor:".count))
        guard let date = VaultDate.parse(dateText) else {
            throw VaultError.malformedNote("\"\(dateText)\" is not a readable date")
        }
        self = .minor(reaches25On: date)
    }

    /// Converts a date of birth to the only thing we keep. The DOB is not stored.
    public static func minor(dateOfBirth: Date, calendar: Calendar = .gregorianUTC) -> RetentionBasis {
        let twentyFifth = calendar.date(byAdding: .year, value: 25, to: dateOfBirth) ?? dateOfBirth
        return .minor(reaches25On: twentyFifth)
    }

    // Encoded by hand rather than synthesised, so the local index and the vault file agree
    // on one representation and a future case cannot change the index format underneath a
    // build that is already running.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(encoded: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedString)
    }
}

/// One append-only entry in a client's metadata log.
///
/// Client metadata *does* change — someone ends therapy, a status is corrected — but the
/// vault is append-only everywhere, not just for notes. So each change writes a new file
/// holding a complete snapshot, and the latest one wins. Same mechanism as notes, same
/// immunity to two devices writing at once, and the history of status changes is kept for
/// free.
public struct ClientMetadataEvent: Identifiable, Hashable, Sendable {
    public static let formatVersion = 1
    public static let magic = "notesvault-client"

    public let id: NoteID
    public let client: ClientCode
    public let written: Date
    public let device: String
    public let status: ClientStatus
    public let retentionBasis: RetentionBasis
    /// Set when the counsellor wants the retention clock to run from a date other than the
    /// last note — a final contact that produced no written record, typically.
    public let lastContactOverride: Date?
    public let extraHeaders: [String: String]

    public init(
        id: NoteID = NoteID(),
        client: ClientCode,
        written: Date = Date(),
        device: String,
        status: ClientStatus,
        retentionBasis: RetentionBasis = .adult,
        lastContactOverride: Date? = nil,
        extraHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.client = client
        self.written = written
        self.device = device
        self.status = status
        self.retentionBasis = retentionBasis
        self.lastContactOverride = lastContactOverride
        self.extraHeaders = extraHeaders
    }

    public func serialised() -> Data {
        var lines: [String] = []
        lines.append("\(Self.magic)/\(Self.formatVersion)")
        lines.append("id: \(id.rawValue)")
        lines.append("client: \(client.rawValue)")
        lines.append("written: \(VaultDate.utcString(written))")
        lines.append("device: \(device)")
        lines.append("status: \(status.rawValue)")
        lines.append("retention: \(retentionBasis.encodedString)")
        if let lastContactOverride {
            lines.append("last-contact: \(VaultDate.utcString(lastContactOverride))")
        }
        for key in extraHeaders.keys.sorted() {
            lines.append("\(key): \(extraHeaders[key] ?? "")")
        }
        lines.append("")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public static func parse(_ data: Data) throws -> ClientMetadataEvent {
        guard let text = String(data: data, encoding: .utf8) else {
            throw VaultError.malformedNote("the client record is not valid UTF-8 text")
        }
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalised.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let magicLine = lines.first else {
            throw VaultError.malformedNote("the client record is empty")
        }
        let magicParts = magicLine.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard magicParts.count == 2, magicParts[0] == magic, let version = Int(magicParts[1]) else {
            throw VaultError.malformedNote("this is not a Notes Vault client record")
        }
        guard version <= formatVersion else {
            throw VaultError.unsupportedNoteFormat(version)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        func required(_ key: String) throws -> String {
            guard let value = headers[key], !value.isEmpty else {
                throw VaultError.malformedNote("the client record has no \"\(key)\" header")
            }
            return value
        }

        guard let written = VaultDate.parse(try required("written")) else {
            throw VaultError.malformedNote("the client record has an unreadable written date")
        }
        let status = ClientStatus(rawValue: try required("status")) ?? .active
        let retention = try RetentionBasis(encoded: headers["retention"] ?? "adult")

        let known: Set<String> = ["id", "client", "written", "device", "status", "retention", "last-contact"]

        return ClientMetadataEvent(
            id: try NoteID(try required("id")),
            client: try ClientCode(try required("client")),
            written: written,
            device: headers["device"] ?? "unknown",
            status: status,
            retentionBasis: retention,
            lastContactOverride: headers["last-contact"].flatMap { VaultDate.parse($0) },
            extraHeaders: headers.filter { !known.contains($0.key) }
        )
    }

    public var filename: String {
        "\(VaultDate.filenameStamp(written))-\(device.asFilenameSlug())-\(id.shortSuffix).client"
    }

    /// The current state of a client, from the whole log. Latest write wins; ties break on
    /// the ID, which is time-ordered, so the fold is deterministic on every device.
    public static func fold(_ events: [ClientMetadataEvent]) -> ClientMetadataEvent? {
        events.max { lhs, rhs in
            if lhs.written == rhs.written { return lhs.id < rhs.id }
            return lhs.written < rhs.written
        }
    }
}

public extension Calendar {
    /// Retention dates are compared across devices and time zones; anchoring them to UTC
    /// keeps "due on the 14th" from being due a day apart on a Mac and an iPhone.
    static var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }
}
