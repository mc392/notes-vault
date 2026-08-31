import Foundation

/// What kind of file this is. Detected from the contents first and the extension second,
/// because a file emailed between two machines has usually lost or gained an extension on
/// the way.
public enum ImportFormat: String, Sendable, CaseIterable {
    case plainText
    case markdown
    case delimited
    case richText
    case html
    case word
    case spreadsheet
    case evernote
    case pdf
    case unsupported

    public var displayName: String {
        switch self {
        case .plainText: return "Text"
        case .markdown: return "Markdown"
        case .delimited: return "Spreadsheet (CSV)"
        case .richText: return "Rich text"
        case .html: return "Web page"
        case .word: return "Word document"
        case .spreadsheet: return "Excel workbook"
        case .evernote: return "Evernote export"
        case .pdf: return "PDF"
        case .unsupported: return "Not readable"
        }
    }

    /// True when the file is a table and cannot become notes until the counsellor says
    /// which column is which.
    public var needsColumnMapping: Bool {
        self == .delimited || self == .spreadsheet
    }

    public static func detect(filename: String, data: Data) -> ImportFormat {
        // Contents win. A `.txt` that is really a PDF, or a `.docx` renamed by a mail
        // client, is common enough that trusting the extension alone produces nonsense.
        if data.starts(with: Array("%PDF".utf8)) { return .pdf }
        if data.starts(with: Array("{\\rtf".utf8)) { return .richText }
        if ZipArchive.looksLikeZip(data) {
            if let archive = try? ZipArchive.open(data) {
                if archive.entry(at: "word/document.xml") != nil { return .word }
                if archive.paths.contains(where: { $0.hasPrefix("xl/worksheets/") }) { return .spreadsheet }
            }
            return .unsupported
        }

        let extensionName = (filename as NSString).pathExtension.lowercased()
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()

        if extensionName == "enex" || head.contains("<en-export") { return .evernote }
        if extensionName == "html" || extensionName == "htm" || extensionName == "xhtml" { return .html }
        if head.contains("<!doctype html") || head.contains("<html") { return .html }

        switch extensionName {
        case "csv", "tsv", "tab": return .delimited
        case "md", "markdown", "mdown", "mkd": return .markdown
        case "rtf": return .richText
        case "txt", "text", "log", "": break
        case "doc", "pages", "numbers", "key", "odt", "ods", "xls", "one", "webarchive":
            return .unsupported
        default: break
        }

        guard !data.isEmpty, String(data: data.prefix(4096), encoding: .utf8) != nil else {
            return .unsupported
        }
        if looksTabular(head) { return .delimited }
        return extensionName == "md" ? .markdown : .plainText
    }

    /// Several lines that all have the same number of separators. Weak on purpose — being
    /// wrong here only means the counsellor sees a mapping screen they did not need, or a
    /// plain note they can still import.
    private static func looksTabular(_ head: String) -> Bool {
        let lines = head.components(separatedBy: "\n").prefix(6).filter { !$0.isEmpty }
        guard lines.count >= 2 else { return false }
        for separator in [",", "\t", ";"] {
            let counts = lines.map { $0.components(separatedBy: separator).count - 1 }
            if let first = counts.first, first >= 1, counts.allSatisfy({ $0 == first }) { return true }
        }
        return false
    }
}

/// One file the counsellor pointed at. The bytes are already in memory, and this type is
/// the only thing the importer ever sees of the filesystem — which is what lets every
/// parser in this module be tested without a disk.
public struct ImportFile: Hashable, Sendable {
    /// Display name, e.g. `2026-06-14.txt`.
    public let name: String
    /// Path components below whatever the counsellor selected, e.g. `["Sarah M", "2026-06-14.txt"]`.
    /// Empty when they picked individual files.
    public let relativePath: [String]
    public let data: Data
    /// The file's own modification date — the fallback when nothing inside it says when
    /// the session was, and always shown as a fallback rather than presented as fact.
    public let modified: Date?

    public init(name: String, relativePath: [String] = [], data: Data, modified: Date? = nil) {
        self.name = name
        self.relativePath = relativePath
        self.data = data
        self.modified = modified
    }

    public var stem: String { (name as NSString).deletingPathExtension }
}

/// How the counsellor's files map onto clients.
public enum ImportGrouping: Hashable, Sendable {
    /// One folder per client, which is how most people who kept files did it.
    case folder
    /// One file per client.
    case filename
    /// Everything selected belongs to one client.
    case wholeSelection(String)

