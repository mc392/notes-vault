import Foundation

/// A CSV or TSV file, read as rows of strings.
///
/// Written here rather than pulled in, because the whole file is thirty lines of state
/// machine and the alternative is a dependency inside the one code path that handles a
/// counsellor's unencrypted clinical history. Quoted fields, doubled quotes and newlines
/// inside a quoted cell are all handled — a note body in a spreadsheet cell is *always*
/// multi-line, so the naive `split(separator: ",")` version of this would silently shred
/// exactly the files people most want to import.
public struct DelimitedTable: Hashable, Sendable {
    /// Column names. Synthesised as "Column 1", "Column 2"… when the file had no header row.
    public let columns: [String]
    public let rows: [[String]]
    public let separator: Character
    public let hadHeaderRow: Bool

    public init(columns: [String], rows: [[String]], separator: Character, hadHeaderRow: Bool) {
        self.columns = columns
        self.rows = rows
        self.separator = separator
        self.hadHeaderRow = hadHeaderRow
    }

    public var isEmpty: Bool { rows.isEmpty }

    public func cell(_ row: [String], at index: Int?) -> String {
        guard let index, index >= 0, index < row.count else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything in one column, for the "which column holds the client?" preview.
    public func distinctValues(inColumn index: Int, limit: Int = 200) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for row in rows {
            let value = cell(row, at: index)
            guard !value.isEmpty, !seen.contains(value) else { continue }
            seen.insert(value)
            ordered.append(value)
            if ordered.count >= limit { break }
        }
        return ordered
    }

    // MARK: - Parsing

    public static func parse(_ text: String, separator explicit: Character? = nil) -> DelimitedTable {
        var source = text
        // Excel writes a UTF-8 BOM. Left in place it becomes part of the first column name,
        // and the mapping screen offers a column called "﻿Client" that never matches.
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }

        let separator = explicit ?? sniffSeparator(source)
        var grid = splitRows(source, separator: separator)
        guard !grid.isEmpty else {
            return DelimitedTable(columns: [], rows: [], separator: separator, hadHeaderRow: false)
        }

        let width = grid.map(\.count).max() ?? 0
        for index in grid.indices {
            while grid[index].count < width { grid[index].append("") }
        }

        let first = grid[0]
        if looksLikeHeader(first) {
            return DelimitedTable(
                columns: first.enumerated().map { offset, name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? "Column \(offset + 1)" : trimmed
                },
                rows: Array(grid.dropFirst()),
                separator: separator,
                hadHeaderRow: true
            )
        }
        return DelimitedTable(
            columns: (1...max(width, 1)).map { "Column \($0)" },
            rows: grid,
            separator: separator,
            hadHeaderRow: false
        )
    }

    /// Tab, semicolon or comma, whichever appears most in the first line outside quotes.
    /// A European Excel export is semicolon-separated and would otherwise arrive as one
    /// enormous column.
    static func sniffSeparator(_ text: String) -> Character {
        var counts: [Character: Int] = [",": 0, "\t": 0, ";": 0]
        var inQuotes = false
        for character in text {
            if character == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if character == "\n" || character == "\r" { break }
            if counts[character] != nil { counts[character]! += 1 }
        }
        return counts.max { lhs, rhs in
            if lhs.value == rhs.value { return rhs.key == "," }
            return lhs.value < rhs.value
        }?.key ?? ","
    }

    private static func splitRows(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            // A trailing newline should not produce a row of one empty cell.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while index < text.endIndex {
            let character = text[index]
            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case separator:
                    endField()
                case "\r":
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\n" { index = next }
                    endRow()
                case "\n":
                    endRow()
                default:
                    field.append(character)
                }
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// A first row is a header when it reads like labels rather than data: every cell
    /// filled, none of them a date or a bare number, all distinct, none of them a
    /// paragraph. Guessing wrong in either direction is visible on the mapping screen and
    /// changeable there, so this only has to be right most of the time.
    static func looksLikeHeader(_ row: [String]) -> Bool {
        guard !row.isEmpty else { return false }
        let cells = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard cells.allSatisfy({ !$0.isEmpty && $0.count <= 60 && !$0.contains("\n") }) else { return false }
        guard Set(cells).count == cells.count else { return false }
        for cell in cells {
            if Double(cell) != nil { return false }
            if ImportDates.first(in: cell) != nil { return false }
        }
        return true
    }
}
