import XCTest
@testable import NotesVaultCore

private let london = TimeZone(identifier: "Europe/London")!
private let fixedNow = VaultDate.parse("2026-08-30T12:00:00Z")!
private let options = ImportOptions(dayFirst: true, splitLongDocuments: true, grouping: .folder, timeZone: london)

private func stamp(_ date: Date?) -> String? {
    date.map { VaultDate.filenameStamp($0, timeZone: london) }
}

/// Real Office files, deflated, built by a tool that is not this one.
///
/// Held as base64 rather than as files on disk so the whole importer stays testable with a
/// plain `swift test` and no resource bundle — and so the fixtures are visible in review
/// instead of being two opaque binaries nobody opens.
private enum OfficeFixture {
    static let docx = Data(base64Encoded:
        "UEsDBBQAAAAIAGmpHl0D0RfEnAAAAMQAAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbCWOSw6DMAxE" +
        "9z1F5D2EdlFVFYFFPyegB7CC+ajBiYhbwe0bytLzZsZT1svk1JfmOHo2cMwLUMTWtyP3Bl7NM7uA" +
        "ioLcovNMBlaKUFeHslkDRZXCHA0MIuGqdbQDTRhzH4gT6fw8oaRz7nVA+8ae9Kkoztp6FmLJZOuA" +
        "qrxThx8n6rEkeR+S4qBuu297ZQBDcKNFSVhvVFel/o+oflBLAwQUAAAACABpqR5dCLY+/TYBAACO" +
        "AgAAEQAAAHdvcmQvZG9jdW1lbnQueG1slZLNTsMwDMfvPIUVJG40bUETlLUTEuLGhY0HyBLTVstH" +
        "lWTr9va4VRlCm5i4WHFs//62k/libzTs0IfW2ZJlScoArXSqtXXJPlavtw8MQhRWCe0sluyAgS2q" +
        "q3lfKCe3Bm0EIthQ9CVrYuwKzoNs0IiQuA4txT6dNyKS62veO6867ySGQAJG8zxNZ9yI1rKKkGun" +
        "DiO7Gzw/mFgthRcNvMHN9UOe5U8g3dYG1JoA4FEScc6HvMH60XYnjOyek06e5jN4LO5SYS6XvLRB" +
        "bkNABUEjdgk81x7J+1V5zG6cQRpucz4KtAOwuI/QI26Sy+J59u9+33HXYk8NxgbPyExm7flJd0ta" +
        "olVAC8W/WlOoj0V0XtE4JGrcjjTXB4heyA3IRtgaw1D6nfMDGwkTlE+vPd5PP6n6AlBLAQIUAxQA" +
        "AAAIAGmpHl0D0RfEnAAAAMQAAAATAAAAAAAAAAAAAACAAQAAAABbQ29udGVudF9UeXBlc10ueG1s" +
        "UEsBAhQDFAAAAAgAaakeXQi2Pv02AQAAjgIAABEAAAAAAAAAAAAAAIABzQAAAHdvcmQvZG9jdW1l" +
        "bnQueG1sUEsFBgAAAAACAAIAgAAAADICAAAAAA=="
    )!

