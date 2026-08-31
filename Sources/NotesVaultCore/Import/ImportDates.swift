import Foundation

/// A date lifted out of somebody else's file.
public struct ParsedDate: Hashable, Sendable {
    public let date: Date
    /// Exactly the text it was read from, so the review screen can show the counsellor what
    /// the app thought it saw rather than only what it decided.
    public let raw: String
    public let hasTime: Bool
    /// True when the source wrote it as digits and both numbers were 12 or less, so
    /// `06/07/2026` could be 6 July or 7 June and only the day-first setting decided.
    public let isAmbiguousOrder: Bool
    /// Where in the text it was found.
    public let range: Range<String.Index>

    public init(date: Date, raw: String, hasTime: Bool, isAmbiguousOrder: Bool, range: Range<String.Index>) {
        self.date = date
        self.raw = raw
        self.hasTime = hasTime
        self.isAmbiguousOrder = isAmbiguousOrder
        self.range = range
    }
}

/// Reading dates out of imported text.
///
/// **Day first by default, and said out loud.** A UK counsellor's records are full of
/// `06/07/2026`, which is 6 July here and 7 June in an American spreadsheet. There is no
/// way to tell from the file, so the app picks day-first, marks every such date as
/// ambiguous, and the review screen states the reading before anything is written. Getting
/// a session date a month wrong in a clinical record is not a cosmetic bug.
public enum ImportDates {
    private static let monthNames: [String: Int] = {
        var map: [String: Int] = [:]
        let full = [
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december"
        ]
        for (offset, name) in full.enumerated() {
            map[name] = offset + 1
            map[String(name.prefix(3))] = offset + 1
        }
        map["sept"] = 9
        return map
    }()

