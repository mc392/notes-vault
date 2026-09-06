import XCTest
@testable import NotesVaultCore

/// Templates a counsellor writes themselves.
///
/// The thing worth guarding here is the identifier. It goes into the note file, so it has
/// to survive a rename, survive being read on a device that has never heard of it, and
/// never collide with one of the built-ins.
final class NoteTemplatesTests: XCTestCase {
    func testTheBuiltInsAreThereToStartWith() {
        let settings = NoteTemplateSettings.default
        XCTAssertEqual(settings.templates.map(\.id), ["freeform", "soap", "dap"])
        XCTAssertTrue(settings.custom.isEmpty)
        XCTAssertTrue(settings.templates.allSatisfy(\.isBuiltIn))
    }

    func testAddingATemplateDerivesAnIdentifierFromItsName() throws {
        var settings = NoteTemplateSettings.default
        let added = try settings.addCustomTemplate(name: "Trauma review", body: "Presentation\n\n\nPlan\n\n")

        XCTAssertEqual(added.id, "trauma-review")
        XCTAssertEqual(added.name, "Trauma review")
        XCTAssertFalse(added.isBuiltIn)
        XCTAssertEqual(settings.starterBody(for: added.template), "Presentation\n\n\nPlan\n\n")
        XCTAssertEqual(settings.displayName(for: added.template), "Trauma review")
    }

    func testANameThatCollidesWithAnExistingTemplateIsRefused() throws {
        var settings = NoteTemplateSettings.default
        XCTAssertThrowsError(try settings.addCustomTemplate(name: "SOAP", body: "")) { error in
            XCTAssertTrue(((error as? VaultError)?.errorDescription ?? "").contains("already a template"))
        }

        try settings.addCustomTemplate(name: "Trauma review", body: "")
        XCTAssertThrowsError(try settings.addCustomTemplate(name: "trauma  review", body: ""),
                             "the identifier is what has to be unique, not the spelling")
    }

    func testANameWithNothingUsableInItIsRefused() {
        var settings = NoteTemplateSettings.default
        XCTAssertThrowsError(try settings.addCustomTemplate(name: "   ", body: ""))
        XCTAssertThrowsError(try settings.addCustomTemplate(name: "…", body: ""))
        XCTAssertThrowsError(try settings.addCustomTemplate(
            name: String(repeating: "x", count: NoteTemplateDefinition.maxNameLength + 1),
            body: ""
        ))
    }

    /// Notes already written point at the identifier, so renaming must not move it. The
    /// record says which template it was written from, and a settings change cannot rewrite
    /// a record.
    func testRenamingATemplateKeepsItsIdentifier() throws {
        var settings = NoteTemplateSettings.default
        let added = try settings.addCustomTemplate(name: "Trauma review", body: "Presentation\n")

        try settings.updateCustomTemplate(id: added.id, name: "Trauma work", body: "Presentation\n\n\nRisk\n")

        XCTAssertEqual(settings.templates.last?.id, "trauma-review")
        XCTAssertEqual(settings.templates.last?.name, "Trauma work")
        XCTAssertEqual(settings.starterBody(for: added.template), "Presentation\n\n\nRisk\n")
    }

    func testBuiltInsCannotBeChanged() {
        var settings = NoteTemplateSettings.default
        XCTAssertThrowsError(try settings.updateCustomTemplate(id: "soap", name: "My SOAP", body: ""))
    }

    /// Removing one of the app's own templates takes it off the picker and keeps it, so it
    /// comes back with the headings it always had rather than being retyped.
    func testABuiltInCanBeRemovedAndPutBack() throws {
        var settings = NoteTemplateSettings.default
        let headings = settings.starterBody(for: .soap)

        try settings.removeTemplate(id: "soap")

        XCTAssertEqual(settings.offered.map(\.id), ["freeform", "dap"])
        XCTAssertEqual(settings.removed.map(\.id), ["soap"])
        XCTAssertEqual(settings.displayName(for: .soap), "SOAP", "a note written from it still reads back")

        settings.restoreTemplate(id: "soap")

        XCTAssertEqual(settings.offered.map(\.id), ["freeform", "soap", "dap"])
        XCTAssertTrue(settings.removed.isEmpty)
        XCTAssertEqual(settings.starterBody(for: .soap), headings)
    }

    /// A note has to be able to start from a blank page.
    func testFreeformCannotBeRemoved() {
        var settings = NoteTemplateSettings.default
        XCTAssertThrowsError(try settings.removeTemplate(id: "freeform")) { error in
            XCTAssertTrue(((error as? VaultError)?.errorDescription ?? "").contains("cannot be removed"))
        }
        XCTAssertEqual(settings.offered.map(\.id), ["freeform", "soap", "dap"])
    }