    public var displayName: String {
        switch self {
        case .folder: return "The folder each file is in"
        case .filename: return "The file's name"
        case .wholeSelection: return "All of it is one client"
        }
    }
}

public struct ImportOptions: Sendable {
    /// UK dates. `06/07/2026` is 6 July. Off means the American reading.
    public var dayFirst: Bool
    /// Cut a long document into one note per dated entry.
    public var splitLongDocuments: Bool
    public var grouping: ImportGrouping
    public var timeZone: TimeZone
    /// A ceiling so a mis-selected disk image does not get pulled into memory in one go.
    public var maximumFileBytes: Int

    public init(
        dayFirst: Bool = true,
        splitLongDocuments: Bool = true,
        grouping: ImportGrouping = .folder,
        timeZone: TimeZone = .current,
        maximumFileBytes: Int = 25 * 1024 * 1024
    ) {
        self.dayFirst = dayFirst
        self.splitLongDocuments = splitLongDocuments
        self.grouping = grouping
        self.timeZone = timeZone
        self.maximumFileBytes = maximumFileBytes
    }

    public static let `default` = ImportOptions()
}

/// What came out of one file.
public struct ImportFileResult: Sendable {
    public let file: String
    public let format: ImportFormat
    /// Notes we can already describe.
    public let items: [ImportedItem]
    /// Set instead of `items` when the file is a table: it cannot become notes until the
    /// counsellor says which column holds the client, the date and the note.
    public let table: DelimitedTable?
    public let issues: [VaultIssue]

    public init(file: String, format: ImportFormat, items: [ImportedItem], table: DelimitedTable?, issues: [VaultIssue]) {
        self.file = file
        self.format = format
        self.items = items
        self.table = table
        self.issues = issues
    }

    public var needsMapping: Bool { table != nil }
}

/// Turning files into proposed notes.
///
/// Nothing in here writes, encrypts or touches the vault. That separation is the point: by
/// the time anything is encrypted the counsellor has already seen, on screen, every note
/// that will be created and which client it will be filed under.
public enum ImportReader {
    /// - Parameter extractText: supplied by the app layer for formats that need a platform
    ///   framework — today only PDF, which needs PDFKit. Core stays free of it so every
    ///   other format is testable with `swift test`.
    public static func read(
        _ file: ImportFile,
        options: ImportOptions = .default,
        now: Date = Date(),
        extractText: ((ImportFile) throws -> String)? = nil
    ) -> ImportFileResult {
        let format = ImportFormat.detect(filename: file.name, data: file.data)

        guard file.data.count <= options.maximumFileBytes else {
            return failure(file, format, ImportError.fileTooLarge(
                name: file.name,
                megabytes: file.data.count / 1_048_576
            ))
        }

        do {
            switch format {
            case .plainText, .markdown:
                return try textResult(file, format: format, text: decodeText(file), options: options, now: now)

            case .richText:
                let text = RTFText.plainText(from: decodeText(file))
                return try textResult(file, format: format, text: text, options: options, now: now)

            case .html:
                let text = HTMLText.plainText(from: decodeText(file))
                return try textResult(file, format: format, text: text, options: options, now: now)

            case .word:
                let text = try DocxDocument.plainText(from: file.data)
                return try textResult(file, format: format, text: text, options: options, now: now)

            case .pdf:
                guard let extractText else {
                    return failure(file, format, ImportError.unsupportedFormat(
                        name: file.name,
                        detail: "PDF text can only be read in the app itself."
                    ))
                }
                let text = try extractText(file)
                return try textResult(file, format: format, text: text, options: options, now: now)

            case .delimited:
                let table = DelimitedTable.parse(decodeText(file))
                guard !table.isEmpty else { throw ImportError.noTextFound(file.name) }
                return ImportFileResult(file: file.name, format: format, items: [], table: table, issues: [])

            case .spreadsheet:
                let table = try XlsxWorkbook.table(from: file.data)
                return ImportFileResult(file: file.name, format: format, items: [], table: table, issues: [])

            case .evernote:
                return evernoteResult(file, options: options, now: now)

            case .unsupported:
                return failure(file, format, ImportError.notReadableAsText(file.name))
            }
        } catch {
            return failure(file, format, error)
        }
    }

    // MARK: - Grouping

