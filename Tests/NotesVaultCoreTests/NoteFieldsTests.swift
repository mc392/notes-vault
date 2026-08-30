import XCTest
@testable import NotesVaultCore

final class NoteFieldsTests: XCTestCase {

    // MARK: - Naming

    func testDerivesAHeaderKeyFromWhatTheCounsellorTyped() {
        XCTAssertEqual(NoteFieldDefinition.key(from: "Session number"), "session-number")
        XCTAssertEqual(NoteFieldDefinition.key(from: "  Room / Location  "), "room-location")
        XCTAssertEqual(NoteFieldDefinition.key(from: "Fee (£)"), "fee")
    }

    func testRefusesAFieldThatWouldShadowTheNoteFormatsOwnHeaders() {
        var settings = NoteFieldSettings.default
        for reserved in ["Client", "Session", "Device", "Supersedes", "id", "template", "written"] {
            XCTAssertThrowsError(try settings.addCustomField(label: reserved, kind: .text), reserved) { error in
                guard case VaultError.invalidNoteField = error else {
                    return XCTFail("expected invalidNoteField for \(reserved), got \(error)")
                }
            }
        }
    }

    func testRefusesADuplicateAndAnEmptyName() {
        var settings = NoteFieldSettings.default
        try? settings.addCustomField(label: "Referrer", kind: .text)

        XCTAssertThrowsError(try settings.addCustomField(label: "referrer", kind: .text))
        XCTAssertThrowsError(try settings.addCustomField(label: "   ", kind: .text))
        XCTAssertThrowsError(try settings.addCustomField(label: "!!!", kind: .text))
        // Session number is a built-in, so it is already taken.
        XCTAssertThrowsError(try settings.addCustomField(label: "Session number", kind: .number))
    }

    // MARK: - The value has to survive being one header line

    /// The one input that could genuinely corrupt a note: a newline in a header value would
    /// end the header block early and swallow the rest of the note into the body.
    func testNewlinesInAValueAreFoldedToSpaces() {
        let folded = NoteFieldDefinition.sanitise(value: "Room 4\n\nSecond floor\r\nAnnexe")
        XCTAssertEqual(folded, "Room 4 Second floor Annexe")
        XCTAssertFalse(folded.contains("\n"))
    }

    func testAValueIsCappedRatherThanAllowedToGrowWithoutLimit() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(NoteFieldDefinition.sanitise(value: long).count, NoteFieldDefinition.maxValueLength)
    }

    /// The whole point of the feature: a field a counsellor invented has to come back out of
    /// a real note file unchanged, through the same serialise/parse the vault uses.
    func testACustomFieldSurvivesARealNoteRoundTrip() throws {
        var settings = NoteFieldSettings.default
        settings.setEnabled(true, forKey: "session-number")
        settings.setEnabled(true, forKey: "location")
        try settings.addCustomField(label: "Referral source", kind: .text)

        let headers = settings.headers(from: [
            "session-number": "12",
            "location": "Room 4, Bristol\nsecond floor",
            "referral-source": "GP"
        ])

        let note = NoteRecord(
            client: try ClientCode("SM2"),
            session: Date(timeIntervalSince1970: 1_780_000_000),
            device: "mac",
            extraHeaders: headers,
            body: "The session itself."
        )

        let parsed = try NoteRecord.parse(note.serialised())

        XCTAssertEqual(parsed.extraHeaders["session-number"], "12")
        XCTAssertEqual(parsed.extraHeaders["location"], "Room 4, Bristol second floor")
        XCTAssertEqual(parsed.extraHeaders["referral-source"], "GP")
        XCTAssertEqual(parsed.body, "The session itself.")
        XCTAssertEqual(parsed.client.rawValue, "SM2")
    }

    func testAnEmptyFieldLeavesNoTraceInTheRecord() {
        var settings = NoteFieldSettings.default
        settings.setEnabled(true, forKey: "location")

        let headers = settings.headers(from: ["location": "   "])
        XCTAssertTrue(headers.isEmpty, "a field left blank should not write an empty header")
    }

    func testAFieldThatIsSwitchedOffIsNotWritten() {
        var settings = NoteFieldSettings.default
        settings.setEnabled(false, forKey: "location")

        let headers = settings.headers(from: ["location": "Room 4"])
        XCTAssertTrue(headers.isEmpty)
    }

    // MARK: - Reading back

    func testShowsAValueEvenWhenThisDeviceHasNeverHeardOfTheField() {
        let settings = NoteFieldSettings.default
        let described = settings.describe(headers: ["risk-review": "completed", "location": "Room 4"])

        // The known field is labelled; the foreign one still appears rather than vanishing.
        XCTAssertTrue(described.contains { $0.label == "Location" && $0.value == "Room 4" })
        XCTAssertTrue(described.contains { $0.label == "risk-review" && $0.value == "completed" })
    }

    func testRemovingACustomFieldDoesNotRemoveABuiltIn() {
        var settings = NoteFieldSettings.default
        settings.removeCustomField(key: "location")
        XCTAssertTrue(settings.fields.contains { $0.key == "location" }, "built-ins can be switched off, not deleted")
    }

    func testNormalisingAddsBuiltInsAnInstallHasNotSeenYet() {
        // Someone upgrading from a build that only knew about "location".
        let stored = NoteFieldSettings(fields: [
            NoteFieldDefinition(key: "location", label: "Location", kind: .text, isEnabled: true, isBuiltIn: true)
        ])
        let normalised = stored.normalised()

        XCTAssertTrue(normalised.fields.contains { $0.key == "session-number" })
        XCTAssertEqual(
            normalised.fields.first { $0.key == "location" }?.isEnabled,
            true,
            "a choice the counsellor already made must survive the upgrade"
        )
    }

    func testSettingsRoundTripThroughJSON() throws {
        var settings = NoteFieldSettings.default
        settings.setEnabled(true, forKey: "session-number")
        try settings.addCustomField(label: "Referral source", kind: .text)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(NoteFieldSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
    }
}