    /// Two-digit years: `26` is 2026, `98` is 1998. The pivot is next year rather than a
    /// fixed constant, so this does not quietly start misreading in 2050.
    static func fullYear(_ value: Int, now: Date = Date()) -> Int {
        guard value < 100 else { return value }
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: now)
        let candidate = 2000 + value
        return candidate <= currentYear + 1 ? candidate : 1900 + value
    }

    private struct Candidate {
        let range: NSRange
        let day: Int
        let month: Int
        let year: Int
        let ambiguous: Bool
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Force-try is safe on a literal pattern compiled once; a typo here is a crash on
        // the first test run, not something that can reach a counsellor.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // The trailing guard is `(?!\d)` rather than `\b`, because `2026-06-14T09:30` has no
    // word boundary between the day and the `T` — and that is the shape half of the
    // machine-written dates in the world arrive in.
    private static let isoPattern = regex(#"\b(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?!\d)"#)
    private static let numericPattern = regex(#"\b(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})(?!\d)"#)
    private static let dayMonthWordPattern = regex(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,9})\.?,?\s+(\d{2,4})\b"#)
    private static let monthDayWordPattern = regex(#"\b([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{2,4})\b"#)
    // `(?<!\d)` rather than `\b` for the same reason as the date patterns: in
    // `2026-06-14T09:30` there is no word boundary in front of the time either.
    private static let timePattern = regex(#"(?<!\d)(\d{1,2})[:.](\d{2})(?::(\d{2}))?\s*([ap])\.?m\.?|(?<!\d)(\d{1,2})[:.](\d{2})(?::(\d{2}))?(?!\d)|(?<!\d)(\d{1,2})\s*([ap])\.?m\.?\b"#)

    /// The first date in the text, or nil.
    public static func first(
        in text: String,
        dayFirst: Bool = true,
        timeZone: TimeZone = .current,
        now: Date = Date()
    ) -> ParsedDate? {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        var candidates: [Candidate] = []

        if let match = isoPattern.firstMatch(in: text, options: [], range: full),
           let year = intAt(1, match, text), let month = intAt(2, match, text), let day = intAt(3, match, text) {
            candidates.append(Candidate(range: match.range, day: day, month: month, year: year, ambiguous: false))
        }
        if let match = dayMonthWordPattern.firstMatch(in: text, options: [], range: full),
           let day = intAt(1, match, text), let name = stringAt(2, match, text),
           let month = monthNames[name.lowercased()], let year = intAt(3, match, text) {
            candidates.append(Candidate(range: match.range, day: day, month: month, year: fullYear(year, now: now), ambiguous: false))
        }
        if let match = monthDayWordPattern.firstMatch(in: text, options: [], range: full),
           let name = stringAt(1, match, text), let month = monthNames[name.lowercased()],
           let day = intAt(2, match, text), let year = intAt(3, match, text) {
            candidates.append(Candidate(range: match.range, day: day, month: month, year: fullYear(year, now: now), ambiguous: false))
        }
        if let match = numericPattern.firstMatch(in: text, options: [], range: full),
           let first = intAt(1, match, text), let second = intAt(2, match, text), let year = intAt(3, match, text) {
            let ambiguous = first <= 12 && second <= 12
            // Only genuinely ambiguous dates follow the setting. When one of the two
            // numbers is over twelve it cannot be a month, and the file has told us which
            // way round it is — insisting on the preference there would throw the date
            // away or, worse, keep an impossible one.
            let dayFirstHere: Bool
            if first > 12 {
                dayFirstHere = true
            } else if second > 12 {
                dayFirstHere = false
            } else {
                dayFirstHere = dayFirst
            }
            let day = dayFirstHere ? first : second
            let month = dayFirstHere ? second : first
            candidates.append(Candidate(range: match.range, day: day, month: month, year: fullYear(year, now: now), ambiguous: ambiguous))
        }

        // Earliest in the text wins; a tie goes to the longer match, which is the more
        // specific pattern (a word month beats the digits inside it).
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.range.location == rhs.range.location { return lhs.range.length > rhs.range.length }
            return lhs.range.location < rhs.range.location
        }

        for candidate in ordered {
            guard let range = Range(candidate.range, in: text) else { continue }
            guard var date = makeDate(
                year: candidate.year, month: candidate.month, day: candidate.day,
                hour: 0, minute: 0, timeZone: timeZone
            ) else { continue }

            var raw = String(text[range])
            var hasTime = false
            if let time = firstTime(in: text, after: range),
               let withTime = makeDate(
                   year: candidate.year, month: candidate.month, day: candidate.day,
                   hour: time.hour, minute: time.minute, timeZone: timeZone
               ) {
                date = withTime
                hasTime = true
                raw = String(text[range.lowerBound..<time.range.upperBound])
            }
            return ParsedDate(
                date: date,
                raw: raw,
                hasTime: hasTime,
                isAmbiguousOrder: candidate.ambiguous,
                range: range
            )
        }
        return nil
    }

    /// A date that *starts* a line, which is how a running document marks a new session:
    /// `14/06/2026 — did not attend`. Used by the splitter, where a date mentioned in the
    /// middle of a paragraph must not cut the note in half.
    public static func leading(
        in line: String,
        dayFirst: Bool = true,
        timeZone: TimeZone = .current,
        now: Date = Date()
    ) -> ParsedDate? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // A heading, a bullet or a "Session 4 —" prefix still counts as leading.
        let stripped = trimmed.drop { character in
            character == "#" || character == "*" || character == "-" || character == "•" || character == ">" || character == " "
        }
        // A new String, because `parsed.range` indexes into whatever was passed in — and
        // an index from one string used against another is undefined behaviour, not a
        // wrong answer you would notice.
        let candidate = String(stripped)
        guard let parsed = first(in: candidate, dayFirst: dayFirst, timeZone: timeZone, now: now) else { return nil }
        // Within the first few characters, so "we agreed to meet on 14/06/2026" is not a
        // session boundary but "14/06/2026 — session 4" is.
        let prefixLength = candidate.distance(from: candidate.startIndex, to: parsed.range.lowerBound)
        guard prefixLength <= 12 else { return nil }
        return parsed
    }

    // MARK: - Plumbing

    private static func intAt(_ index: Int, _ match: NSTextCheckingResult, _ text: String) -> Int? {
        guard let string = stringAt(index, match, text) else { return nil }
        return Int(string)
    }

    private static func stringAt(_ index: Int, _ match: NSTextCheckingResult, _ text: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    private static func firstTime(in text: String, after dateRange: Range<String.Index>) -> (hour: Int, minute: Int, range: Range<String.Index>)? {
        // Only just after the date. A time three lines further down belongs to something else.
        let searchStart = dateRange.upperBound
        let searchEnd = text.index(searchStart, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
        guard searchStart < searchEnd else { return nil }
        let window = String(text[searchStart..<searchEnd])
        guard !window.contains("\n") else { return nil }

        let range = NSRange(window.startIndex..<window.endIndex, in: window)
        guard let match = timePattern.firstMatch(in: window, options: [], range: range),
              let matchRange = Range(match.range, in: window) else { return nil }
        // Anything more than a separator between the date and the time is a different thing.
        let gap = window[window.startIndex..<matchRange.lowerBound]
        guard gap.allSatisfy({ $0 == " " || $0 == "," || $0 == "-" || $0 == "—" || $0 == "–" || $0 == "@" || $0 == "T" || $0 == "t" }) else { return nil }

        var hour: Int?
        var minute = 0
        var meridiem: String?

        if let value = stringAt(1, match, window) {                  // 9:30am
            hour = Int(value)
            minute = stringAt(2, match, window).flatMap(Int.init) ?? 0
            meridiem = stringAt(4, match, window)?.lowercased()
        } else if let value = stringAt(5, match, window) {           // 09:30
            hour = Int(value)
            minute = stringAt(6, match, window).flatMap(Int.init) ?? 0
        } else if let value = stringAt(8, match, window) {           // 9am
            hour = Int(value)
            meridiem = stringAt(9, match, window)?.lowercased()
        }

        guard var resolved = hour, resolved <= 23, minute <= 59 else { return nil }
        if meridiem == "p", resolved < 12 { resolved += 12 }
        if meridiem == "a", resolved == 12 { resolved = 0 }
        guard resolved <= 23 else { return nil }

        let absolute = text.index(searchStart, offsetBy: window.distance(from: window.startIndex, to: matchRange.lowerBound))
        let absoluteEnd = text.index(searchStart, offsetBy: window.distance(from: window.startIndex, to: matchRange.upperBound))
        return (resolved, minute, absolute..<absoluteEnd)
    }

    /// Builds the date and refuses one the calendar had to correct — `31/02/2026` rolls
    /// forward to 3 March if you let it, which would file a note under a session that
    /// never happened.
    private static func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, timeZone: TimeZone) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), (1900...2200).contains(year) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return date
    }
}