    static let xlsx = Data(base64Encoded:
        "UEsDBBQAAAAIAGmpHl0D0RfEnAAAAMQAAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbCWOSw6DMAxE" +
        "9z1F5D2EdlFVFYFFPyegB7CC+ajBiYhbwe0bytLzZsZT1svk1JfmOHo2cMwLUMTWtyP3Bl7NM7uA" +
        "ioLcovNMBlaKUFeHslkDRZXCHA0MIuGqdbQDTRhzH4gT6fw8oaRz7nVA+8ae9Kkoztp6FmLJZOuA" +
        "qrxThx8n6rEkeR+S4qBuu297ZQBDcKNFSVhvVFel/o+oflBLAwQUAAAACABpqR5d5fllkesAAAB5" +
        "AQAAFAAAAHhsL3NoYXJlZFN0cmluZ3MueG1sZY5BS8RADIXv/oowZ+1UDyrSdg8rCoIiruI5dLKd" +
        "wTZTJ+mu+++dIqtQL4G8l/e9VKuvoYcdJQmRa3NelAaI2+gCd7V5e707uzYgiuywj0y1OZCYVXNS" +
        "iSjkKEttvOp4Y620ngaUIo7E2dnGNKDmNXVWxkToxBPp0NuLsry0AwY20MaJtTZXBiYOnxOtj/vc" +
        "EJpKm3UfiLWy2lR2Vn7UDcn8MDhUWnpPUUl+xSNngwk9PC6P32P6IAcZJT3RCP7Q5T46BewSZQNh" +
        "7JGLf7iH6Blul7QX2gXa59hALrSo84v7oB7un/8QeYg231BLAwQUAAAACABpqR5d9/wU0NsAAADD" +
        "AQAAGAAAAHhsL3dvcmtzaGVldHMvc2hlZXQxLnhtbHWQ3U7DMAxG73mKyPfM/RllQkmmDcQTwANE" +
        "bVgrmqSKow7eHjNQFypxF/vY37Ei9x9uFLONNASvoNwUIKxvQzf4k4LXl+fbHQhKxndmDN4q+LQE" +
        "e30jzyG+U29tEhzgSUGf0vSASG1vnaFNmKxn8haiM4nLeEKaojXdZcmNWBVFg84MHrS89J5MMhwc" +
        "w1lEvoTb7ffjUIJICojrWRcSZy2x/WXHnJV/2WPOqoUh518t1WKpsul6ZWFGPxfNetuUu/uVKd/d" +
        "/mOqF1OdTd+tknLWrJPw+k0Sl//XX1BLAQIUAxQAAAAIAGmpHl0D0RfEnAAAAMQAAAATAAAAAAAA" +
        "AAAAAACAAQAAAABbQ29udGVudF9UeXBlc10ueG1sUEsBAhQDFAAAAAgAaakeXeX5ZZHrAAAAeQEA" +
        "ABQAAAAAAAAAAAAAAIABzQAAAHhsL3NoYXJlZFN0cmluZ3MueG1sUEsBAhQDFAAAAAgAaakeXff8" +
        "FNDbAAAAwwEAABgAAAAAAAAAAAAAAIAB6gEAAHhsL3dvcmtzaGVldHMvc2hlZXQxLnhtbFBLBQYA" +
        "AAAAAwADAMkAAAD7AgAAAAA="
    )!
}

final class ZipAndOfficeTests: XCTestCase {
    func testReadsADeflatedZipsIndex() throws {
        let archive = try ZipArchive.open(OfficeFixture.docx)
        XCTAssertTrue(archive.paths.contains("word/document.xml"))
        let part = try XCTUnwrap(archive.data(for: "word/document.xml"))
        XCTAssertTrue(String(decoding: part, as: UTF8.self).contains("Discussed sleep"))
    }

    func testRefusesSomethingThatIsNotAZip() {
        XCTAssertThrowsError(try ZipArchive.open(Data("not a zip at all".utf8)))
    }

    func testWordDocumentBecomesParagraphs() throws {
        let text = try DocxDocument.plainText(from: OfficeFixture.docx)
        XCTAssertTrue(text.hasPrefix("Sarah M — counselling record"))
        // Runs inside one paragraph are one line, not three.
        XCTAssertTrue(text.contains("Discussed sleep. Agreed homework for next week."))
        XCTAssertTrue(text.contains("Reviewed the week.\nSecond line."))
    }

    /// Text someone deleted with track changes on is not part of the record and must not
    /// reappear inside an encrypted note as though it were.
    func testWordDropsTrackChangeDeletions() throws {
        let text = try DocxDocument.plainText(from: OfficeFixture.docx)
        XCTAssertFalse(text.contains("Removed by track changes"))
    }

    func testExcelBecomesATable() throws {
        let table = try XlsxWorkbook.table(from: OfficeFixture.xlsx)
        XCTAssertTrue(table.hadHeaderRow)
        XCTAssertEqual(table.columns, ["Client", "Session date", "Notes"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.cell(table.rows[0], at: 0), "Sarah M")
        XCTAssertEqual(table.cell(table.rows[0], at: 2), "Worked on sleep hygiene, agreed a plan.")
    }

    /// An empty cell is simply absent from the XML. Without the column reference being
    /// honoured, every value after a gap shifts one column left — and a note gets filed
    /// under the wrong client.
    func testExcelKeepsColumnsAlignedAcrossEmptyCells() throws {
        let table = try XlsxWorkbook.table(from: OfficeFixture.xlsx)
        XCTAssertEqual(table.cell(table.rows[1], at: 0), "John D")
        XCTAssertEqual(table.cell(table.rows[1], at: 1), "")
        XCTAssertEqual(table.cell(table.rows[1], at: 2), "Reviewed medication with GP.")
    }

    func testExcelDateSerialsBecomeDates() {
        XCTAssertEqual(stamp(XlsxWorkbook.date(fromSerial: 46187, timeZone: london)), "2026-06-14T0000")
        XCTAssertTrue(XlsxWorkbook.looksLikeDateSerial(46187))
        XCTAssertFalse(XlsxWorkbook.looksLikeDateSerial(4))     // a session count
        XCTAssertFalse(XlsxWorkbook.looksLikeDateSerial(50.0))  // a fee
    }
}

final class ImportFormatTests: XCTestCase {
    private func detect(_ name: String, _ text: String) -> ImportFormat {
        ImportFormat.detect(filename: name, data: Data(text.utf8))
    }

