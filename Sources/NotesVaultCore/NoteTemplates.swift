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
    /// Built-ins cannot be *edited* — a counsellor's own version of SOAP is a new template
    /// started from it, which is what the "start from" choice is for. They can be removed,
    /// and removing one only takes it off the picker: it is hidden rather than deleted, so
    /// it can be put back with the headings it always had.
    public let isBuiltIn: Bool
    /// Removed from the picker but kept. Only ever true of a built-in — a template the
    /// counsellor wrote is deleted outright when they remove it, because they have the only
    /// copy of what it said and nothing else can restore it.
    public var isHidden: Bool

    public init(id: String, name: String, body: String, isBuiltIn: Bool, isHidden: Bool = false) {
        self.id = id
        self.name = name
        self.body = body
        self.isBuiltIn = isBuiltIn
        self.isHidden = isHidden
    }

    public var template: NoteTemplate { NoteTemplate(rawValue: id) }

    /// Freeform is the one template that stays. It is not really a template — it is what a
    /// note with no template is, and prefills nothing by definition — so removing it from
    /// the picker would mean a new note with nowhere to start.
    public var isRemovable: Bool { id != NoteTemplate.freeform.rawValue }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, body, isBuiltIn, isHidden
    }

    /// Written by hand for one reason: settings saved before templates could be removed have
    /// no `isHidden` key, and everything in them was being offered. The synthesised
    /// initialiser would refuse to decode them and quietly reset the counsellor's templates.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        body = try container.decode(String.self, forKey: .body)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }

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

    /// The headings each one prefills are written as Markdown subheadings, so a note started
    /// from SOAP reads back with four subheadings rather than four sentences that happen to
    /// be on their own lines. They are still plain text: `## Subjective` is what the file
    /// says and what a text editor shows.
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
            body: "## Subjective\n\n\n## Objective\n\n\n## Assessment\n\n\n## Plan\n\n",
            isBuiltIn: true
        ),
        NoteTemplateDefinition(
            id: NoteTemplate.dap.rawValue,
            name: NoteTemplate.dap.displayName,
            body: "## Data\n\n\n## Assessment\n\n\n## Plan\n\n",
            isBuiltIn: true
        )
    ]

    public static let `default` = NoteTemplateSettings(templates: builtIns)

    public var custom: [NoteTemplateDefinition] {
        templates.filter { !$0.isBuiltIn }
    }

    /// What the note screen offers. Everything except the built-ins the counsellor has
    /// removed — which are kept, so they can be put back, but are not offered.
    public var offered: [NoteTemplateDefinition] {
        templates.filter { !$0.isHidden }
    }

    /// Built-ins that have been removed, in the order they ship in, so the settings screen
    /// can offer them back.
    public var removed: [NoteTemplateDefinition] {
        templates.filter(\.isHidden)
    }

    /// Re-adds any built-in the stored settings predate, and puts the built-ins back in
    /// front. Without this, shipping a fourth built-in would be invisible to every install
    /// that has ever saved a template.
    ///
    /// A built-in's name and headings come from this build, so a wording change ships to
    /// everyone. The one thing carried across from what was stored is whether the counsellor
    /// removed it — a settings load must not put a template back on the picker after they
    /// took it off.
    public func normalised() -> NoteTemplateSettings {
        var result: [NoteTemplateDefinition] = Self.builtIns.map { builtIn in
            var updated = builtIn
            updated.isHidden = templates.first { $0.id == builtIn.id }?.isHidden ?? false
            return updated
        }
        for stored in templates where !stored.isBuiltIn && !result.contains(where: { $0.id == stored.id }) {
            var updated = stored
            // A template of the counsellor's own is never hidden — removing one deletes it —
            // so a stored flag saying otherwise would hide it with no way to get it back.
            updated.isHidden = false
            result.append(updated)
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
        if let clash = templates.first(where: { $0.id == id }) {
            // Naming the removed one matters: otherwise "there is already a template called
            // that" is said about a template the counsellor cannot see anywhere.
            throw VaultError.invalidNoteTemplate(
                trimmedName,
                reason: clash.isHidden
                    ? "there is a removed template called that — put it back instead"
                    : "there is already a template called that"
            )
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
    ///
    /// A built-in is hidden rather than deleted, so "remove SOAP" can be undone and comes
    /// back with the headings it always had. One of the counsellor's own goes for good:
    /// keeping a deleted template in the settings file would mean a name they thought they
    /// had got rid of.
    public mutating func removeTemplate(id: String) throws {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        let template = templates[index]

        guard template.isRemovable else {
            throw VaultError.invalidNoteTemplate(
                template.name,
                reason: "it is what a note with no template is, so it cannot be removed — every note has to be able to start from a blank page"
            )
        }

        if template.isBuiltIn {
            templates[index].isHidden = true
        } else {
            templates.remove(at: index)
        }
    }

    /// Puts a removed built-in back on the picker.
    public mutating func restoreTemplate(id: String) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[index].isHidden = false
    }

    private static func trimmedBody(_ body: String) -> String {
        String(body.prefix(NoteTemplateDefinition.maxBodyLength))
    }
}
