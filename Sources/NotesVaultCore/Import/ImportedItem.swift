import Foundation

/// Where one imported note came from, in the counsellor's words rather than the parser's.
///
/// This is shown in the review list *and* written into the note as an `imported-from`
/// header, so a note that came out of a spreadsheet three years from now still says which
/// spreadsheet and which row. A clinical record that cannot say where it came from is
/// worth less than one that can.
public struct ImportOrigin: Hashable, Sendable, CustomStringConvertible {
    /// The file, folder or paste it arrived in — `sessions.csv`, `Client notes.docx`.
    public let container: String
    /// Which part of it — `row 12`, `note 3 of 40`, `page 2`. Nil when the whole file was
    /// one note.
    public let locator: String?

    public init(container: String, locator: String? = nil) {
        self.container = container
        self.locator = locator
    }

    public var description: String {
        guard let locator else { return container }
        return "\(container) · \(locator)"
    }
}

/// How confident we are about when the session happened.
///
/// The distinction is deliberate and survives into the vault. A date lifted out of the
/// text is evidence; a file's modification date is a guess that happens to be a date, and
/// a note carrying one is marked so nobody later mistakes it for the real appointment.
public enum ImportedDate: Hashable, Sendable {
    /// Read out of the source, with the text it was read from kept for the review screen.
    case found(Date, raw: String)
    /// Nothing in the source said when — this is the file's own timestamp.
    case fromFile(Date)
    /// Nothing at all. The counsellor has to supply one before this item can be imported.
    case unknown

    public var date: Date? {
        switch self {
        case let .found(date, _): return date
        case let .fromFile(date): return date
        case .unknown: return nil
        }
    }

    public var isCertain: Bool {
        if case .found = self { return true }
        return false
    }

    /// What the review row says under the date.
    public var explanation: String {
        switch self {
        case let .found(_, raw): return "read from “\(raw)”"
        case .fromFile: return "the file's own date — not the session date"
        case .unknown: return "no date found"
        }
    }
}

/// One note-shaped thing found in something the counsellor pointed at.
///
/// Nothing here has reached the vault. It has no client code yet, because the source
/// almost certainly identified the client by name and this app has nowhere to put a name —
/// the counsellor maps `groupKey` to one of their own codes before anything is written.
public struct ImportedItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let origin: ImportOrigin
    /// Whatever the source called this: a note title, a filename, a spreadsheet cell. It
    /// may well be a real name, which is why it is kept separate from the body and never
    /// written to the vault on its own.
    public let sourceTitle: String?
    /// The value the counsellor maps to a client code. Usually a name, a folder or a
    /// spreadsheet column — the thing that says "these forty notes are all one person".
    public let groupKey: String
    public let date: ImportedDate
    public let body: String

    public init(
        id: UUID = UUID(),
        origin: ImportOrigin,
        sourceTitle: String? = nil,
        groupKey: String,
        date: ImportedDate,
        body: String
    ) {
        self.id = id
        self.origin = origin
        self.sourceTitle = sourceTitle
        self.groupKey = groupKey
        self.date = date
        self.body = body
    }

    public var wordCount: Int { body.wordCount }

    /// First line or so, for the review list. Never more than one line: the review screen
    /// is likely to be looked at over someone's shoulder.
    public func preview(limit: Int = 90) -> String {
        let firstLine = body
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if firstLine.count <= limit { return firstLine }
        return String(firstLine.prefix(limit)) + "…"
    }

    /// A stable fingerprint of the content, used to collapse the same note appearing twice
    /// in one selection — a folder exported twice, or a file that is also inside a zip.
    public var contentFingerprint: String {
        let normalised = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Data((groupKey + "\u{1}" + normalised).utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
