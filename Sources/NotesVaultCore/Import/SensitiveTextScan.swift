import Foundation

/// Something in an imported note that identifies a person.
public struct SensitiveMatch: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case name
        case email
        case phone
        case postcode
        case nhsNumber
        case dateOfBirth

        public var displayName: String {
            switch self {
            case .name: return "Name"
            case .email: return "Email address"
            case .phone: return "Phone number"
            case .postcode: return "Postcode"
            case .nhsNumber: return "NHS number"
            case .dateOfBirth: return "Date of birth"
            }
        }

        /// Whether the app will offer to take it out automatically. Only the name is
        /// offered: it has a known replacement — the client code — and every other kind
        /// would be the app editing a clinical record on a guess.
        public var isAutoReplaceable: Bool { self == .name }
    }

    public let kind: Kind
    /// Exactly what was matched.
    public let text: String
    /// A few words either side, so the counsellor can see what they are looking at.
    public let context: String

    public init(kind: Kind, text: String, context: String) {
        self.kind = kind
        self.text = text
        self.context = context
    }

    public var id: String { "\(kind.rawValue)|\(text)|\(context)" }
}

/// Finding identifying details in text that was written somewhere with no rule against them.
///
/// **Why this is part of importing and not an optional extra.** Everything else in this app
/// is built so a name cannot get in: `ClientCode` will not hold one, there is no name field,
/// and the code-to-person list lives in the counsellor's password manager. Import is the one
/// door where that stops being true — the file being imported was written in Word, where
/// "Sarah rang on Tuesday" is completely normal. Encrypting a note that names its subject is
/// still a great deal better than a Word file that names its subject, so nothing here blocks
/// an import. But the counsellor should be told, once, before it goes in, rather than
/// discovering it in an access request three years later.
///
/// This finds patterns, not people. It will miss a first name it was never told about and
/// it will flag "Dr Green" in a referral. It is a prompt to look, not a guarantee.
public enum SensitiveTextScan {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let email = regex(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#)
    private static let phone = regex(#"(?:\+44\s?\d{2,4}|\(?0\d{3,4}\)?)[\s.-]?\d{3,4}[\s.-]?\d{3,4}"#)
    private static let postcode = regex(#"\b[A-Z]{1,2}\d[A-Z\d]?\s?\d[A-Z]{2}\b"#)
    private static let nhsNumber = regex(#"\b\d{3}[\s-]?\d{3}[\s-]?\d{4}\b"#)
    private static let dateOfBirth = regex(#"\b(?:d\.?o\.?b\.?|date of birth|born)\b[^\n]{0,30}"#)

    /// - Parameter names: the words the counsellor's own source used for this client — the
    ///   folder name, the spreadsheet cell, the note title. Whatever they called the file
    ///   is very likely what they called the person inside it.
    public static func scan(_ text: String, names: [String] = []) -> [SensitiveMatch] {
        var matches: [SensitiveMatch] = []
        var seen = Set<String>()

        func add(_ kind: SensitiveMatch.Kind, _ range: Range<String.Index>) {
            let value = String(text[range]).trimmingCharacters(in: .whitespaces)
            guard value.count >= 2 else { return }
            let match = SensitiveMatch(kind: kind, text: value, context: context(around: range, in: text))
            guard !seen.contains(match.id) else { return }
            seen.insert(match.id)
            matches.append(match)
        }

        for (kind, pattern) in [
            (SensitiveMatch.Kind.email, email),
            (.dateOfBirth, dateOfBirth),
            (.postcode, postcode),
            (.nhsNumber, nhsNumber),
            (.phone, phone)
        ] {
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            for result in pattern.matches(in: text, options: [], range: full) {
                guard let range = Range(result.range, in: text) else { continue }
                add(kind, range)
            }
        }

        for word in nameWords(from: names) {
            for range in ranges(of: word, in: text) {
                add(.name, range)
            }
        }
        return matches
    }

    /// Replaces every occurrence of the source's own words for this client with the client
    /// code. Whole words only and case-insensitive, so "Sarah" goes and "Sarahs" — which
    /// might be a different word entirely — does not.
    public static func replacingNames(in text: String, names: [String], with code: String) -> String {
        var output = text
        // Longest first, so "Sarah Mitchell" is replaced as one name rather than leaving
        // "SM2 SM2" behind.
        for word in nameWords(from: names).sorted(by: { $0.count > $1.count }) {
            var result = ""
            var cursor = output.startIndex
            for range in ranges(of: word, in: output) {
                guard range.lowerBound >= cursor else { continue }
                result += output[cursor..<range.lowerBound]
                result += code
                cursor = range.upperBound
            }
            result += output[cursor...]
            output = result
        }
        return output
    }

    /// The words from a group key worth searching for: `"Sarah M (Tues 9am)"` gives
    /// `["Sarah M (Tues 9am)", "Sarah", "Tues"]` — and drops the initial, the time and
    /// anything under three letters, which would match half the note.
    public static func nameWords(from names: [String]) -> [String] {
        var words: [String] = []
        var seen = Set<String>()

        func consider(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard trimmed.count >= 3 else { return }
            guard trimmed.rangeOfCharacter(from: CharacterSet.letters) != nil else { return }
            guard Int(trimmed) == nil else { return }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return }
            // A phrase made entirely of the words every note contains — "Session notes",
            // "Client file" — is a filename, not a person.
            let parts = key.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            guard parts.contains(where: { !stopWords.contains($0) }) else { return }
            seen.insert(key)
            words.append(trimmed)
        }

        for name in names {
            consider(name)
            for part in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                consider(String(part))
            }
        }
        return words
    }

    /// Words that turn up in filenames and are not anybody's name. Matching on these would
    /// fill the review screen with noise and teach the counsellor to click past it.
    private static let stopWords: Set<String> = [
        "notes", "note", "session", "sessions", "client", "clients", "therapy", "counselling",
        "counseling", "record", "records", "file", "files", "copy", "final", "draft", "new",
        "old", "archive", "export", "docx", "doc", "txt", "csv", "pdf", "rtf", "and", "the",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"
    ]

    private static func ranges(of word: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: word, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            if isWholeWord(range, in: text) { found.append(range) }
            searchStart = range.upperBound
        }
        return found
    }

    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.isLetter || after.isNumber { return false }
        }
        return true
    }

    private static func context(around range: Range<String.Index>, in text: String, radius: Int = 24) -> String {
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let snippet = text[start..<end]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        return prefix + snippet + suffix
    }
}