    /// Which client-shaped bucket this file falls in, before any code is assigned.
    public static func groupKey(for file: ImportFile, grouping: ImportGrouping) -> String {
        // An `.rtfd` is a folder pretending to be a file. Without this, importing a folder
        // of them would group every note under "Session 4.rtfd" instead of the client.
        let components = file.relativePath.dropLast().filter { !$0.lowercased().hasSuffix(".rtfd") }

        switch grouping {
        case .folder:
            if let folder = components.first, !folder.isEmpty { return folder }
            return displayStem(file)
        case .filename:
            return displayStem(file)
        case let .wholeSelection(key):
            return key
        }
    }

    private static func displayStem(_ file: ImportFile) -> String {
        if let bundle = file.relativePath.dropLast().last, bundle.lowercased().hasSuffix(".rtfd") {
            return (bundle as NSString).deletingPathExtension
        }
        return file.stem
    }

    // MARK: - Building items

    private static func textResult(
        _ file: ImportFile,
        format: ImportFormat,
        text: String,
        options: ImportOptions,
        now: Date
    ) throws -> ImportFileResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.noTextFound(file.name) }

        let group = groupKey(for: file, grouping: options.grouping)
        let title = displayStem(file)

        let sections = options.splitLongDocuments
            ? SessionSplitter.split(trimmed, dayFirst: options.dayFirst, timeZone: options.timeZone, now: now)
            : [TextSection(
                heading: nil,
                date: ImportDates.first(in: trimmed, dayFirst: options.dayFirst, timeZone: options.timeZone, now: now),
                text: trimmed
              )]

        let items = sections.enumerated().map { offset, section -> ImportedItem in
            ImportedItem(
                origin: ImportOrigin(
                    container: file.name,
                    locator: sections.count > 1 ? "entry \(offset + 1) of \(sections.count)" : nil
                ),
                sourceTitle: sections.count > 1 ? (section.heading ?? title) : title,
                groupKey: group,
                date: resolveDate(section.date, file: file),
                body: section.text
            )
        }
        return ImportFileResult(file: file.name, format: format, items: items, table: nil, issues: [])
    }

    private static func evernoteResult(_ file: ImportFile, options: ImportOptions, now: Date) -> ImportFileResult {
        let notes = EnexDocument.notes(from: decodeText(file))
        let group = groupKey(for: file, grouping: options.grouping)

        var items: [ImportedItem] = []
        var issues: [VaultIssue] = []

        for (offset, note) in notes.enumerated() {
            guard !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                issues.append(VaultIssue(
                    location: "\(file.name) · note \(offset + 1)",
                    message: "This note had no text in it — probably an attachment or a drawing, which this app does not import."
                ))
                continue
            }
            // Evernote's own created date is a real timestamp, so it beats anything the
            // text happens to mention — but a date written in the note wins over it,
            // because that is what the counsellor typed as the session date.
            let inText = ImportDates.first(in: note.body, dayFirst: options.dayFirst, timeZone: options.timeZone, now: now)
                ?? note.title.flatMap { ImportDates.first(in: $0, dayFirst: options.dayFirst, timeZone: options.timeZone, now: now) }

            let date: ImportedDate
            if let inText {
                date = .found(inText.date, raw: inText.raw)
            } else if let created = note.created {
                date = .fromFile(created)
            } else {
                date = .unknown
            }

            items.append(ImportedItem(
                origin: ImportOrigin(container: file.name, locator: "note \(offset + 1) of \(notes.count)"),
                sourceTitle: note.title,
                groupKey: group,
                date: date,
                body: note.body
            ))
        }
        return ImportFileResult(file: file.name, format: .evernote, items: items, table: nil, issues: issues)
    }

    private static func resolveDate(_ parsed: ParsedDate?, file: ImportFile) -> ImportedDate {
        if let parsed { return .found(parsed.date, raw: parsed.raw) }
        if let modified = file.modified { return .fromFile(modified) }
        return .unknown
    }

    /// UTF-8, then Windows-1252 for the older files that are not. Never fails — a note
    /// with one odd character in it should still import, with the odd character visible.
    static func decodeText(_ file: ImportFile) -> String {
        if let text = String(data: file.data, encoding: .utf8) { return text }
        if let text = String(data: file.data, encoding: .windowsCP1252) { return text }
        return String(decoding: file.data, as: UTF8.self)
    }

    private static func failure(_ file: ImportFile, _ format: ImportFormat, _ error: Error) -> ImportFileResult {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return ImportFileResult(
            file: file.name,
            format: format,
            items: [],
            table: nil,
            issues: [VaultIssue(location: file.name, message: message)]
        )
    }
}
