import Foundation

/// The extra things a counsellor can record alongside a note, beyond the session date.
///
/// These ride in `NoteRecord.extraHeaders`, which the note format has always round-tripped:
/// an unknown `key: value` header is preserved on read and re-emitted on write. So nothing
/// here changes the on-disk format, and a note written with a "Location" field still opens
/// in a text editor — and in a copy of this app that has never heard of that field.
///
/// Which fields exist is a device setting, not a vault setting. That mirrors
/// `RetentionPolicy`, and it means turning a field on never writes to the vault. The
/// trade-off is that a counsellor who sets up fields on a Mac sets them up again on their
/// iPhone; the notes themselves carry their values either way, so nothing is lost by it.
public enum NoteFieldKind: String, Codable, CaseIterable, Sendable {
    case text
    case number

    public var displayName: String {
        switch self {
        case .text: return "Text"
        case .number: return "Number"
        }
    }
}

public struct NoteFieldDefinition: Identifiable, Hashable, Codable, Sendable {
    /// The header key this field writes, e.g. `location`. Lower case, because the parser
    /// lower-cases every header key it reads and the two must agree.
    public let key: String
    public var label: String
    public var kind: NoteFieldKind
    public var isEnabled: Bool
    /// Built-in fields can be switched off but not deleted, so turning one off and on again
    /// does not lose the label a counsellor is used to seeing.
    public let isBuiltIn: Bool

    public var id: String { key }

    public init(key: String, label: String, kind: NoteFieldKind, isEnabled: Bool, isBuiltIn: Bool) {
        self.key = key
        self.label = label
        self.kind = kind
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
    }

    // MARK: - Validation

    /// Header names the note format uses itself. A custom field may not shadow one of these,
    /// because `NoteRecord.parse` would read it as the real header and the note would come
    /// back wrong.
    public static let reservedKeys: Set<String> = [
        "id", "client", "session", "written", "device", "template", "supersedes"
    ]

    public static let maxLabelLength = 40
    public static let maxValueLength = 200

    /// Turns what the counsellor typed into a header key: `Session number` → `session-number`.
    public static func key(from label: String) -> String {
        let lowered = label.lowercased()
        let mapped = lowered.map { character -> Character in
            if character.isASCII && (character.isLetter || character.isNumber) { return character }
            return "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(collapsed.prefix(32))
    }

    /// A header value has to survive being written as one line of `key: value` and read
    /// back. Newlines are the only thing that genuinely breaks that — a blank line would
    /// end the header block and swallow the rest of the note into the body — so they are
    /// folded to spaces rather than rejected.
    public static func sanitise(value: String) -> String {
        let folded = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let collapsed = folded
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return String(collapsed.prefix(maxValueLength)).trimmingCharacters(in: .whitespaces)
    }
}

public struct NoteFieldSettings: Equatable, Codable, Sendable {
    public var fields: [NoteFieldDefinition]

    public init(fields: [NoteFieldDefinition]) {
        self.fields = fields
    }

    /// The two the handover's users asked for first, both off until switched on. A field
    /// that appeared uninvited on the note screen would be a change to the clinical record
    /// nobody chose.
    public static let builtIns: [NoteFieldDefinition] = [
        NoteFieldDefinition(key: "session-number", label: "Session number", kind: .number, isEnabled: false, isBuiltIn: true),
        NoteFieldDefinition(key: "location", label: "Location", kind: .text, isEnabled: false, isBuiltIn: true)
    ]

    public static let `default` = NoteFieldSettings(fields: builtIns)

    public var enabled: [NoteFieldDefinition] {
        fields.filter(\.isEnabled)
    }

    public var custom: [NoteFieldDefinition] {
        fields.filter { !$0.isBuiltIn }
    }

    /// Re-adds any built-in the stored settings predate, keeping whatever the counsellor
    /// had already chosen for the ones they have seen. Without this, shipping a new
    /// built-in would be invisible to every existing install.
    public func normalised() -> NoteFieldSettings {
        var result = fields
        for builtIn in Self.builtIns where !result.contains(where: { $0.key == builtIn.key }) {
            result.append(builtIn)
        }
        return NoteFieldSettings(fields: result)
    }

    // MARK: - Editing

    @discardableResult
    public mutating func addCustomField(label: String, kind: NoteFieldKind) throws -> NoteFieldDefinition {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            throw VaultError.invalidNoteField(label, reason: "it needs a name")
        }
        guard trimmedLabel.count <= NoteFieldDefinition.maxLabelLength else {
            throw VaultError.invalidNoteField(trimmedLabel, reason: "a field name has to be \(NoteFieldDefinition.maxLabelLength) characters or fewer")
        }

        let key = NoteFieldDefinition.key(from: trimmedLabel)
        guard !key.isEmpty else {
            throw VaultError.invalidNoteField(trimmedLabel, reason: "it needs at least one letter or number in it")
        }
        guard !NoteFieldDefinition.reservedKeys.contains(key) else {
            throw VaultError.invalidNoteField(trimmedLabel, reason: "the note format already uses \"\(key)\" for something else")
        }
        guard !fields.contains(where: { $0.key == key }) else {
            throw VaultError.invalidNoteField(trimmedLabel, reason: "there is already a field called that")
        }

        let field = NoteFieldDefinition(key: key, label: trimmedLabel, kind: kind, isEnabled: true, isBuiltIn: false)
        fields.append(field)
        return field
    }

    /// Removing a custom field only stops it being offered on new notes. Notes already
    /// written keep their value, and it is still shown when one of them is read back —
    /// the record is append-only, and a setting cannot rewrite it.
    public mutating func removeCustomField(key: String) {
        fields.removeAll { $0.key == key && !$0.isBuiltIn }
    }

    public mutating func setEnabled(_ enabled: Bool, forKey key: String) {
        guard let index = fields.firstIndex(where: { $0.key == key }) else { return }
        fields[index].isEnabled = enabled
    }

    // MARK: - Reading and writing note headers

    /// Builds the `extraHeaders` for a note from what was typed on the note screen.
    /// Empty values are dropped rather than written blank, so a field left alone leaves no
    /// trace in the record.
    public func headers(from values: [String: String]) -> [String: String] {
        var headers: [String: String] = [:]
        for field in enabled {
            guard let raw = values[field.key] else { continue }
            let value = NoteFieldDefinition.sanitise(value: raw)
            guard !value.isEmpty else { continue }
            headers[field.key] = value
        }
        return headers
    }

    /// What to show when reading a note back: every extra header it carries, labelled with
    /// the field's name where this device knows one, and with the raw key where it does not
    /// — a note written on a device with a field this one has never heard of still shows
    /// its value rather than hiding it.
    public func describe(headers: [String: String]) -> [(label: String, value: String)] {
        var described: [(label: String, value: String)] = []
        var remaining = headers

        for field in fields {
            if let value = remaining.removeValue(forKey: field.key), !value.isEmpty {
                described.append((field.label, value))
            }
        }
        for key in remaining.keys.sorted() {
            let value = remaining[key] ?? ""
            guard !value.isEmpty else { continue }
            described.append((key, value))
        }
        return described
    }
}
