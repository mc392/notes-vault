import Foundation

/// Which column holds what.
///
/// A spreadsheet is the one format that cannot be guessed into notes safely — the same
/// file might have the client in column A or column D, and putting a note under the wrong
/// client is the single worst thing this importer could do. So the mapping is explicit,
/// suggested but never assumed, and the review screen shows the result before anything is
/// written.
public struct ColumnMapping: Hashable, Sendable {
    public var client: Int?
    public var date: Int?
    /// Optional, for the spreadsheets that keep `09:30` in its own column.
    public var time: Int?
    public var title: Int?
    /// One or more columns making up the note. Several is normal — a sheet with
    /// Presenting / Intervention / Plan columns becomes one note with three headed parts.
    public var body: [Int]

    public init(client: Int? = nil, date: Int? = nil, time: Int? = nil, title: Int? = nil, body: [Int] = []) {
        self.client = client
        self.date = date
        self.time = time
        self.title = title
        self.body = body
    }

    public var isUsable: Bool { !body.isEmpty }

    /// A first guess from the column names, and from the data when the names say nothing.
    public static func suggest(for table: DelimitedTable) -> ColumnMapping {
        var mapping = ColumnMapping()
        var claimed = Set<Int>()

        func match(_ needles: [String]) -> Int? {
            for (index, column) in table.columns.enumerated() where !claimed.contains(index) {
                let name = column.lowercased()
                if needles.contains(where: { name == $0 }) { claimed.insert(index); return index }
            }
            for (index, column) in table.columns.enumerated() where !claimed.contains(index) {
                let name = column.lowercased()
                if needles.contains(where: { name.contains($0) }) { claimed.insert(index); return index }
            }
            return nil
        }

        if table.hadHeaderRow {
            mapping.client = match(["client", "client code", "code", "initials", "name", "clientname", "client name", "ref", "reference"])
            mapping.date = match(["date", "session date", "session", "when", "day", "appointment"])
            mapping.time = match(["time", "start", "start time"])
            mapping.title = match(["title", "subject", "heading", "topic"])
            let bodyColumns = table.columns.indices.filter { index in
                guard !claimed.contains(index) else { return false }
                let name = table.columns[index].lowercased()
                return ["note", "notes", "body", "content", "summary", "text", "entry", "comment",
                        "observation", "subjective", "objective", "assessment", "plan", "data",
                        "presenting", "intervention", "outcome"].contains { name.contains($0) }
            }
            mapping.body = bodyColumns
        }

        if mapping.date == nil {
            mapping.date = table.columns.indices
                .filter { !claimed.contains($0) }
                .max { lhs, rhs in dateLikeScore(table, lhs) < dateLikeScore(table, rhs) }
                .flatMap { dateLikeScore(table, $0) > 0.5 ? $0 : nil }
            if let index = mapping.date { claimed.insert(index) }
        }
        if mapping.body.isEmpty {
            // Whatever holds the most prose. A note column is always the longest one.
            if let widest = table.columns.indices
                .filter({ !claimed.contains($0) })
                .max(by: { averageLength(table, $0) < averageLength(table, $1) }),
               averageLength(table, widest) > 20 {
                mapping.body = [widest]
                claimed.insert(widest)
            }
        }
        if mapping.client == nil {
            // A client column repeats: few distinct values, all short.
            mapping.client = table.columns.indices
                .filter { !claimed.contains($0) && averageLength(table, $0) <= 40 }
                .min { lhs, rhs in table.distinctValues(inColumn: lhs).count < table.distinctValues(inColumn: rhs).count }
        }
        return mapping
    }

    private static func averageLength(_ table: DelimitedTable, _ index: Int) -> Double {
        guard !table.rows.isEmpty else { return 0 }
        let total = table.rows.reduce(0) { $0 + table.cell($1, at: index).count }
        return Double(total) / Double(table.rows.count)
    }

    /// The share of non-empty cells in a column that read as a date.
    private static func dateLikeScore(_ table: DelimitedTable, _ index: Int) -> Double {
        let sample = table.rows.prefix(40)
        var filled = 0
        var dates = 0
        for row in sample {
            let value = table.cell(row, at: index)
            guard !value.isEmpty else { continue }
            filled += 1
            if ImportDates.first(in: value) != nil { dates += 1 }
            else if let number = Double(value), XlsxWorkbook.looksLikeDateSerial(number) { dates += 1 }
        }
        guard filled > 0 else { return 0 }
        return Double(dates) / Double(filled)
    }
}