    func testDetectsByContentsBeforeExtension() {
        XCTAssertEqual(detect("notes.txt", "%PDF-1.4 ..."), .pdf)
        XCTAssertEqual(detect("notes.txt", #"{\rtf1\ansi hello}"#), .richText)
        XCTAssertEqual(ImportFormat.detect(filename: "renamed.txt", data: OfficeFixture.docx), .word)
        XCTAssertEqual(ImportFormat.detect(filename: "renamed.bin", data: OfficeFixture.xlsx), .spreadsheet)
    }

    func testDetectsTextFormats() {
        XCTAssertEqual(detect("a.md", "# Heading"), .markdown)
        XCTAssertEqual(detect("a.csv", "a,b\n1,2\n"), .delimited)
        XCTAssertEqual(detect("a.txt", "Just a note."), .plainText)
        XCTAssertEqual(detect("a.html", "<html><body>x</body></html>"), .html)
        XCTAssertEqual(detect("a.enex", "<?xml version=\"1.0\"?><en-export></en-export>"), .evernote)
    }

    /// Comma-separated data in a file called `.txt` still gets the mapping screen.
    func testDetectsATableWithoutTheExtension() {
        XCTAssertEqual(detect("a.txt", "Client,Date,Notes\nSM2,14/06/2026,x\nJD1,21/06/2026,y\n"), .delimited)
    }

    /// Formats we cannot read say so, rather than importing something garbled.
    func testNamesTheFormatsItCannotRead() {
        XCTAssertEqual(detect("old.doc", "\u{d0}\u{cf}binary"), .unsupported)
        XCTAssertEqual(detect("notes.pages", "binary"), .unsupported)
    }
}

final class ImportReaderTests: XCTestCase {
    private func file(_ name: String, _ text: String, path: [String] = [], modified: Date? = nil) -> ImportFile {
        ImportFile(name: name, relativePath: path, data: Data(text.utf8), modified: modified)
    }

    func testAFolderPerClientGroupsByFolder() {
        let result = ImportReader.read(
            file("2026-06-14.txt", "14/06/2026\nWent well.", path: ["Sarah M", "2026-06-14.txt"]),
            options: options,
            now: fixedNow
        )
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].groupKey, "Sarah M")
        XCTAssertEqual(stamp(result.items[0].date.date), "2026-06-14T0000")
    }

