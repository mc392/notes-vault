import Foundation

/// Which template a note was started from — an identifier and nothing else.
///
/// Deliberately **not** an enum. The headings a counsellor works to are theirs, not ours,
/// and decision 07 said templates are configurable; a closed set of three could not honour
/// that. The identifier is what goes in the note file (`template: soap`), so it has to be
/// something a note written today still reads back as years from now, on a device that has
/// never heard of the template it names.
///
/// What each one is *called* and what it prefills live in `NoteTemplateSettings`, which is
/// a device setting like the note fields. That split is what lets a note carry a template
/// this device knows nothing about and still read back sensibly — `displayName` falls back
/// to the identifier, which for a template made in this app is the counsellor's own words
/// with the punctuation taken out.
public struct NoteTemplate: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    public let rawValue: String
    public var id: String { rawValue }

    /// Never fails. A note carrying a template header this build has never seen is not a
    /// damaged note, and refusing to read it would be the app losing a record over a label.
    /// An empty or blank header reads as freeform, which is what it means.
    public init(rawValue: String) {
        let cleaned = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.rawValue = cleaned.isEmpty ? Self.freeformIdentifier : cleaned
    }

    private static let freeformIdentifier = "freeform"

    /// The three this app has always shipped. They are ordinary templates — a counsellor's
    /// own sits beside them and behaves identically — they simply cannot be deleted.
    public static let freeform = NoteTemplate(rawValue: freeformIdentifier)
    public static let soap = NoteTemplate(rawValue: "soap")
    public static let dap = NoteTemplate(rawValue: "dap")

    /// What to call this template when nothing on this device knows better: the two
    /// abbreviations spelled the way anyone writing notes expects to see them, and anything
    /// else turned back from `trauma-review` into `Trauma review`.
    public var displayName: String {
        switch rawValue {
        case Self.freeformIdentifier: return "Freeform"
        case "soap": return "SOAP"
        case "dap": return "DAP"
        default:
            let words = rawValue.split(separator: "-").joined(separator: " ")
            guard let first = words.first else { return rawValue }
            return first.uppercased() + words.dropFirst()
        }
    }

    // Written and read as a bare string, so the note format and the index cache are byte
    // for byte what they were when this was an enum.
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One clinical session note.
///
/// Principle 04: a note is immutable. Nothing here has a setter and the store never opens
/// an existing file for writing. A correction is a *new* note carrying `supersedes`, which
/// is what gives the vault an audit trail without a separate audit feature, and what makes
/// the format immune to the multi-device write conflicts GroundWork has documented as an
/// open limitation.
public struct NoteRecord: Identifiable, Hashable, Sendable {
    /// Bumped only when an older build would *misread* a newer note — the same rule
    /// GroundWork's own schema version follows.
    public static let formatVersion = 1
    public static let magic = "notesvault"

    public let id: NoteID
    public let client: ClientCode
    /// When the session happened.
    public let session: Date
    /// The UTC offset the session was recorded in, so the appointment time reads back the
    /// way it was written.
    public let sessionUTCOffset: Int
    /// When this file was written. For a correction this is later than `session`.
    public let written: Date
    /// Which device wrote it — part of the filename, so two devices never collide.
    public let device: String
    public let template: NoteTemplate
    /// Set when this note corrects or replaces an earlier one.
    public let supersedes: NoteID?
    /// Headers written by a future version of this format, kept so a note round-tripped
    /// through an older build cannot quietly lose them.
    public let extraHeaders: [String: String]
    public let body: String

    public var wordCount: Int { body.wordCount }
    public var isCorrection: Bool { supersedes != nil }

    public var sessionTimeZone: TimeZone {
        TimeZone(secondsFromGMT: sessionUTCOffset) ?? .current
    }

    public init(
        id: NoteID = NoteID(),
        client: ClientCode,
        session: Date,
        sessionUTCOffset: Int = TimeZone.current.secondsFromGMT(),
        written: Date = Date(),
        device: String,
        template: NoteTemplate = .freeform,
        supersedes: NoteID? = nil,
        extraHeaders: [String: String] = [:],
        body: String
    ) {
        self.id = id
        self.client = client
        self.session = session
        self.sessionUTCOffset = sessionUTCOffset
        self.written = written
        self.device = device
        self.template = template
        self.supersedes = supersedes
        self.extraHeaders = extraHeaders
        self.body = body
    }

    // MARK: - The stored format

