import Foundation

/// Date handling for the note format.
///
/// Two different questions, so two different representations. `session` is a wall-clock
/// appointment and keeps its UTC offset, because "the 9:30" means 9:30 where the
/// counsellor was — reading it back an hour out after a clock change would be wrong on the
/// record. `written` is an instant and is always stored in UTC.
public enum VaultDate {
    private static func formatter(_ options: ISO8601DateFormatter.Options, timeZone: TimeZone?) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        if let timeZone { formatter.timeZone = timeZone }
        return formatter
    }

    /// e.g. `2026-06-14T09:30:00+01:00`
    public static func localString(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter([.withInternetDateTime], timeZone: timeZone).string(from: date)
    }

    /// e.g. `2026-06-14T08:30:00Z`
    public static func utcString(_ date: Date) -> String {
        formatter([.withInternetDateTime], timeZone: TimeZone(secondsFromGMT: 0)).string(from: date)
    }

    /// Accepts either shape, with or without fractional seconds.
    public static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let date = formatter([.withInternetDateTime], timeZone: nil).date(from: trimmed) {
            return date
        }
        return formatter([.withInternetDateTime, .withFractionalSeconds], timeZone: nil).date(from: trimmed)
    }

    /// `2026-06-14T0930` — the filename form. Local time, minute precision, no punctuation
    /// that a filesystem or a sync client might object to.
    public static func filenameStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
    }
}

public extension String {
    /// Reduced to the characters that are safe in a filename on every platform this vault
    /// might be synced to, and short enough to stay well under the vault's name limit.
    func asFilenameSlug(maxLength: Int = 16) -> String {
        let kept = self.lowercased().map { character -> Character in
            if character.isASCII && (character.isLetter || character.isNumber) { return character }
            return "-"
        }
        let collapsed = String(kept)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(collapsed.prefix(maxLength))
    }

    /// Word count as a counsellor would mean it, used only for the "how long is this note"
    /// column in the index.
    var wordCount: Int {
        self.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

public extension VaultDate {
    /// Parses an ISO 8601 instant *and* keeps the UTC offset it was written with.
    ///
    /// A `Date` alone would render "the 9:30 on Tuesday" as 10:30 for a counsellor who
    /// later travels, or after the clocks change. The offset is part of the record.
    static func parseWithOffset(_ string: String) -> (date: Date, offsetSeconds: Int)? {
        guard let date = parse(string) else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        if trimmed.hasSuffix("Z") || trimmed.hasSuffix("z") {
            return (date, 0)
        }
        // The offset is the trailing ±HH:MM or ±HHMM, which is the last +/- that appears
        // after the time separator rather than the one in the date.
        let timePart = trimmed.drop(while: { $0 != "T" && $0 != "t" })
        guard let signIndex = timePart.lastIndex(where: { $0 == "+" || $0 == "-" }) else {
            return (date, TimeZone.current.secondsFromGMT(for: date))
        }
        let sign = timePart[signIndex] == "-" ? -1 : 1
        let digits = timePart[timePart.index(after: signIndex)...].filter { $0.isNumber }
        guard digits.count >= 2, let hours = Int(digits.prefix(2)) else {
            return (date, TimeZone.current.secondsFromGMT(for: date))
        }
        let minutes = digits.count >= 4 ? (Int(digits.dropFirst(2).prefix(2)) ?? 0) : 0
        return (date, sign * (hours * 3600 + minutes * 60))
    }
}
