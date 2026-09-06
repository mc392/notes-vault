import XCTest
@testable import NotesVaultCore

final class NoteMarkdownTests: XCTestCase {

    private func apply(
        _ style: NoteMarkdownStyle,
        _ text: String,
        _ start: Int,
        _ length: Int
    ) -> MarkdownEdit {
        NoteMarkdown.apply(style, to: text, selectionStart: start, selectionLength: length)
    }

    // MARK: - Bold and italic

    func testBoldWrapsTheSelection() {
        let edit = apply(.bold, "the client said", 4, 6) // "client"
        XCTAssertEqual(edit.text, "the **client** said")
        XCTAssertEqual(String(edit.text.dropFirst(edit.selectionStart).prefix(edit.selectionLength)), "client")
    }

    func testBoldAgainRemovesIt() {
        // Selection covers the markers as well.
        let edit = apply(.bold, "the **client** said", 4, 10)
        XCTAssertEqual(edit.text, "the client said")
    }

    func testBoldRemovesMarkersSittingJustOutsideTheSelection() {
        // Caret selects only the word, the markers are either side of it.
        let edit = apply(.bold, "the **client** said", 6, 6)
        XCTAssertEqual(edit.text, "the client said")
        XCTAssertEqual(String(edit.text.dropFirst(edit.selectionStart).prefix(edit.selectionLength)), "client")
    }

    func testBoldWithNothingSelectedLeavesTheCaretReadyToType() {
        let edit = apply(.bold, "note: ", 6, 0)
        XCTAssertEqual(edit.text, "note: ****")
        XCTAssertEqual(edit.selectionStart, 8, "caret belongs between the markers")
        XCTAssertEqual(edit.selectionLength, 0)
    }

    func testItalicUsesASingleMarker() {
        let edit = apply(.italic, "felt low", 5, 3)
        XCTAssertEqual(edit.text, "felt *low*")
    }

    // MARK: - Subheadings and bullets

    func testHeadingPrefixesTheLineTheCaretIsOn() {
        let edit = apply(.heading, "Presenting concern\nSlept badly.", 3, 0)
        XCTAssertEqual(edit.text, "## Presenting concern\nSlept badly.")
    }

    func testHeadingAgainRemovesThePrefix() {
        let edit = apply(.heading, "## Presenting concern\nSlept badly.", 3, 0)
        XCTAssertEqual(edit.text, "Presenting concern\nSlept badly.")
    }

    func testBulletAppliesToEveryLineTheSelectionTouches() {
        let text = "milk\neggs\nbread"
        let edit = apply(.bullet, text, 0, text.utf16.count)
        XCTAssertEqual(edit.text, "- milk\n- eggs\n- bread")
    }

    func testBulletTogglesOffOnlyWhenEveryTouchedLineHasIt() {
        // One of the three is not a bullet, so pressing the button should finish the job
        // rather than strip the other two.
        let text = "- milk\neggs\n- bread"
        let edit = apply(.bullet, text, 0, text.utf16.count)
        XCTAssertEqual(edit.text, "- milk\n- eggs\n- bread")

        let again = apply(.bullet, edit.text, 0, edit.text.utf16.count)
        XCTAssertEqual(again.text, "milk\neggs\nbread")
    }

    func testFormattingAnEmptyNoteDoesNotCrash() {
        XCTAssertEqual(apply(.bullet, "", 0, 0).text, "- ")
        XCTAssertEqual(apply(.heading, "", 0, 0).text, "## ")
        XCTAssertEqual(apply(.bold, "", 0, 0).text, "****")
    }

    func testAnOutOfRangeSelectionIsClampedRatherThanCrashing() {
        let edit = apply(.bold, "short", 900, 900)
        XCTAssertFalse(edit.text.isEmpty)
    }

    /// Emoji and accents are two UTF-16 units, which is exactly where offset arithmetic
    /// goes wrong if it is written against characters instead.
    func testOffsetsSurviveTextThatIsNotPlainASCII() {
        let text = "client 🙂 said café"
        let edit = apply(.bold, text, 0, 6) // "client"
        XCTAssertEqual(edit.text, "**client** 🙂 said café")
    }

    // MARK: - Drawing the formatting instead of its markup

    /// The one thing every test below is really asserting: styling a note never edits it.
    private func assertRunsFit(_ body: String, file: StaticString = #filePath, line: UInt = #line) {
        for run in NoteMarkdown.styleRuns(in: body) {
            XCTAssertGreaterThanOrEqual(run.start, 0, "run starts before the text", file: file, line: line)
            XCTAssertGreaterThan(run.length, 0, "an empty run has nothing to draw", file: file, line: line)
            XCTAssertLessThanOrEqual(
                run.start + run.length,
                body.utf16.count,
                "a run past the end of the note would raise when it reached the text view",
                file: file,
                line: line
            )
        }
    }

