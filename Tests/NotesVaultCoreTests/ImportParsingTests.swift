import XCTest
@testable import NotesVaultCore

/// A fixed zone, because a test that passes in London and fails in Sydney is worse than no
/// test — and the note format keeps the offset a session was recorded in, so this is the
/// thing under test rather than an incidental detail.
private let london = TimeZone(identifier: "Europe/London")!
private let fixedNow = VaultDate.parse("2026-08-30T12:00:00Z")!

private func stamp(_ date: Date?) -> String? {
    date.map { VaultDate.filenameStamp($0, timeZone: london) }
}

final class ImportDateTests: XCTestCase {
    private func parse(_ text: String, dayFirst: Bool = true) -> ParsedDate? {
        ImportDates.first(in: text, dayFirst: dayFirst, timeZone: london, now: fixedNow)
    }

    func testReadsUKDatesDayFirst() {
        XCTAssertEqual(stamp(parse("14/06/2026")?.date), "2026-06-14T0000")
        XCTAssertEqual(stamp(parse("Session on 06/07/2026 went well")?.date), "2026-07-06T0000")
    }

    /// The reading that could be wrong is marked as such, so the review screen can say so
    /// rather than the app quietly filing a note a month out.
    func testAmbiguousNumericDatesAreFlagged() {
        XCTAssertEqual(parse("06/07/2026")?.isAmbiguousOrder, true)
        XCTAssertEqual(parse("14/06/2026")?.isAmbiguousOrder, false)
        XCTAssertEqual(parse("2026-06-14")?.isAmbiguousOrder, false)
        XCTAssertEqual(parse("14 June 2026")?.isAmbiguousOrder, false)
    }

    func testDayFirstCanBeTurnedOff() {
        XCTAssertEqual(stamp(parse("06/07/2026", dayFirst: false)?.date), "2026-06-07T0000")
    }

    /// Day-first still yields to a file that plainly means month first, rather than
    /// throwing the date away.
    func testMonthFirstIsAcceptedWhenDayFirstIsImpossible() {
        XCTAssertEqual(stamp(parse("06/25/2026")?.date), "2026-06-25T0000")
    }

    func testReadsWordMonthsBothWaysRound() {
        XCTAssertEqual(stamp(parse("14 June 2026")?.date), "2026-06-14T0000")
        XCTAssertEqual(stamp(parse("14th Jun 2026")?.date), "2026-06-14T0000")
        XCTAssertEqual(stamp(parse("June 14, 2026")?.date), "2026-06-14T0000")
        XCTAssertEqual(stamp(parse("14 Sept 2026")?.date), "2026-09-14T0000")
    }

    func testReadsTheTimeWhenItFollowsTheDate() {
        XCTAssertEqual(stamp(parse("14/06/2026 09:30")?.date), "2026-06-14T0930")
        XCTAssertEqual(stamp(parse("14/06/2026 9:30am")?.date), "2026-06-14T0930")
        XCTAssertEqual(stamp(parse("14/06/2026, 2.15pm")?.date), "2026-06-14T1415")
        XCTAssertEqual(stamp(parse("2026-06-14T09:30")?.date), "2026-06-14T0930")
    }

    /// A time three lines below belongs to something else. Attaching it would invent an
    /// appointment time nobody wrote down.
    func testIgnoresATimeThatIsNotNextToTheDate() {
        let parsed = parse("14/06/2026 — a long note\n\nwe agreed 09:30 next week")
        XCTAssertEqual(parsed?.hasTime, false)
        XCTAssertEqual(stamp(parsed?.date), "2026-06-14T0000")
    }

    func testTwoDigitYearsPivotOnNextYear() {
        XCTAssertEqual(stamp(parse("14/06/26")?.date), "2026-06-14T0000")
        XCTAssertEqual(stamp(parse("14/06/98")?.date), "1998-06-14T0000")
    }