    /// An `.rtfd` is a folder wearing a file's name. Grouped naively, every note in a
    /// folder of them would end up under a different "client".
    func testRTFDBundlesGroupByTheirParentFolder() {
        let inside = ImportFile(
            name: "TXT.rtf",
            relativePath: ["Sarah M", "Session 4.rtfd", "TXT.rtf"],
            data: Data(#"{\rtf1 14/06/2026\par Went well.}"#.utf8)
        )
        let result = ImportReader.read(inside, options: options, now: fixedNow)
        XCTAssertEqual(result.items.first?.groupKey, "Sarah M")
        XCTAssertEqual(result.items.first?.sourceTitle, "Session 4")
    }

    func testALongDocumentBecomesOneItemPerSession() {
        let body = "14/06/2026\nOne.\n\n21/06/2026\nTwo.\n\n28/06/2026\nThree."
        let result = ImportReader.read(file("Sarah M.txt", body), options: options, now: fixedNow)
        XCTAssertEqual(result.items.count, 3)
        XCTAssertEqual(result.items[1].origin.locator, "entry 2 of 3")
    }

    /// A file with no date in it is not silently filed under today. It arrives marked as a
    /// guess, and the plan refuses to import until the counsellor supplies one.
    func testAFileWithNoDateFallsBackToTheFileDateAndSaysSo() {
        let modified = VaultDate.parse("2026-05-01T09:00:00Z")!
        let result = ImportReader.read(file("Notes.txt", "No date anywhere.", modified: modified), options: options, now: fixedNow)
        XCTAssertEqual(result.items[0].date, .fromFile(modified))
        XCTAssertFalse(result.items[0].date.isCertain)
    }

    func testATableIsHeldBackForColumnMapping() {
        let result = ImportReader.read(file("sessions.csv", "Client,Date,Notes\nSM2,14/06/2026,x\n"), options: options, now: fixedNow)
        XCTAssertTrue(result.needsMapping)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testAnUnreadableFileIsReportedRatherThanThrown() {
        let result = ImportReader.read(file("old.doc", "\u{d0}\u{cf}binary"), options: options, now: fixedNow)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
    }

    func testAnOversizeFileIsRefusedByName() {
        let big = ImportFile(name: "huge.txt", data: Data(count: 2_000_000))
        let result = ImportReader.read(big, options: ImportOptions(maximumFileBytes: 1_000_000), now: fixedNow)
        XCTAssertTrue(result.issues.first?.message.contains("larger than") == true)
    }
}

final class TabularImportTests: XCTestCase {
    private let csv = """
    Client,Session date,Time,Notes
    Sarah M,14/06/2026,09:30,"Discussed sleep.
    Agreed homework."
    Sarah M,21/06/2026,09:30,Reviewed the week.
    John D,21/06/2026,11:00,Reviewed medication.
    """

    func testSuggestsColumnsFromTheirNames() {
        let table = DelimitedTable.parse(csv)
        let mapping = ColumnMapping.suggest(for: table)
        XCTAssertEqual(mapping.client, 0)
        XCTAssertEqual(mapping.date, 1)
        XCTAssertEqual(mapping.time, 2)
        XCTAssertEqual(mapping.body, [3])
    }

    func testSuggestsColumnsFromTheDataWhenThereAreNoNames() {
        let table = DelimitedTable.parse("SM2,14/06/2026,A much longer note about the session and what was agreed.\nSM2,21/06/2026,Another long note about the second session that took place.")
        let mapping = ColumnMapping.suggest(for: table)
        XCTAssertEqual(mapping.date, 1)
        XCTAssertEqual(mapping.body, [2])
        XCTAssertEqual(mapping.client, 0)
    }

    func testBuildsOneItemPerRowWithTheDateAndTime() {
        let table = DelimitedTable.parse(csv)
        let result = TabularImport.items(
            from: table,
            mapping: ColumnMapping.suggest(for: table),
            container: "sessions.csv",
            options: options,
            now: fixedNow
        )
        XCTAssertEqual(result.items.count, 3)
        XCTAssertEqual(result.items[0].groupKey, "Sarah M")
        XCTAssertEqual(stamp(result.items[0].date.date), "2026-06-14T0930")
        XCTAssertEqual(result.items[0].body, "Discussed sleep.\nAgreed homework.")
        // The row number is the one the counsellor sees in Excel, header included.
        XCTAssertEqual(result.items[0].origin.locator, "row 2")
    }

    /// A row with no client cannot be filed. Guessing would put someone's session in
    /// another person's record.
    func testARowWithNoClientIsLeftOutAndReported() {
        let table = DelimitedTable.parse("Client,Date,Notes\n,14/06/2026,Orphan note\nSM2,21/06/2026,Fine\n")
        let result = TabularImport.items(
            from: table,
            mapping: ColumnMapping.suggest(for: table),
            container: "sessions.csv",
            options: options,
            now: fixedNow
        )
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].message.contains("no way to say whose note it is"))
    }

    func testSeveralBodyColumnsBecomeOneHeadedNote() {
        let table = DelimitedTable.parse("Client,Date,Subjective,Plan\nSM2,14/06/2026,Feeling low,Review in a fortnight\n")
        var mapping = ColumnMapping.suggest(for: table)
        mapping.body = [2, 3]
        let result = TabularImport.items(from: table, mapping: mapping, container: "s.csv", options: options, now: fixedNow)
        XCTAssertEqual(result.items[0].body, "Subjective\nFeeling low\n\nPlan\nReview in a fortnight")
    }

