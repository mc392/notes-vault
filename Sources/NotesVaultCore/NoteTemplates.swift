import Foundation

/// One template the note screen offers: a name, and the headings it prefills.
///
/// `id` is what gets written into the note (`template: soap`) and is derived from the name
/// the same way a note field's key is — `Trauma review` becomes `trauma-review`. It never
/// changes afterwards, even if the template is renamed, because notes already written point
/// at it and a record must not be quietly re-labelled by a settings change.
public struct NoteTemplateDefinition: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    /// What the editor is prefilled with. Only ever a prefill — decision 07: nothing
    /// enforces the headings afterwards, so a counsellor who starts one and then writes
    /// freely is not fighting the app.
    public var body: String
    /// Built-ins cannot be deleted or edited. They can be copied: the "start from" choice
    /// on a new template is how a counsellor gets SOAP with one more heading.
    public let isBuiltIn: Bool

    public init(id: String, name: String, body: String, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.body = body
        self.isBuiltIn = isBuiltIn
    }

    public var template: NoteTemplate { NoteTemplate(rawValue: id) }

    public static let maxNameLength = 40
    /// Generous. A template is headings and blank lines, not a document — but a counsellor
    /// who wants a checklist in theirs should not be told a round number is the limit.
    public static let maxBodyLength = 4_000
}

/// Which templates the note screen offers.
///
/// A device setting, exactly like `NoteFieldSettings` and for the same reason: adding a
/// template must never write to the vault. The trade-off is the same too — a counsellor who
/// makes a template on a Mac makes it again on their iPhone. What crosses between devices
/// is what actually matters: a note written from a template carries that template's
/// identifier, and the other device reads it back as `Trauma review` whether or not it has
/// ever been told what a trauma review is.
public struct NoteTemplateSettings: Equatable, Codable, Sendable {
    public var templates: [NoteTemplateDefinition]

    public init(templates: [NoteTemplateDefinition]) {
        self.templates = templates
    }

    public static let builtIns: [NoteTemplateDefinition] = [
        NoteTemplateDefinition(
            id: NoteTemplate.freeform.rawValue,
            name: NoteTemplate.freeform.displayName,
            body: "",
            isBuiltIn: true
        ),
        NoteTemplateDefinition(
            id: NoteTemplate.soap.rawValue,
            name: NoteTemplate.soap.displayName,
            body: "Subjective\n\n\nObjective\n\n\nAssessment\n\n\nPlan\n\n",
            isBuiltIn: true
        ),
        NoteTemplateDefinition(
            id: NoteTemplate.dap.rawValue,
            name: NoteTemplate.dap.displayName,
            body: "Data\n\n\nAssessment\n\n\nPlan\n\n",
            isBuiltIn: true
        )
    ]

    public static let `default` = NoteTemplateSettings(templates: builtIns)

    public var custom: [NoteTemplateDefinition] {
        templates.filter { !$0.isBuiltIn }
    }

    /// Re-adds any built-in the stored settings predate, and puts the built-ins back in
    /// front. Without this, shipping a fourth built-in would be invisible to every install
    /// that has ever saved a template.
    public func normalised() -> NoteTemplateSettings {
        var result = Self.builtIns
        for stored in templates where !stored.isBuiltIn && !result.contains(where: { $0.id == stored.id }) {
            result.append(stored)
        }
        return NoteTemplateSettings(templates: result)
    }

    // MARK: - Reading

    public func definition(for template: NoteTemplate) -> NoteTemplateDefinition? {
        templates.first { $0.id == template.rawValue }
    }

    /// What to call a template on screen. A note written from a template this device does
    /// not have — made on another device, or deleted since — still gets a readable name
    /// rather than a blank or an identifier, because the identifier *is* the name with the
    /// punctuation taken out.
    public func displayName(for template: NoteTemplate) -> String {
        definition(for: template)?.name ?? template.displayName
    }

    /// What a new note starts with. Unknown templates prefill nothing, which is right:
    /// guessing at headings this device has never seen would put words in the record.
    public func starterBody(for template: NoteTemplate) -> String {
        definition(for: template)?.body ?? ""
    }

    // MARK: - Editing

    /// Turns what the counsellor typed into an identifier: `Trauma review` →
    /// `trauma-review`. The same rule note fields use, so the two behave alike and neither
    /// can produce something the one-line `key: value` header format cannot carry.
    public static func identifier(from name: String) -> String {
        NoteFieldDefinition.key(from: name)
    }

    /// One line, no runs of spaces. A template name is shown in a picker row and a note's
    /// summary line, neither of which has anywhere to put a second line.
    private static func tidied(name: String) -> String {
        name
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    @discardableResult
    public mutating func addCustomTemplate(name: String, body: String) throws -> NoteTemplateDefinition {
        let trimmedName = Self.tidied(name: name)
        guard !trimmedName.isEmpty else {
            throw VaultError.invalidNoteTemplate(name, reason: "it needs a name")
        }
        guard trimmedName.count <= NoteTemplateDefinition.maxNameLength else {
            throw VaultError.invalidNoteTemplate(trimmedName, reason: "a template name has to be \(NoteTemplateDefinition.maxNameLength) characters or fewer")
        }

        let id = Self.identifier(from: trimmedName)
        guard !id.isEmpty else {
            throw VaultError.invalidNoteTemplate(trimmedName, reason: "it needs at least one letter or number in it")
        }
        guard !templates.contains(where: { $0.id == id }) else {
            throw VaultError.invalidNoteTemplate(trimmedName, reason: "there is already a template called that")
        }

        let definition = NoteTemplateDefinition(
            id: id,
            name: trimmedName,
            body: Self.trimmedBody(body),
            isBuiltIn: false
        )
        templates.append(definition)
        return definition
    }

    /// Renames a template or changes what it prefills. The identifier is left alone, so
    /// every note already written from it still points at it.
    public mutating func updateCustomTemplate(id: String, name: String, body: String) throws {
        guard let index = templates.firstIndex(where: { $0.id == id }), !templates[index].isBuiltIn else {
            throw VaultError.invalidNoteTemplate(name, reason: "that template isn't one you can change")
        }

        let trimmedName = Self.tidied(name: name)
        guard !trimmedName.isEmpty else {
            throw VaultError.invalidNoteTemplate(name, reason: "it needs a name")
        }
        guard trimmedName.count <= NoteTemplateDefinition.maxNameLength else {
            throw VaultError.invalidNoteTemplate(trimmedName, reason: "a template name has to be \(NoteTemplateDefinition.maxNameLength) characters or fewer")
        }
        guard !templates.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) else {
            throw VaultError.invalidNoteTemplate(trimmedName, reason: "there is already a template called that")
        }

        templates[index].name = trimmedName
        templates[index].body = Self.trimmedBody(body)
    }

    /// Removing a template only stops it being offered on new notes. Notes already written
    /// from it are untouched and still say which template they used — the record is
    /// append-only, and a setting cannot rewrite it.
    public mutating func removeCustomTemplate(id: String) {
        templates.removeAll { $0.id == id && !$0.isBuiltIn }
    }

    private static func trimmedBody(_ body: String) -> String {
        String(body.prefix(NoteTemplateDefinition.maxBodyLength))
    }
}