    /// A calendar will roll 31 February forward to 3 March if you let it. A session note
    /// filed on a day that never happened is worse than one the counsellor has to date
    /// themselves.
    func testRefusesADateTheCalendarWouldHaveToCorrect() {
        XCTAssertNil(parse("31/02/2026"))
        XCTAssertNil(parse("32/01/2026"))
    }

    func testFindsNothingWhenThereIsNothing() {
        XCTAssertNil(parse("No date here at all."))
        XCTAssertNil(parse(""))
    }

    func testLeadingDatesOnlyCountAtTheStartOfALine() {
        XCTAssertNotNil(ImportDates.leading(in: "14/06/2026 — session 4", timeZone: london, now: fixedNow))
        XCTAssertNotNil(ImportDates.leading(in: "## 14 June 2026", timeZone: london, now: fixedNow))
        XCTAssertNotNil(ImportDates.leading(in: "  - 14/06/2026", timeZone: london, now: fixedNow))
        XCTAssertNil(ImportDates.leading(in: "We agreed to meet again on 14/06/2026.", timeZone: london, now: fixedNow))
    }
}

final class DelimitedTextTests: XCTestCase {
    func testReadsAHeaderAndRows() {
        let table = DelimitedTable.parse("Client,Date,Notes\nSM2,14/06/2026,Went well\n")
        XCTAssertTrue(table.hadHeaderRow)
        XCTAssertEqual(table.columns, ["Client", "Date", "Notes"])
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.cell(table.rows[0], at: 2), "Went well")
    }

    /// The case the naive version of this gets wrong, and the case that matters most: a
    /// note body in a spreadsheet cell is nearly always several lines long.
    func testKeepsNewlinesAndCommasInsideQuotedCells() {
        let csv = "Client,Notes\nSM2,\"Line one\nLine two, with a comma\"\n"
        let table = DelimitedTable.parse(csv)
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.cell(table.rows[0], at: 1), "Line one\nLine two, with a comma")
    }

    func testHandlesDoubledQuotes() {
        let table = DelimitedTable.parse("A\n\"She said \"\"no\"\" firmly\"\n")
        XCTAssertEqual(table.cell(table.rows[0], at: 0), "She said \"no\" firmly")
    }

    func testSniffsTabsAndSemicolons() {
        XCTAssertEqual(DelimitedTable.parse("A\tB\n1\t2\n").columns, ["A", "B"])
        XCTAssertEqual(DelimitedTable.parse("A;B\n1;2\n").columns, ["A", "B"])
    }

    /// Excel writes a byte-order mark. Left alone it becomes part of the first column
    /// name, and the mapping screen offers a column that never matches anything.
    func testStripsTheExcelByteOrderMark() {
        let table = DelimitedTable.parse("\u{FEFF}Client,Notes\nSM2,x\n")
        XCTAssertEqual(table.columns.first, "Client")
    }

    func testAFileWithNoHeaderKeepsItsFirstRow() {
        let table = DelimitedTable.parse("SM2,14/06/2026,Went well\nJD1,21/06/2026,Also fine\n")
        XCTAssertFalse(table.hadHeaderRow)
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.columns, ["Column 1", "Column 2", "Column 3"])
    }

    func testRaggedRowsArePaddedRatherThanDropped() {
        let table = DelimitedTable.parse("A,B,C\n1,2\n")
        XCTAssertEqual(table.rows[0].count, 3)
    }
}

final class MarkupTextTests: XCTestCase {
    func testHTMLKeepsTheLineBreaksAReaderDependsOn() {
        let html = "<div>14/06/2026</div><div>Discussed sleep.</div><ul><li>Homework</li></ul>"
        let text = HTMLText.plainText(from: html)
        XCTAssertEqual(text, "14/06/2026\nDiscussed sleep.\n• Homework")
    }

    func testHTMLDecodesEntities() {
        XCTAssertEqual(HTMLText.plainText(from: "<p>Fees &amp; &pound;50 &#8212; agreed</p>"), "Fees & £50 — agreed")
    }

