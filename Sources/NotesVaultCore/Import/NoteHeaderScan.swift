import Foundation

/// A `Label: value` line found at the top of an imported note.
public struct DetectedField: Hashable, Sendable {
    /// As the source wrote it — "Session number", "Duration", "Room".
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    /// The header key it would be stored under, which is also how it is matched against
    /// the fields this device already has.
    public var key: String { NoteFieldDefinition.key(from: label) }
}

/// Pulling the metadata block off the top of an imported note.
///
/// **Why this is worth doing.** People who kept notes in Word or Notes almost always wrote
/// a little block at the top — `Session number: 4`, `Duration: 50 minutes`, `Room: 2` —
/// because there was nowhere else to put it. This app has somewhere else to put it: note
/// fields, which ride in the note's headers, show as labelled metadata rather than prose,
/// and can be read back on a device that has never heard of the field. Left in the body,
/// the same information is a paragraph that no screen can do anything with.
///
/// **Nothing is moved without being asked.** A line only leaves the body if the counsellor
/// has chosen a field for it. The default for anything this app does not already have a
/// field for is to leave the note exactly as it was found — silently restructuring a
/// clinical record on a pattern match is not a decision an importer gets to make.
public enum NoteHeaderScan {
    /// How far down a note to look. A metadata block is at the top or it is not a metadata
    /// block.
    public static let lineLimit = 15

    /// Labels that say when the session was. The session date is read separately and is
    /// part of the note's identity, so these are never offered as fields.
    static let dateLikeKeys: Set<String> = [
        "date", "session-date", "time", "session-time", "start", "start-time",
        "when", "day", "appointment", "appointment-date", "seen"
    ]

    /// Labels that hold a person rather than a fact about a session. Offering these as
    /// fields would put a "Name" field in an app built so that names cannot be stored —
    /// so they stay in the body, where the identifying-details scan will flag them.
    static let identityKeys: Set<String> = [
        "name", "client-name", "full-name", "patient", "patient-name", "surname",
        "dob", "d-o-b", "date-of-birth", "born", "address", "postcode", "phone",
        "telephone", "mobile", "email", "e-mail", "nhs-number", "nhs-no", "next-of-kin",
        "gp", "emergency-contact"
    ]

    /// Every metadata line in a note, with the line it was found on.
    static func scan(_ body: String) -> [(line: Int, field: DetectedField)] {
        var found: [(line: Int, field: DetectedField)] = []
        let lines = body.components(separatedBy: "\n")

        for (index, raw) in lines.enumerated() {
            guard index < lineLimit else { break }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // A blank line ends the block — but only once the block has started, so a
                // note that opens with a blank line is not written off.
                if !found.isEmpty { break }
                continue
            }
            if let field = field(from: trimmed) {
                found.append((index, field))
                continue
            }
            // Not a metadata line. A short line near the top is a title and the block may
            // still be under it; anything else means the note itself has started.
            if index <= 2 && trimmed.count <= 60 { continue }
            break
        }
        return found
    }

    /// The metadata worth offering as fields: everything found, minus the dates, the
    /// identities and anything the note format already uses for itself.
    public static func detect(in body: String) -> [DetectedField] {
        scan(body).map(\.field).filter { isOfferable($0.key) }
    }

    static func isOfferable(_ key: String) -> Bool {
        !key.isEmpty
            && !NoteFieldDefinition.reservedKeys.contains(key)
            && !dateLikeKeys.contains(key)
            && !identityKeys.contains(key)
            && !key.hasPrefix("imported-")
    }

    /// Applies the counsellor's decisions: the lines they chose a field for are lifted out
    /// of the body and returned as headers; everything else is left exactly where it was.
    ///
    /// - Parameter accepting: label key → the field key to store it under. A label absent
    ///   from this map stays in the note.
    public static func apply(to body: String, accepting: [String: String]) -> (body: String, headers: [String: String]) {
        let found = scan(body)
        guard !found.isEmpty, !accepting.isEmpty else { return (body, [:]) }

        var headers: [String: String] = [:]
        var removed = Set<Int>()

        for entry in found {
            guard isOfferable(entry.field.key), let fieldKey = accepting[entry.field.key] else { continue }
            let value = NoteFieldDefinition.sanitise(value: entry.field.value)
            guard !value.isEmpty else { continue }
            // First value wins if a note somehow repeats a label, which is the same rule
            // the note format's own header parser follows.
            if headers[fieldKey] == nil { headers[fieldKey] = value }
            removed.insert(entry.line)
        }
        guard !removed.isEmpty else { return (body, [:]) }

        let kept = body
            .components(separatedBy: "\n")
            .enumerated()
            .filter { !removed.contains($0.offset) }
            .map(\.element)

        // Leading blank lines left behind by the block are tidied; the rest of the note is
        // untouched, including any spacing inside it.
        var trimmedLines = kept
        while let first = trimmedLines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            trimmedLines.removeFirst()
        }
        return (trimmedLines.joined(separator: "\n"), headers)
    }

    /// One line, if it reads as `Label: value` rather than as a sentence with a colon in it.
    static func field(from line: String) -> DetectedField? {
        guard let colon = line.firstIndex(of: ":") else { return nil }

        // Markdown survives an export from Notes, so `**Session number:** 4` and
        // `- Location: Room 2` are the same line as far as this is concerned.
        let markers = CharacterSet(charactersIn: " *_#>-•\t")
        let label = String(line[line.startIndex..<colon]).trimmingCharacters(in: markers)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: markers)

        guard !label.isEmpty, !value.isEmpty else { return nil }
        guard label.count <= NoteFieldDefinition.maxLabelLength else { return nil }
        // A value longer than this is prose that happens to follow a colon, not a fact
        // about the session.
        guard value.count <= 120 else { return nil }

        let words = label.split(whereSeparator: { $0 == " " })
        guard words.count <= 4 else { return nil }
        guard label.rangeOfCharacter(from: .letters) != nil else { return nil }
        guard label.allSatisfy({ $0.isLetter || $0.isNumber || " -/()&'".contains($0) }) else { return nil }

        return DetectedField(label: label, value: value)
    }
}