/// Turning a mapped table into proposed notes.
public enum TabularImport {
    public static func items(
        from table: DelimitedTable,
        mapping: ColumnMapping,
        container: String,
        options: ImportOptions = .default,
        modified: Date? = nil,
        now: Date = Date()
    ) -> (items: [ImportedItem], issues: [VaultIssue]) {
        var items: [ImportedItem] = []
        var issues: [VaultIssue] = []

        guard mapping.isUsable else {
            return ([], [VaultIssue(
                location: container,
                message: "No column was chosen to hold the note itself, so there is nothing to import from this file."
            )])
        }

        for (offset, row) in table.rows.enumerated() {
            // Spreadsheet row numbers as the counsellor sees them in Excel: one-based, and
            // one more again when the first row was the header.
            let rowNumber = offset + 1 + (table.hadHeaderRow ? 1 : 0)
            let locator = "row \(rowNumber)"

            let body = buildBody(table: table, row: row, mapping: mapping)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue // An empty row is padding, not a problem worth reporting.
            }

            let group: String
            if let clientColumn = mapping.client {
                let value = table.cell(row, at: clientColumn)
                if value.isEmpty {
                    issues.append(VaultIssue(
                        location: "\(container) · \(locator)",
                        message: "This row has no client in the “\(table.columns[safe: clientColumn] ?? "client")” column, so there is no way to say whose note it is. It was left out."
                    ))
                    continue
                }
                group = value
            } else {
                group = ImportReader.groupKey(
                    for: ImportFile(name: container, data: Data()),
                    grouping: options.grouping
                )
            }

            let date = resolveDate(table: table, row: row, mapping: mapping, options: options, modified: modified, now: now)

            items.append(ImportedItem(
                origin: ImportOrigin(container: container, locator: locator),
                sourceTitle: mapping.title.map { table.cell(row, at: $0) }.flatMap { $0.isEmpty ? nil : $0 },
                groupKey: group,
                date: date,
                body: body
            ))
        }
        return (items, issues)
    }

    private static func buildBody(table: DelimitedTable, row: [String], mapping: ColumnMapping) -> String {
        let parts: [String] = mapping.body.compactMap { index in
            let value = table.cell(row, at: index)
            guard !value.isEmpty else { return nil }
            guard mapping.body.count > 1, let name = table.columns[safe: index], table.hadHeaderRow else {
                return value
            }
            // Several columns become one note with the column names kept as headings,
            // because "Plan: review in a fortnight" reads as a record and a bare paragraph
            // of four concatenated cells does not.
            return "\(name)\n\(value)"
        }
        return parts.joined(separator: "\n\n")
    }

    private static func resolveDate(
        table: DelimitedTable,
        row: [String],
        mapping: ColumnMapping,
        options: ImportOptions,
        modified: Date?,
        now: Date
    ) -> ImportedDate {
        guard let dateColumn = mapping.date else {
            return modified.map { ImportedDate.fromFile($0) } ?? .unknown
        }
        let raw = table.cell(row, at: dateColumn)
        var base: Date?
        var rawText = raw

        if let parsed = ImportDates.first(in: raw, dayFirst: options.dayFirst, timeZone: options.timeZone, now: now) {
            base = parsed.date
        } else if let serial = Double(raw), XlsxWorkbook.looksLikeDateSerial(serial) {
            // Excel keeps dates as a day count. The cell shows "14/06/2026" and holds
            // 46187, and the counsellor has no idea the file works that way — so say so
            // in the review row rather than showing them a number.
            base = XlsxWorkbook.date(fromSerial: serial, timeZone: options.timeZone)
            rawText = "\(raw) (an Excel date)"
        }

        guard let day = base else {
            return modified.map { ImportedDate.fromFile($0) } ?? .unknown
        }

        if let timeColumn = mapping.time {
            let timeText = table.cell(row, at: timeColumn)
            if !timeText.isEmpty,
               let combined = ImportDates.first(
                   in: "\(VaultDate.filenameStamp(day, timeZone: options.timeZone).prefix(10)) \(timeText)",
                   dayFirst: options.dayFirst,
                   timeZone: options.timeZone,
                   now: now
               ), combined.hasTime {
                return .found(combined.date, raw: "\(rawText) \(timeText)")
            }
        }
        return .found(day, raw: rawText)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
