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
