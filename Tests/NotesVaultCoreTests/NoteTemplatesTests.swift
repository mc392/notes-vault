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

    func testBuiltInsCannotBeChangedOrRemoved() {
        var settings = NoteTemplateSettings.default
        XCTAssertThrowsError(try settings.updateCustomTemplate(id: "soap", name: "My SOAP", body: ""))

        settings.removeCustomTemplate(id: "soap")
        XCTAssertEqual(settings.templates.count, 3, "a built-in is still there afterwards")
    }

    /// Removing a template stops it being offered and does nothing else. Notes written from
    /// it still name it, and still read back with a readable name.
    func testRemovingATemplateLeavesNotesWrittenFromItReadable() throws {
        var settings = NoteTemplateSettings.default
        let added = try settings.addCustomTemplate(name: "Trauma review", body: "Presentation\n")
        settings.removeCustomTemplate(id: added.id)

        XCTAssertEqual(settings.templates.count, 3)
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
