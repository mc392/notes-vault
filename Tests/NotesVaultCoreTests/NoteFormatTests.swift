import XCTest
@testable import NotesVaultCore

final class NoteFormatTests: XCTestCase {
    func testRoundTripsEveryField() throws {
        let note = NoteRecord(
            client: Fixture.code("SM2"),
            session: Fixture.date("2026-06-14T09:30:00+01:00"),
            sessionUTCOffset: 3600,
            written: Fixture.date("2026-06-14T10:12:03Z"),
            device: "iphone",
            template: .soap,
            supersedes: nil,
            body: "Presented flat. Discussed the week.\n\nAgreed to try the sleep diary again."
        )

        let parsed = try NoteRecord.parse(note.serialised())

        XCTAssertEqual(parsed.id, note.id)
        XCTAssertEqual(parsed.client, note.client)
        XCTAssertEqual(parsed.session.timeIntervalSince1970, note.session.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(parsed.sessionUTCOffset, 3600)
        XCTAssertEqual(parsed.device, "iphone")
        XCTAssertEqual(parsed.template, .soap)
        XCTAssertEqual(parsed.body, note.body)
    }

    /// The offset is part of the record, not a rendering detail. A note written at 9:30
    /// during British Summer Time must still read as 9:30 when it is opened in winter, or
    /// on a device that has travelled.
    func testKeepsTheOffsetItWasWrittenWith() throws {
        let note = NoteRecord(
            client: Fixture.code("AB1"),
            session: Fixture.date("2026-01-14T09:30:00Z"),
            sessionUTCOffset: 0,
            device: "mac",
            body: "x"
        )
        let text = String(data: note.serialised(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("session: 2026-01-14T09:30:00Z"), text)

        let parsed = try NoteRecord.parse(note.serialised())
        XCTAssertEqual(parsed.sessionUTCOffset, 0)
    }

    func testBodyKeepsBlankLines() throws {
        let body = "One.\n\nTwo.\n\n\nThree."
        let note = NoteRecord(client: Fixture.code("SM2"), session: Date(), device: "mac", body: body)
        XCTAssertEqual(try NoteRecord.parse(note.serialised()).body, body)
    }

    func testAcceptsCRLF() throws {
        let source = """
        notesvault/1
        id: \(NoteID().rawValue)
        client: SM2
        session: 2026-06-14T09:30:00+01:00
        written: 2026-06-14T10:12:03Z
        device: mac
        template: freeform

        Body line one.
        """.replacingOccurrences(of: "\n", with: "\r\n")

        let parsed = try NoteRecord.parse(text: source)
        XCTAssertEqual(parsed.body, "Body line one.")
    }

    /// Forward compatibility. A note written by a later version carrying a header this
    /// build has never heard of must survive being read here — dropping it would lose
    /// clinical information the moment two devices ran different versions.
    func testUnknownHeadersSurviveARoundTrip() throws {
        let source = """
        notesvault/1
        id: \(NoteID().rawValue)
        client: SM2
        session: 2026-06-14T09:30:00+01:00
        written: 2026-06-14T10:12:03Z
        device: mac
        template: freeform
        risk-flag: reviewed

        Body.
        """

        let parsed = try NoteRecord.parse(text: source)
        XCTAssertEqual(parsed.extraHeaders["risk-flag"], "reviewed")
        XCTAssertTrue(String(data: parsed.serialised(), encoding: .utf8)!.contains("risk-flag: reviewed"))
    }

    /// The other direction: a *newer format* is refused outright rather than read
    /// optimistically, because reading it wrongly and then saving is how data is lost.
    func testRefusesANewerFormat() {
        let source = """
        notesvault/2
        id: \(NoteID().rawValue)
        client: SM2
        session: 2026-06-14T09:30:00+01:00
        written: 2026-06-14T10:12:03Z
        device: mac

        Body.
        """
        XCTAssertThrowsError(try NoteRecord.parse(text: source)) { error in
            XCTAssertEqual(error as? VaultError, .unsupportedNoteFormat(2))
        }
    }

    func testRejectsMissingHeaders() {
        let source = """
        notesvault/1
        client: SM2

        Body.
        """
        XCTAssertThrowsError(try NoteRecord.parse(text: source))
    }

    func testRejectsSomethingThatIsNotANote() {
        XCTAssertThrowsError(try NoteRecord.parse(text: "Dear diary,\n\nhello."))
    }

    func testFilenameMatchesTheDocumentedShape() {
        let note = NoteRecord(
            client: Fixture.code("SM2"),
            session: Fixture.date("2026-06-14T09:30:00+01:00"),
            sessionUTCOffset: 3600,
            device: "iPhone 15",
            body: "x"
        )
        XCTAssertEqual(note.preferredFilename, "2026-06-14T0930-iphone-15.note")
        XCTAssertTrue(note.disambiguatedFilename.hasSuffix(".note"))
        XCTAssertNotEqual(note.preferredFilename, note.disambiguatedFilename)
    }

    func testTemplateOnlyPrefills() {
        XCTAssertTrue(NoteTemplate.freeform.starterBody.isEmpty)
        XCTAssertTrue(NoteTemplate.soap.starterBody.contains("Subjective"))
        XCTAssertTrue(NoteTemplate.dap.starterBody.contains("Data"))
    }
}

final class ClientCodeTests: XCTestCase {
    func testNormalisesCase() throws {
        XCTAssertEqual(try ClientCode("sm2").rawValue, "SM2")
        XCTAssertEqual(try ClientCode("  sm2 ").rawValue, "SM2")
    }

    /// The type is the enforcement of "never store a name". Anything with a space or
    /// punctuation is exactly what a name looks like when someone types one in.
    func testRejectsAnythingThatCouldBeAName() {
        XCTAssertThrowsError(try ClientCode("Sarah M"))
        XCTAssertThrowsError(try ClientCode("S"))
        XCTAssertThrowsError(try ClientCode("sarah.miller"))
        XCTAssertThrowsError(try ClientCode("SM-2"))
        XCTAssertThrowsError(try ClientCode("_reserved"))
        XCTAssertThrowsError(try ClientCode("ABCDEFGHIJKLM"))
    }
}

final class NoteIDTests: XCTestCase {
    func testIsTimeOrdered() {
        let earlier = NoteID(generatedAt: Fixture.date("2026-01-01T00:00:00Z"))
        let later = NoteID(generatedAt: Fixture.date("2026-06-01T00:00:00Z"))
        XCTAssertLessThan(earlier, later)
    }

    func testRoundTrips() throws {
        let id = NoteID()
        XCTAssertEqual(try NoteID(id.rawValue), id)
        XCTAssertEqual(id.rawValue.count, NoteID.length)
    }

    func testRejectsRubbish() {
        XCTAssertThrowsError(try NoteID("nope"))
    }
}