    func testHTMLDropsScriptAndStyle() {
        let html = "<style>p{color:red}</style><p>Real text</p><script>alert(1)</script>"
        XCTAssertEqual(HTMLText.plainText(from: html), "Real text")
    }

    func testRichTextExtractsTheNoteAndNotTheFontTable() {
        let rtf = #"{\rtf1\ansi\ansicpg1252{\fonttbl\f0\fswiss Helvetica;}\f0\fs24 First line\par Second line}"#
        XCTAssertEqual(RTFText.plainText(from: rtf), "First line\nSecond line")
    }

    func testRichTextDecodesEscapedCharacters() {
        let rtf = #"{\rtf1 Smart \'93quotes\'94 and \u8212 ?dashes \\ braces \{\}}"#
        let text = RTFText.plainText(from: rtf)
        XCTAssertTrue(text.contains("\u{201C}quotes\u{201D}"), text)
        XCTAssertTrue(text.contains("—dashes"), text)
        XCTAssertTrue(text.contains("\\ braces {}"), text)
    }

    func testRichTextSkipsIgnorableDestinations() {
        let rtf = #"{\rtf1{\*\generator Riched20 10.0;}Kept text}"#
        XCTAssertEqual(RTFText.plainText(from: rtf), "Kept text")
    }
}

final class SessionSplitterTests: XCTestCase {
    private func split(_ text: String) -> [TextSection] {
        SessionSplitter.split(text, timeZone: london, now: fixedNow)
    }

    /// The commonest shape of all: one Word document per client with years of dated
    /// entries in it.
    func testSplitsARunningDocumentAtEachDatedEntry() {
        let document = """
        Sarah M — counselling record

        14/06/2026 09:30
        Discussed sleep. Agreed homework.

        21/06/2026 09:30
        Reviewed the week. Better.

        28/06/2026 09:40
        Ending planned for July.
        """
        let sections = split(document)
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(stamp(sections[0].date?.date), "2026-06-14T0930")
        XCTAssertEqual(stamp(sections[2].date?.date), "2026-06-28T0940")
        // The title block rides along with the first session rather than being dropped.
        XCTAssertTrue(sections[0].text.contains("counselling record"))
        XCTAssertTrue(sections[1].text.contains("Reviewed the week"))
        XCTAssertFalse(sections[1].text.contains("Discussed sleep"))
    }

    /// Splitting too eagerly tears a note in half, which is worse than not splitting.
    func testLeavesADocumentWholeWhenThereIsOnlyOneDate() {
        let sections = split("14/06/2026\nA single session, mentioning 21/06/2026 as the next one.")
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(stamp(sections[0].date?.date), "2026-06-14T0000")
    }

    func testALongPreambleBecomesItsOwnUndatedItem() {
        let preamble = String(repeating: "Referral background. ", count: 30)
        let sections = split("\(preamble)\n14/06/2026\nOne\n21/06/2026\nTwo")
        XCTAssertEqual(sections.count, 3)
        XCTAssertNil(sections[0].date)
        XCTAssertNotNil(sections[1].date)
    }
}

final class EnexTests: XCTestCase {
    func testReadsEvernoteNotes() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <en-export>
        <note><title>Sarah M 14/06/2026</title>
        <content><![CDATA[<en-note><div>Discussed sleep.</div><div>Agreed homework.</div></en-note>]]></content>
        <created>20260614T083000Z</created></note>
        <note><title>Second</title>
        <content><![CDATA[<en-note><div>Another note.</div></en-note>]]></content>
        <created>20260621T083000Z</created></note>
        </en-export>
        """
        let notes = EnexDocument.notes(from: xml)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].title, "Sarah M 14/06/2026")
        XCTAssertEqual(notes[0].body, "Discussed sleep.\nAgreed homework.")
        XCTAssertEqual(VaultDate.utcString(notes[0].created!), "2026-06-14T08:30:00Z")
    }
}