    func testExcelSerialDatesInTheDateColumnAreRead() throws {
        let table = try XlsxWorkbook.table(from: OfficeFixture.xlsx)
        let result = TabularImport.items(
            from: table,
            mapping: ColumnMapping.suggest(for: table),
            container: "sessions.xlsx",
            options: options,
            now: fixedNow
        )
        XCTAssertEqual(stamp(result.items[0].date.date), "2026-06-14T0000")
        XCTAssertTrue(result.items[0].date.explanation.contains("Excel date"))
    }
}

final class SensitiveTextScanTests: XCTestCase {
    func testFindsTheThingsThatIdentifyAPerson() {
        let text = """
        Sarah rang on Tuesday. Her email is sarah.mitchell@example.com and her mobile is
        07700 900123. She has moved to SW1A 1AA. DOB 14/06/1990. NHS 943 476 5919.
        """
        let kinds = Set(SensitiveTextScan.scan(text, names: ["Sarah M"]).map(\.kind))
        XCTAssertTrue(kinds.contains(.email))
        XCTAssertTrue(kinds.contains(.phone))
        XCTAssertTrue(kinds.contains(.postcode))
        XCTAssertTrue(kinds.contains(.dateOfBirth))
        XCTAssertTrue(kinds.contains(.nhsNumber))
        XCTAssertTrue(kinds.contains(.name))
    }

    func testDoesNotFlagTheWordsEveryNoteContains() {
        let matches = SensitiveTextScan.scan("Session notes for the client.", names: ["Session notes", "client"])
        XCTAssertTrue(matches.isEmpty)
    }

    func testReplacesNamesWithTheClientCode() {
        let replaced = SensitiveTextScan.replacingNames(
            in: "Sarah said she and Sarah's mother argued. Sarahs is a different word.",
            names: ["Sarah Mitchell"],
            with: "SM2"
        )
        XCTAssertTrue(replaced.hasPrefix("SM2 said"))
        XCTAssertTrue(replaced.contains("SM2's mother"))
        // Whole words only: "Sarahs" is not "Sarah".
        XCTAssertTrue(replaced.contains("Sarahs is a different word"))
    }

    func testReplacesTheLongestNameFirst() {
        let replaced = SensitiveTextScan.replacingNames(
            in: "Sarah Mitchell attended.",
            names: ["Sarah Mitchell"],
            with: "SM2"
        )
        XCTAssertEqual(replaced, "SM2 attended.")
    }
}

final class ImportFilenameDateTests: XCTestCase {
    /// Apple Notes exports one Markdown file per note, named after the note's title — and
    /// a counsellor's note titles are usually the date. The file's own timestamp is the
    /// moment they ran the export, so without this every note in the folder would arrive
    /// dated the same afternoon.
    func testADateInTheFilenameBeatsTheFilesTimestamp() {
        let exportedToday = VaultDate.parse("2026-08-30T18:00:00Z")!
        let file = ImportFile(
            name: "14 June 2026.md",
            relativePath: ["Sarah M", "14 June 2026.md"],
            data: Data("Discussed sleep. Agreed homework.".utf8),
            modified: exportedToday
        )
        let result = ImportReader.read(file, options: options, now: fixedNow)
        XCTAssertEqual(stamp(result.items.first?.date.date), "2026-06-14T0000")
        XCTAssertTrue(result.items.first?.date.isCertain == true)
        XCTAssertTrue(result.items.first?.date.explanation.contains("file's name") == true)
    }

    /// A date inside the note still wins — that is what the counsellor typed as the
    /// session date, and a filename is only ever a fallback.
    func testADateInsideTheNoteStillWins() {
        let file = ImportFile(
            name: "Session 4.md",
            data: Data("21/06/2026\nReviewed the week.".utf8),
            modified: VaultDate.parse("2026-08-30T18:00:00Z")!
        )
        let result = ImportReader.read(file, options: options, now: fixedNow)
        XCTAssertEqual(stamp(result.items.first?.date.date), "2026-06-21T0000")
    }

    /// A filename date cannot be the date of the third entry inside a running document.
    func testAFilenameDateIsNotAppliedToASplitDocument() {
        let file = ImportFile(
            name: "14 June 2026.md",
            data: Data("14/06/2026\nOne.\n\n21/06/2026\nTwo.".utf8)
        )
        let result = ImportReader.read(file, options: options, now: fixedNow)
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(stamp(result.items[1].date.date), "2026-06-21T0000")
    }
}
