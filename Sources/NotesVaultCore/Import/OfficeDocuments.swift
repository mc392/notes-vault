import Foundation

/// The smallest XML reader that can get text out of an Office file.
///
/// Not a parser — it does not build a tree, validate anything or resolve namespaces. It
/// walks tags and hands them to a caller that knows what it is looking for. That is all
/// `.docx` and `.xlsx` need, and it keeps a document a counsellor was sent by email away
/// from anything with an entity resolver in it.
enum XMLScanner {
    struct Tag {
        let name: String       // lower-cased, namespace stripped: `w:t` → `t`
        let qualified: String  // as written: `w:t`
        let isClosing: Bool
        let isSelfClosing: Bool
        let raw: String

        func attribute(_ key: String) -> String? {
            guard let keyRange = raw.range(of: "\(key)=\"") else { return nil }
            let rest = raw[keyRange.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return HTMLText.decodeEntities(String(rest[rest.startIndex..<end]))
        }
    }

    /// Walks the document, calling `onTag` for every tag and `onText` for the character
    /// data between them.
    static func scan(_ xml: String, onTag: (Tag) -> Void, onText: (String) -> Void) {
        var index = xml.startIndex
        var text = ""

        func flush() {
            if !text.isEmpty {
                onText(HTMLText.decodeEntities(text))
                text = ""
            }
        }

        while index < xml.endIndex {
            let character = xml[index]
            guard character == "<" else {
                text.append(character)
                index = xml.index(after: index)
                continue
            }
            // CDATA is where Evernote keeps the note itself. Treated as a tag it would be
            // parsed as markup and the note would come out empty.
            if xml[index...].hasPrefix("<![CDATA[") {
                let start = xml.index(index, offsetBy: 9)
                if let end = xml.range(of: "]]>", range: start..<xml.endIndex) {
                    flush()
                    onText(String(xml[start..<end.lowerBound]))
                    index = end.upperBound
                    continue
                }
            }
            guard let close = xml[index...].firstIndex(of: ">") else { break }
            flush()

            let body = String(xml[xml.index(after: index)..<close])
            if !body.hasPrefix("?") && !body.hasPrefix("!") {
                let isClosing = body.hasPrefix("/")
                let isSelfClosing = body.hasSuffix("/")
                let trimmed = body.drop(while: { $0 == "/" })
                let qualified = String(trimmed.prefix { !$0.isWhitespace && $0 != "/" })
                let name = qualified.split(separator: ":").last.map(String.init)?.lowercased() ?? qualified.lowercased()
                onTag(Tag(name: name, qualified: qualified, isClosing: isClosing, isSelfClosing: isSelfClosing, raw: body))
            }
            index = xml.index(after: close)
        }
        flush()
    }
}

/// Word documents.
///
/// A `.docx` is a zip with the text in `word/document.xml`. Only paragraph structure is
/// kept: headings, bold and colour are formatting, and a clinical note is text. Tables
/// come out row by row, which is enough to read but not enough to reconstruct — the review
/// screen shows exactly what will be stored, so a table that came out badly is visible
/// before anything is written rather than after.
public enum DocxDocument {
    public static func plainText(from data: Data) throws -> String {
        let archive = try ZipArchive.open(data)
        guard let documentData = try archive.data(for: "word/document.xml") else {
            throw ImportError.unsupportedFormat(
                name: "This Word file",
                detail: "it has no document part. If it is an older .doc, open it in Word and save it as .docx."
            )
        }
        let xml = String(decoding: documentData, as: UTF8.self)

        var output = ""
        var inTextRun = false
        var inDeletedRun = false

        XMLScanner.scan(xml) { tag in
            switch tag.name {
            case "t":
                if tag.isClosing { inTextRun = false } else if !tag.isSelfClosing { inTextRun = true }
            case "deltext":
                inDeletedRun = !tag.isClosing
            case "del":
                // Text someone deleted with track-changes on. It is not part of the record.
                inDeletedRun = !tag.isClosing
            case "p":
                if tag.isClosing { output.append("\n") }
            case "br", "cr":
                output.append("\n")
            case "tab":
                output.append("\t")
            case "tc":
                if tag.isClosing { output.append("\t") }
            case "tr":
                if tag.isClosing { output.append("\n") }
            default:
                break
            }
        } onText: { text in
            if inTextRun && !inDeletedRun { output.append(text) }
        }

        let tidied = HTMLText.tidy(output)
        guard !tidied.isEmpty else { throw ImportError.noTextFound("This Word file") }
        return tidied
    }
}

/// Excel workbooks, read as a table so they land in the same mapping screen as a CSV.
public enum XlsxWorkbook {
    /// Excel's day zero. Serial 1 is 1 January 1900, but the format also believes 1900 was
    /// a leap year — so counting from 30 December 1899 gives the right answer for every
    /// date after February 1900, which is every date anyone will ever import.
    ///
    /// Counted in the counsellor's own time zone rather than in UTC, because a spreadsheet
    /// date is a day on a calendar and not an instant. Treating 46187 as a UTC instant puts
    /// a British summer session at one in the morning, and puts an American one on the day
    /// before — which is a session note filed under the wrong date.
    public static func date(fromSerial serial: Double, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var epochComponents = DateComponents()
        epochComponents.year = 1899
        epochComponents.month = 12
        epochComponents.day = 30
        guard let start = calendar.date(from: epochComponents) else {
            return Date(timeIntervalSince1970: -2_209_161_600 + serial * 86_400)
        }
        let wholeDays = Int(serial.rounded(.down))
        let partOfDay = (serial - Double(wholeDays)) * 86_400
        guard let day = calendar.date(byAdding: .day, value: wholeDays, to: start) else { return start }
        return day.addingTimeInterval(partOfDay.rounded())
    }

