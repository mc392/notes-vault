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
    /// The appointment time. When absent, predictions keep the last written-up session's own
    /// time — or, when there is no such session, carry no time at all rather than invent one.
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

/// One session a client should have had, and has no note for.
///
/// It carries a flag as well as a date because a prediction's *time* is sometimes a real
/// fact and sometimes nothing at all. The slot GroundWork sent, or the time of the session
/// the walk last passed, is real. A client whose GroundWork record has no appointment time,
/// with no notes yet to borrow one from, has a date and no time — and showing the midnight
/// that falls out of the arithmetic (which reads as 01:00 through a British summer) states
/// an appointment time nobody ever set.
public struct PredictedSession: Hashable, Sendable, Identifiable {
    public var id: Date { date }

    /// The session. When `timeIsKnown` is false this is midday — a defensible thing to open
    /// the note editor on, and far enough from either end of the day that it stays on the
    /// right date in every time zone.
    public let date: Date

    /// Whether `date`'s time of day means anything. When false, show the date alone.
    public let timeIsKnown: Bool

    public init(date: Date, timeIsKnown: Bool) {
        self.date = date
        self.timeIsKnown = timeIsKnown
    }
}

/// Working out which sessions should have happened and have not been written up.
///
/// This is the whole of the integration on this side. It reads only the vault — the notes
/// already stored and the cadence in the client's metadata — so it works on a machine that
/// has never once been in contact with GroundWork.
public enum SessionPrediction {
    /// No cap. Every session without a note is work still outstanding, and a list that
    /// quietly stopped at six was hiding some of it — a counsellor coming back from a
    /// fortnight away needs to see the fortnight, not the tail of it.
    public static let defaultLimit = Int.max

    /// How far back a prediction will ever reach: two years before today.
    ///
    /// Not a tidiness rule — it is what stops a series start typed as 1926, or a client
    /// seen for a decade, from turning into hundreds of rows nobody will ever write up. Two
    /// years is well past the point where a session is going to be written up from memory,
    /// and well short of anything a counsellor would call recent.
    public static let maximumLookbackDays = 730

    /// Guards the stepping loop. With the lookback above, a weekly client needs about a
    /// hundred steps and a daily one about seven hundred, so this only ever bites on a
    /// cadence the app itself cannot produce.
    private static let maximumSteps = 400

    /// The sessions that fall between `anchor` and the end of today and have no note.
    ///
    /// Returns most recent first: the session most likely to be getting written up right
    /// now is the one that just happened.
    ///
    /// The walk **re-anchors onto every session it meets that does have a note**, which is
    /// what keeps a series that slipped by a day or two from drifting, while still leaving
    /// the gaps behind it on the list. Anchoring on the latest note instead — which is what
    /// this did until the walk was rewritten — made every other outstanding session vanish
    /// the moment one of them was written up, because the walk then started after them.
    ///
    /// - Parameters:
    ///   - anchor: the earliest session known about. Nothing before this is predicted.
    ///   - schedule: the client's cadence, from their metadata.
    ///   - recorded: session dates that already have a note. Compared by calendar day.
    ///   - now: the horizon. Predictions stop at the end of this day.
    ///   - anchorCarriesATime: whether the anchor's time of day is a real appointment time.
    ///     False for a `series-start`, which GroundWork sends as a day with no time — see
    ///     `PredictedSession.timeIsKnown`.
    public static func expected(
        anchor: Date,
        schedule: SessionSchedule,
        recorded: [Date],
        now: Date = Date(),
        limit: Int = defaultLimit,
        anchorCarriesATime: Bool = true,
        calendar: Calendar = .current
    ) -> [PredictedSession] {
        guard limit > 0, schedule.cadenceDays > 0 else { return [] }
        guard let horizon = calendar.dateInterval(of: .day, for: now)?.end else { return [] }
        let floor = calendar.date(byAdding: .day, value: -maximumLookbackDays, to: now) ?? anchor

        // Sessions that already have a note, earliest first, and which of them the walk has
        // matched to a slot. Each is claimed once: two notes cannot write up one session.
        let written = recorded.sorted()
        var claimed = Set<Int>()
        // How far from a predicted slot a note can sit and still be that session: half a
        // cadence, so every note belongs to exactly one slot — the nearest. A note written
        // at 09:35 for a 09:30 appointment is obviously that appointment, and so is one for
        // a Tuesday session that was moved to the Wednesday.
        let tolerance = Double(schedule.cadenceDays) * 43_200

        var cursor = anchor
        var cursorCarriesATime = anchorCarriesATime

        // A series that began before the lookback window is walked from inside the window
        // rather than from its first appointment: the same answer, without the years of
        // stepping it would otherwise take to get here.
        if cursor < floor {
            if let latest = recorded.filter({ $0 <= floor }).max(), latest > cursor {
                cursor = latest
                cursorCarriesATime = true
            }
            if let behind = calendar.dateComponents([.day], from: cursor, to: floor).day,
               behind > schedule.cadenceDays {
                let jumps = behind / schedule.cadenceDays
                cursor = calendar.date(byAdding: .day, value: jumps * schedule.cadenceDays, to: cursor) ?? cursor
            }
        }

        var results: [PredictedSession] = []
        var offered: Set<Date> = []
        var steps = 0

        while steps < maximumSteps {
            steps += 1
            guard let stepped = calendar.date(byAdding: .day, value: schedule.cadenceDays, to: cursor) else { break }

            let candidate = place(stepped, on: schedule, carryingATime: cursorCarriesATime, calendar: calendar)
            guard candidate.date < horizon else { break }
            cursor = stepped

            // The candidate can be nudged back over the anchor by day-snapping — a session
            // moved forward by two days, with the next one snapped back onto its usual day.
            // Skip it rather than suggesting a date that is already written up.
            guard candidate.date > anchor else { continue }

            if let match = nearestUnclaimed(to: candidate.date, in: written, claimed: claimed, within: tolerance) {
                // This one has a note. Claim it, and step on from where the session actually
                // was rather than from where the arithmetic said it would be — which is what
                // keeps a series that slipped a day from drifting a day further every time.
                claimed.insert(match)
                cursor = written[match]
                cursorCarriesATime = true
                continue
            }

            guard candidate.date >= floor else { continue }
            // A cadence shorter than the snap distance can land twice on the same day.
            guard offered.insert(calendar.startOfDay(for: candidate.date)).inserted else { continue }
            results.append(candidate)
        }

        return Array(results.reversed().prefix(limit))
    }

