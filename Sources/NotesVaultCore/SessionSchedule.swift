import Foundation

/// Which day of the week a client is usually seen.
///
/// Stored as a three-letter lower-case name rather than a number, because the number would
/// be a `Calendar` convention (1 = Sunday) written into a file that outlives this app, and
/// nobody reading `usual-day: 3` in a decrypted record years from now could tell whether
/// that meant Tuesday or Wednesday.
public enum Weekday: String, CaseIterable, Codable, Sendable {
    case mon, tue, wed, thu, fri, sat, sun

    /// The `Calendar` weekday number, 1 = Sunday through 7 = Saturday.
    public var calendarWeekday: Int {
        switch self {
        case .sun: return 1
        case .mon: return 2
        case .tue: return 3
        case .wed: return 4
        case .thu: return 5
        case .fri: return 6
        case .sat: return 7
        }
    }

    public init?(calendarWeekday: Int) {
        guard let match = Weekday.allCases.first(where: { $0.calendarWeekday == calendarWeekday }) else { return nil }
        self = match
    }

    public var displayName: String {
        switch self {
        case .mon: return "Monday"
        case .tue: return "Tuesday"
        case .wed: return "Wednesday"
        case .thu: return "Thursday"
        case .fri: return "Friday"
        case .sat: return "Saturday"
        case .sun: return "Sunday"
        }
    }
}

/// A time of day, to the minute, with no date and no time zone attached.
///
/// An appointment slot is a local-time fact — "Tuesdays at half nine" does not move when
/// the clocks change, and does not mean something different on holiday. Storing it as an
/// instant would make it do both.
public struct TimeOfDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// Parses `09:30`. Returns nil for anything else, including `9.30` and `9am` — this is
    /// only ever fed by our own writers, and guessing at a format we did not write would be
    /// how a 9am appointment quietly becomes 9pm.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    public var description: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}

/// How often a client is seen, and when.
///
/// The cadence is a **number of days**, not a label. GroundWork's own `freqDays()` maps
/// "Monthly" to a flat 28 days, and a calendar month here would put the two apps a few days
/// apart within a quarter — see `docs/schedule-sync.md`. Carrying days over the wire means
/// that mapping exists in one place per app and the two cannot drift.
public struct SessionSchedule: Hashable, Codable, Sendable {
    /// Sensible values are 7, 14, 21 and 28, but any positive number is accepted — a
    /// counsellor working to a rhythm we did not anticipate is not an error.
    public let cadenceDays: Int
    /// The day the series sits on. When absent, predictions keep whatever day the last
    /// session fell on.
    public let usualDay: Weekday?
    /// The appointment time. When absent, predictions keep the last session's own time.
    public let usualTime: TimeOfDay?

    public init(cadenceDays: Int, usualDay: Weekday? = nil, usualTime: TimeOfDay? = nil) {
        self.cadenceDays = max(1, cadenceDays)
        self.usualDay = usualDay
        self.usualTime = usualTime
    }

    /// The cadences GroundWork's client form offers, with its own labels, so the two apps
    /// present the same four choices and agree on what each means.
    public static let offered: [(label: String, days: Int)] = [
        ("Weekly", 7),
        ("Every 2 weeks", 14),
        ("Every 3 weeks", 21),
        ("Monthly (28 days)", 28)
    ]

    public var cadenceLabel: String {
        Self.offered.first { $0.days == cadenceDays }?.label ?? "Every \(cadenceDays) days"
    }

    /// "Weekly, Tuesdays at 09:30".
    public var summary: String {
        var parts = [cadenceLabel]
        if let usualDay { parts.append("\(usualDay.displayName)s") }
        if let usualTime { parts.append("at \(usualTime)") }
        return parts.joined(separator: ", ")
    }
}

/// Working out which sessions should have happened and have not been written up.
///
/// This is the whole of the integration on this side. It reads only the vault — the notes
/// already stored and the cadence in the client's metadata — so it works on a machine that
/// has never once been in contact with GroundWork.
public enum SessionPrediction {
    /// How many suggestions are worth offering. Beyond about six the list stops being a
    /// shortcut and becomes something to read.
    public static let defaultLimit = 6