    /// Serial numbers that could plausibly be a date in a clinical record: 1990 to 2100.
    /// Outside that a bare number in a date column is much more likely to be a session
    /// count or a fee, and guessing would be worse than leaving it for the counsellor.
    public static func looksLikeDateSerial(_ value: Double) -> Bool {
        value >= 32_874 && value <= 73_415
    }

    public static func table(from data: Data) throws -> DelimitedTable {
        let archive = try ZipArchive.open(data)
        let shared = try sharedStrings(archive)

        // The first worksheet, by the file naming the format uses. Picking by name rather
        // than by following workbook.xml's relationship ids costs nothing here and cannot
        // fail on a workbook whose rels are written unusually.
        let sheetPaths = archive.paths
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
            .sorted()
        guard let sheetPath = sheetPaths.first(where: { $0 == "xl/worksheets/sheet1.xml" }) ?? sheetPaths.first,
              let sheetData = try archive.data(for: sheetPath) else {
            throw ImportError.unsupportedFormat(name: "This spreadsheet", detail: "it has no worksheet in it.")
        }

        var grid: [[String]] = []
        var row: [String] = []
        var cellColumn = 0
        var cellType = ""
        var inValue = false
        var inInlineString = false
        var value = ""

        XMLScanner.scan(String(decoding: sheetData, as: UTF8.self)) { tag in
            switch tag.name {
            case "row":
                if tag.isClosing {
                    grid.append(row)
                    row = []
                } else if !tag.isSelfClosing {
                    row = []
                }
            case "c":
                if tag.isClosing {
                    let resolved: String
                    if cellType == "s", let index = Int(value.trimmingCharacters(in: .whitespaces)), index < shared.count {
                        resolved = shared[index]
                    } else {
                        resolved = value
                    }
                    while row.count < cellColumn { row.append("") }
                    row.append(resolved)
                    value = ""
                    cellType = ""
                } else {
                    value = ""
                    cellType = tag.attribute("t") ?? ""
                    cellColumn = tag.attribute("r").map(columnIndex(fromReference:)) ?? row.count
                    if tag.isSelfClosing {
                        while row.count < cellColumn { row.append("") }
                        row.append("")
                    }
                }
            case "v":
                inValue = !tag.isClosing && !tag.isSelfClosing
            case "is":
                inInlineString = !tag.isClosing
            case "t":
                if inInlineString { inValue = !tag.isClosing && !tag.isSelfClosing }
            default:
                break
            }
        } onText: { text in
            if inValue { value += text }
        }

        guard !grid.isEmpty else { throw ImportError.noTextFound("This spreadsheet") }

        let width = grid.map(\.count).max() ?? 0
        for index in grid.indices {
            while grid[index].count < width { grid[index].append("") }
        }
        // Trailing rows of nothing are what a spreadsheet's used range usually ends with.
        while let last = grid.last, last.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            grid.removeLast()
        }
        guard let first = grid.first else { throw ImportError.noTextFound("This spreadsheet") }

        if DelimitedTable.looksLikeHeader(first) {
            return DelimitedTable(
                columns: first.enumerated().map { offset, name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? "Column \(offset + 1)" : trimmed
                },
                rows: Array(grid.dropFirst()),
                separator: ",",
                hadHeaderRow: true
            )
        }
        return DelimitedTable(
            columns: (1...max(width, 1)).map { "Column \($0)" },
            rows: grid,
            separator: ",",
            hadHeaderRow: false
        )
    }

    private static func sharedStrings(_ archive: ZipArchive) throws -> [String] {
        guard let data = try archive.data(for: "xl/sharedStrings.xml") else { return [] }
        var strings: [String] = []
        var current = ""
        var depth = 0
        var inText = false

        XMLScanner.scan(String(decoding: data, as: UTF8.self)) { tag in
            switch tag.name {
            case "si":
                if tag.isClosing {
                    strings.append(current)
                    current = ""
                    depth = 0
                } else {
                    current = ""
                    depth = 1
                }
            case "t":
                inText = depth > 0 && !tag.isClosing && !tag.isSelfClosing
            default:
                break
            }
        } onText: { text in
            if inText { current += text }
        }
        return strings
    }

    /// `B7` → 1. Cells with nothing in them are simply absent from the XML, so without
    /// this every row after a blank cell would be shifted one column left — and a note
    /// would end up filed under the wrong client.
    static func columnIndex(fromReference reference: String) -> Int {
        var index = 0
        for character in reference.uppercased() {
            guard let ascii = character.asciiValue, character.isLetter else { break }
            index = index * 26 + Int(ascii - 64)
        }
        return max(0, index - 1)
    }
}