    /// The same thing, from an index and a client — the form the app actually calls.
    ///
    /// The anchor is the client's **first** note, falling back to the start of the work when
    /// nothing has been written up yet. Everything from there to today that has no note is
    /// outstanding. A client with neither gets no suggestions, which is correct: there is
    /// nothing to count from, and inventing a first appointment would be worse than an
    /// empty list.
    ///
    /// Starting at the first note rather than the series start is deliberate. Sessions from
    /// before this app was keeping the record are not work outstanding — they are work that
    /// was written up somewhere else — and listing them would bury the ones that are.
    public static func expected(
        for code: ClientCode,
        in index: VaultIndex,
        now: Date = Date(),
        limit: Int = defaultLimit,
        calendar: Calendar = .current
    ) -> [PredictedSession] {
        guard let summary = index.client(code) else { return [] }
        return expected(
            for: summary,
            sessions: index.currentNotes(for: code).map(\.session),
            now: now,
            limit: limit,
            calendar: calendar
        )
    }

    /// Every client's outstanding sessions, from one pass over the index.
    ///
    /// `expected(for:in:)` walks the whole note list to pick out one client's notes, so the
    /// client list — which needs a count per row — was re-scanning the entire vault once per
    /// client. This groups the notes once and hands each client their own.
    public static func expectedForEveryClient(
        in index: VaultIndex,
        now: Date = Date(),
        limit: Int = defaultLimit,
        calendar: Calendar = .current
    ) -> [ClientCode: [PredictedSession]] {
        let superseded = index.supersededIDs
        let byClient = Dictionary(grouping: index.notes.filter { !superseded.contains($0.id) }, by: \.client)

        var result: [ClientCode: [PredictedSession]] = [:]
        for summary in index.clients where summary.schedule != nil {
            let sessions = (byClient[summary.code] ?? []).map(\.session)
            let predicted = expected(for: summary, sessions: sessions, now: now, limit: limit, calendar: calendar)
            if !predicted.isEmpty { result[summary.code] = predicted }
        }
        return result
    }

    /// The anchoring rule, in one place, so the per-client and whole-vault forms cannot
    /// come to different answers.
    private static func expected(
        for summary: ClientSummary,
        sessions: [Date],
        now: Date,
        limit: Int,
        calendar: Calendar
    ) -> [PredictedSession] {
        guard let schedule = summary.schedule else { return [] }

        let anchor: Date
        let anchorCarriesATime: Bool
        if let first = sessions.min() {
            anchor = first
            anchorCarriesATime = true
        } else if let start = summary.seriesStart {
            anchor = start
            // `series-start` is a day, not an appointment. Its time of day is an artefact of
            // however it was written down.
            anchorCarriesATime = false
        } else {
            return []
        }

        return expected(
            anchor: anchor,
            schedule: schedule,
            recorded: sessions,
            now: now,
            limit: limit,
            anchorCarriesATime: anchorCarriesATime,
            calendar: calendar
        )
    }

    /// The index of the closest session with a note that no slot has claimed yet, if one is
    /// close enough to be this slot at all.
    private static func nearestUnclaimed(
        to candidate: Date,
        in written: [Date],
        claimed: Set<Int>,
        within tolerance: Double
    ) -> Int? {
        var best: Int?
        var bestDistance = tolerance

        for index in written.indices where !claimed.contains(index) {
            let distance = abs(written[index].timeIntervalSince(candidate))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Moves a candidate onto the client's usual day and time.
    ///
    /// The day snap moves at most three days in either direction, so it can only ever
    /// correct a series back onto its own rhythm — never relocate it. Every cadence is a
    /// whole number of weeks, so after one correction the snap does nothing at all.
    static func place(
        _ date: Date,
        on schedule: SessionSchedule,
        carryingATime: Bool,
        calendar: Calendar
    ) -> PredictedSession {
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

        if let usualTime = schedule.usualTime {
            if let timed = calendar.date(
                bySettingHour: usualTime.hour,
                minute: usualTime.minute,
                second: 0,
                of: result
            ) {
                result = timed
            }
            return PredictedSession(date: result, timeIsKnown: true)
        }

        // No slot from GroundWork. The time carried down from the last session that had one
        // is a real time; anything else is arithmetic, and is shown as a date alone.
        if carryingATime {
            return PredictedSession(date: result, timeIsKnown: true)
        }
        let midday = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: result) ?? result
        return PredictedSession(date: midday, timeIsKnown: false)
    }
}