    /// Plain UTF-8 text: a few `key: value` headers, a blank line, then the note.
    ///
    /// Principle 05, no lock-in. Once decrypted this is a file the counsellor can open in
    /// any text editor on any machine forever, with no reference to this app. That rules
    /// out a binary container or an embedded database, and it is worth more than the few
    /// bytes it costs.
    public func serialised() -> Data {
        var lines: [String] = []
        lines.append("\(Self.magic)/\(Self.formatVersion)")
        lines.append("id: \(id.rawValue)")
        lines.append("client: \(client.rawValue)")
        lines.append("session: \(VaultDate.localString(session, timeZone: sessionTimeZone))")
        lines.append("written: \(VaultDate.utcString(written))")
        lines.append("device: \(device)")
        lines.append("template: \(template.rawValue)")
        if let supersedes {
            lines.append("supersedes: \(supersedes.rawValue)")
        }
        for key in extraHeaders.keys.sorted() {
            lines.append("\(key): \(extraHeaders[key] ?? "")")
        }
        lines.append("")
        let text = lines.joined(separator: "\n") + "\n" + body
        return Data(text.utf8)
    }

    public static func parse(_ data: Data) throws -> NoteRecord {
        guard let text = String(data: data, encoding: .utf8) else {
            throw VaultError.malformedNote("the file is not valid UTF-8 text")
        }
        return try parse(text: text)
    }

    public static func parse(text: String) throws -> NoteRecord {
        // Normalise line endings first — a note that has been through a machine writing
        // CRLF is still the same note.
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var headerLines: [String] = []
        var body = ""
        var seenBlankLine = false
        var cursor = normalised.startIndex

        while cursor < normalised.endIndex {
            let lineEnd = normalised[cursor...].firstIndex(of: "\n") ?? normalised.endIndex
            let line = String(normalised[cursor..<lineEnd])
            let next = lineEnd < normalised.endIndex ? normalised.index(after: lineEnd) : normalised.endIndex

            if line.isEmpty {
                seenBlankLine = true
                body = String(normalised[next...])
                break
            }
            headerLines.append(line)
            cursor = next
        }

        guard let magicLine = headerLines.first else {
            throw VaultError.malformedNote("the file is empty")
        }
        guard seenBlankLine else {
            throw VaultError.malformedNote("there is no blank line between the headers and the note")
        }

        let magicParts = magicLine.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard magicParts.count == 2, magicParts[0] == magic, let version = Int(magicParts[1]) else {
            throw VaultError.malformedNote("this is not a Notes Vault note — the first line reads \"\(magicLine)\"")
        }
        guard version <= formatVersion else {
            throw VaultError.unsupportedNoteFormat(version)
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw VaultError.malformedNote("header line \"\(line)\" has no colon")
            }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        func required(_ key: String) throws -> String {
            guard let value = headers[key], !value.isEmpty else {
                throw VaultError.malformedNote("the note has no \"\(key)\" header")
            }
            return value
        }

        let id = try NoteID(try required("id"))
        let client = try ClientCode(try required("client"))

        let sessionRaw = try required("session")
        guard let session = VaultDate.parseWithOffset(sessionRaw) else {
            throw VaultError.malformedNote("\"\(sessionRaw)\" is not a readable session date")
        }
        let writtenRaw = try required("written")
        guard let written = VaultDate.parse(writtenRaw) else {
            throw VaultError.malformedNote("\"\(writtenRaw)\" is not a readable written date")
        }

        let template = NoteTemplate(rawValue: headers["template"] ?? "")

        var supersedes: NoteID?
        if let raw = headers["supersedes"], !raw.isEmpty {
            supersedes = try NoteID(raw)
        }

        let known: Set<String> = ["id", "client", "session", "written", "device", "template", "supersedes"]
        let extras = headers.filter { !known.contains($0.key) }

        return NoteRecord(
            id: id,
            client: client,
            session: session.date,
            sessionUTCOffset: session.offsetSeconds,
            written: written,
            device: headers["device"] ?? "unknown",
            template: template,
            supersedes: supersedes,
            extraHeaders: extras,
            body: body
        )
    }

    // MARK: - Filenames

    /// `2026-06-14T0930-iphone-k3m.note`
    ///
    /// Readable in the decrypted view, and carrying the device so the same client written
    /// up on a Mac and an iPhone in the same minute produces two files rather than one
    /// overwrite. The ciphertext name that reaches iCloud carries none of this.
    public var preferredFilename: String {
        "\(VaultDate.filenameStamp(session, timeZone: sessionTimeZone))-\(device.asFilenameSlug()).note"
    }

    /// Used only when `preferredFilename` is already taken — one client, one device, one
    /// minute, which in practice is a correction written straight after the original.
    public var disambiguatedFilename: String {
        "\(VaultDate.filenameStamp(session, timeZone: sessionTimeZone))-\(device.asFilenameSlug())-\(id.shortSuffix).note"
    }
}