    private func styled(_ body: String, _ appearance: NoteMarkdownAppearance) -> [String] {
        let units = Array(body.utf16)
        return NoteMarkdown.styleRuns(in: body)
            .filter { $0.appearance == appearance }
            .map { String(decoding: units[$0.start..<($0.start + $0.length)], as: UTF16.self) }
    }

    func testASubheadingIsDrawnAsOneAndItsHashesFade() {
        let body = "## Presenting concern\nSlept badly."

        XCTAssertEqual(styled(body, .heading), ["Presenting concern"])
        XCTAssertEqual(styled(body, .marker), ["## "], "the hashes are still there, just drawn faintly")
        assertRunsFit(body)
    }

    func testBoldAndItalicAreDrawnWithTheirMarkersFaded() {
        let body = "Client reported **low mood** and *poor sleep*."

        XCTAssertEqual(styled(body, .bold), ["low mood"])
        XCTAssertEqual(styled(body, .italic), ["poor sleep"])
        XCTAssertEqual(styled(body, .marker), ["**", "**", "*", "*"])
        assertRunsFit(body)
    }

    func testABulletsDashIsDrawnFaintly() {
        let body = "- low mood\n- poor appetite"
        XCTAssertEqual(styled(body, .marker), ["- ", "- "])
        assertRunsFit(body)
    }

    /// A subheading with a bold phrase in it is one stretch of text that is both, which is
    /// why the appearance is a set rather than a case.
    func testBoldInsideASubheadingIsBothAtOnce() {
        let body = "## Risk **today**"
        XCTAssertEqual(styled(body, [.heading, .bold]), ["today"])
        assertRunsFit(body)
    }

    /// Half a marker is what every bold phrase looks like on the way to being typed, and the
    /// bold button itself leaves the caret sitting inside an empty pair.
    func testAnUnfinishedMarkerStylesNothing() {
        XCTAssertTrue(NoteMarkdown.styleRuns(in: "the client said **low").isEmpty)
        XCTAssertTrue(NoteMarkdown.styleRuns(in: "note: ****").isEmpty)
        XCTAssertTrue(NoteMarkdown.styleRuns(in: "5 * 4 = 20").isEmpty, "arithmetic is not italics")
    }

    func testAPlainNoteIsDrawnPlainly() {
        let body = "Client arrived on time. We discussed the week.\nAgreed to meet fortnightly."
        XCTAssertTrue(NoteMarkdown.styleRuns(in: body).isEmpty)
    }

    /// Offsets are UTF-16 because they end up in an `NSRange`. An emoji earlier in the line
    /// is where that arithmetic goes wrong if it is written against characters.
    func testOffsetsAreUTF16SoTheyLandOnTheRightCharacters() {
        let body = "🙂 said **low mood**"
        XCTAssertEqual(styled(body, .bold), ["low mood"])
        assertRunsFit(body)
    }

    func testStylingAnEmptyOrRaggedNoteDoesNotCrash() {
        XCTAssertTrue(NoteMarkdown.styleRuns(in: "").isEmpty)
        XCTAssertTrue(NoteMarkdown.styleRuns(in: "\n\n\n").isEmpty)
        assertRunsFit("## \n- \n**\n#### not a heading\r\n## Windows line\r\n")
    }

    // MARK: - Reading back

    func testSplitsANoteIntoBlocksForDisplay() {
        let blocks = NoteMarkdown.blocks(in: "## Presenting concern\nSlept badly.\n\n- low mood\n- poor appetite")
        XCTAssertEqual(blocks, [
            .heading("Presenting concern"),
            .paragraph("Slept badly."),
            .blank,
            .bullet("low mood"),
            .bullet("poor appetite")
        ])
    }

    /// Every note written before this feature existed is plain prose, and has to render as
    /// exactly what was typed.
    func testAPlainNoteRendersUnchanged() {
        let body = "Client arrived on time. We discussed the week.\nAgreed to meet fortnightly."
        let blocks = NoteMarkdown.blocks(in: body)
        XCTAssertEqual(blocks, [
            .paragraph("Client arrived on time. We discussed the week."),
            .paragraph("Agreed to meet fortnightly.")
        ])
    }

    /// The formatting is only ever markers in the text, so a formatted note still round-trips
    /// through the note format untouched — that is the whole reason for choosing Markdown.
    func testAFormattedNoteSurvivesTheNoteFormat() throws {
        let body = "## Presenting concern\n\nClient reported **low mood** and *poor sleep*.\n\n- referred to GP"
        let note = NoteRecord(
            client: try ClientCode("SM2"),
            session: Date(timeIntervalSince1970: 1_780_000_000),
            device: "mac",
            body: body
        )
        let parsed = try NoteRecord.parse(note.serialised())
        XCTAssertEqual(parsed.body, body)
    }
}