/// One kind of metadata found across the whole import, and what this device already knows
/// about it.
public struct ImportFieldCandidate: Identifiable, Hashable, Sendable {
    public let label: String
    public let key: String
    /// How many of the notes being imported carry it.
    public let occurrences: Int
    /// A few real values, so the counsellor can see what they are agreeing to.
    public let examples: [String]
    /// `.number` when every value seen is one.
    public let suggestedKind: NoteFieldKind
    /// The field on this device that matches, if there is one.
    public let matchingFieldKey: String?
    public let matchingFieldLabel: String?
    public let matchingFieldIsEnabled: Bool

    public var id: String { key }

    public init(
        label: String,
        key: String,
        occurrences: Int,
        examples: [String],
        suggestedKind: NoteFieldKind,
        matchingFieldKey: String?,
        matchingFieldLabel: String?,
        matchingFieldIsEnabled: Bool
    ) {
        self.label = label
        self.key = key
        self.occurrences = occurrences
        self.examples = examples
        self.suggestedKind = suggestedKind
        self.matchingFieldKey = matchingFieldKey
        self.matchingFieldLabel = matchingFieldLabel
        self.matchingFieldIsEnabled = matchingFieldIsEnabled
    }

    /// Gathers the metadata across every note in an import.
    public static func gather(from items: [ImportedItem], noteFields: NoteFieldSettings) -> [ImportFieldCandidate] {
        var order: [String] = []
        var labels: [String: String] = [:]
        var counts: [String: Int] = [:]
        var values: [String: [String]] = [:]

        for item in items {
            for field in NoteHeaderScan.detect(in: item.body) {
                if counts[field.key] == nil {
                    order.append(field.key)
                    labels[field.key] = field.label
                }
                counts[field.key, default: 0] += 1
                if (values[field.key]?.count ?? 0) < 3, !(values[field.key] ?? []).contains(field.value) {
                    values[field.key, default: []].append(field.value)
                }
            }
        }

        return order.map { key in
            let seen = values[key] ?? []
            let match = noteFields.fields.first { $0.key == key }
            return ImportFieldCandidate(
                label: labels[key] ?? key,
                key: key,
                occurrences: counts[key] ?? 0,
                examples: seen,
                suggestedKind: seen.allSatisfy { Double($0.replacingOccurrences(of: ",", with: "")) != nil } ? .number : .text,
                matchingFieldKey: match?.key,
                matchingFieldLabel: match?.label,
                matchingFieldIsEnabled: match?.isEnabled ?? false
            )
        }
    }
}

/// What to do with one kind of metadata.
public enum ImportFieldDecision: Hashable, Sendable {
    /// Leave the line in the note exactly as it was written. The default for anything this
    /// device has no field for.
    case leaveInNote
    /// Lift it out of the note and store it as this field.
    case store(fieldKey: String)
}