    /// Removing a template stops it being offered and does nothing else. Notes written from
    /// it still name it, and still read back with a readable name.
    func testRemovingATemplateLeavesNotesWrittenFromItReadable() throws {
        var settings = NoteTemplateSettings.default
        let added = try settings.addCustomTemplate(name: "Trauma review", body: "Presentation\n")
        try settings.removeTemplate(id: added.id)

        XCTAssertEqual(settings.templates.count, 3, "one of the counsellor's own goes for good")
        XCTAssertNil(settings.definition(for: added.template))
        XCTAssertEqual(settings.displayName(for: added.template), "Trauma review")
        XCTAssertEqual(settings.starterBody(for: added.template), "")
    }

    /// A built-in added in a later version has to appear for someone who saved their
    /// settings before it existed — and their own templates have to survive that.
    func testNormalisingRestoresMissingBuiltInsWithoutLosingCustomOnes() throws {
        var settings = NoteTemplateSettings(templates: [])
        try settings.addCustomTemplate(name: "Trauma review", body: "Presentation\n")

        let normalised = settings.normalised()

        XCTAssertEqual(normalised.templates.map(\.id), ["freeform", "soap", "dap", "trauma-review"])
        XCTAssertEqual(normalised.custom.map(\.name), ["Trauma review"])
    }

    /// The counterpart to the test above: normalising must not undo a removal. Settings are
    /// normalised every time they are loaded, so a built-in that came back here would come
    /// back on every launch.
    func testNormalisingLeavesARemovedBuiltInRemoved() throws {
        var settings = NoteTemplateSettings.default
        try settings.removeTemplate(id: "dap")

        let normalised = settings.normalised()

        XCTAssertEqual(normalised.offered.map(\.id), ["freeform", "soap"])
        XCTAssertEqual(normalised.removed.map(\.id), ["dap"])
    }

    /// Settings written by a version that had no removable built-ins have no such flag in
    /// them. They have to load, with everything still offered — the alternative is a
    /// counsellor's own templates silently reset to the defaults.
    func testSettingsSavedBeforeTemplatesCouldBeRemovedStillLoad() throws {
        let legacy = """
        {"templates":[{"id":"freeform","name":"Freeform","body":"","isBuiltIn":true},\
        {"id":"trauma-review","name":"Trauma review","body":"Presentation\\n","isBuiltIn":false}]}
        """
        let decoded = try JSONDecoder().decode(NoteTemplateSettings.self, from: Data(legacy.utf8))

        XCTAssertEqual(decoded.offered.map(\.id), ["freeform", "trauma-review"])
        XCTAssertTrue(decoded.removed.isEmpty)
        XCTAssertEqual(decoded.normalised().offered.map(\.id), ["freeform", "soap", "dap", "trauma-review"])
    }

    /// The headings the app ships with are Markdown subheadings, so a note started from one
    /// reads back as a formatted note rather than as lines that happen to be short.
    func testTheBuiltInHeadingsAreWrittenAsSubheadings() {
        let settings = NoteTemplateSettings.default
        XCTAssertEqual(
            NoteMarkdown.blocks(in: settings.starterBody(for: .soap)).filter { $0 != .blank },
            [.heading("Subjective"), .heading("Objective"), .heading("Assessment"), .heading("Plan")]
        )
    }

    func testSettingsSurviveARoundTripThroughJSON() throws {
        var settings = NoteTemplateSettings.default
        try settings.addCustomTemplate(name: "Trauma review", body: "Presentation\n\n\nPlan\n")

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(NoteTemplateSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
    }

    /// The identifier is written into a one-line `key: value` header, so it must never
    /// carry a colon, a newline, or anything else that would break the note format.
    func testAnIdentifierIsSafeToWriteIntoTheNoteFormat() throws {
        var settings = NoteTemplateSettings.default
        let added = try settings.addCustomTemplate(name: "Risk: review & plan\nnow", body: "")

        XCTAssertFalse(added.id.contains(":"))
        XCTAssertFalse(added.id.contains("\n"))
        XCTAssertTrue(added.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })

        let note = NoteRecord(
            client: Fixture.code("SM2"),
            session: Fixture.date("2026-06-14T09:30:00Z"),
            device: "mac",
            template: added.template,
            body: "Body."
        )
        XCTAssertEqual(try NoteRecord.parse(note.serialised()).template, added.template)
    }
}