    /// Guards the stepping loop against a cadence and an anchor that would otherwise walk
    /// for years — an anchor date typed as 1926, most plausibly.
    private static let maximumSteps = 400

    /// The sessions that fall between `anchor` and the end of today and have no note.
    ///
    /// Returns most recent first: the session most likely to be getting written up right
    /// now is the one that just happened.
    ///
    /// - Parameters:
    ///   - anchor: the latest session already known about. Nothing before this is predicted.
    ///   - schedule: the client's cadence, from their metadata.
    ///   - recorded: session dates that already have a note. Compared by calendar day.
    ///   - now: the horizon. Predictions stop at the end of this day.
    public static func expected(
        anchor: Date,
        schedule: SessionSchedule,
        recorded: [Date],
        now: Date = Date(),
        limit: Int = defaultLimit,
        calendar: Calendar = .current
    ) -> [Date] {
        guard limit > 0, schedule.cadenceDays > 0 else { return [] }
        guard let horizon = calendar.dateInterval(of: .day, for: now)?.end else { return [] }

        let taken = Set(recorded.map { calendar.startOfDay(for: $0) })
        var results: [Date] = []
        var cursor = anchor
        var steps = 0

        while steps < maximumSteps {
            steps += 1
            guard let stepped = calendar.date(byAdding: .day, value: schedule.cadenceDays, to: cursor) else { break }
            cursor = stepped

            let candidate = place(stepped, on: schedule, calendar: calendar)
            // The candidate can be nudged back over the anchor by day-snapping — a session
            // moved forward by two days, with the next one snapped back onto its usual day.
            // Skip it rather than suggesting a date that is already written up.
            guard candidate > anchor else { continue }
            guard candidate < horizon else { break }
            if taken.contains(calendar.startOfDay(for: candidate)) { continue }
            results.append(candidate)
        }

        return Array(results.reversed().prefix(limit))
    }

    /// The same thing, from an index and a client — the form the app actually calls.
    ///
    /// The anchor is the latest note's session, falling back to the start of the work when
    /// nothing has been written up yet. A client with neither gets no suggestions, which is
    /// correct: there is nothing to count from, and inventing a first appointment would be
    /// worse than an empty list.
    public static func expected(
        for code: ClientCode,
        in index: VaultIndex,
        now: Date = Date(),
        limit: Int = defaultLimit,
        calendar: Calendar = .current
    ) -> [Date] {
        guard let summary = index.client(code), let schedule = summary.schedule else { return [] }
        let sessions = index.currentNotes(for: code).map(\.session)
        guard let anchor = sessions.max() ?? summary.seriesStart else { return [] }

        return expected(
            anchor: anchor,
            schedule: schedule,
            recorded: sessions,
            now: now,
            limit: limit,
            calendar: calendar
        )
    }

    /// Moves a candidate onto the client's usual day and time.
    ///
    /// The day snap moves at most three days in either direction, so it can only ever
    /// correct a series back onto its own rhythm — never relocate it. Every cadence is a
    /// whole number of weeks, so after one correction the snap does nothing at all.
    static func place(_ date: Date, on schedule: SessionSchedule, calendar: Calendar) -> Date {
        var result = date

        if let usualDay = schedule.usualDay {
            let current = calendar.component(.weekday, from: result)
            var delta = usualDay.calendarWeekday - current
            if delta > 3 { delta -= 7 }
            if delta < -3 { delta += 7 }
            if delta != 0, let moved = calendar.date(byAdding: .day, value: delta, to: result) {
                result = moved
            }
        }

        if let usualTime = schedule.usualTime,
           let timed = calendar.date(
            bySettingHour: usualTime.hour,
            minute: usualTime.minute,
            second: 0,
            of: result
           ) {
            result = timed
        }
        return result
    }
}
