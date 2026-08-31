import XCTest
@testable import NotesVaultCore

/// The prediction algorithm and the schedule headers.
///
/// The dates here are checked against the spec in `docs/schedule-sync.md` rather than
/// against whatever the code happens to do — this is the half of the integration that has
/// to agree with a second implementation in another language, and a test that only asserts
/// the current behaviour would let the two drift apart without failing.
final class SessionScheduleTests: XCTestCase {
    /// UTC throughout, so a test run in July and a test run in January agree.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = text.count > 10 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.date(from: text)!
    }

    private func expect(
        anchor: String,
        schedule: SessionSchedule,
        recorded: [String] = [],
        now: String,
        limit: Int = SessionPrediction.defaultLimit
    ) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        return SessionPrediction.expected(
            anchor: date(anchor),
            schedule: schedule,
            recorded: recorded.map(date),
            now: date(now),
            limit: limit,
            calendar: calendar
        ).map(formatter.string(from:))
    }

    // MARK: - Stepping

    func testWeeklyFillsInTheMissedWeeksMostRecentFirst() {
        // Last note 4 August, today 25 August: three Tuesdays have gone by.
        let dates = expect(
            anchor: "2026-08-04 09:30",
            schedule: SessionSchedule(cadenceDays: 7, usualDay: .tue, usualTime: TimeOfDay(hour: 9, minute: 30)),
            now: "2026-08-25 14:00"
        )
        XCTAssertEqual(dates, ["2026-08-25 09:30", "2026-08-18 09:30", "2026-08-11 09:30"])
    }

    func testTodaysSessionIsOfferedEvenBeforeItsUsualTime() {
        // Written up at lunchtime, for a session that morning — and equally, a counsellor
        // who writes up in advance of the slot should not be told there is nothing to do.
        let dates = expect(
            anchor: "2026-08-18 09:30",
            schedule: SessionSchedule(cadenceDays: 7, usualDay: .tue, usualTime: TimeOfDay(hour: 9, minute: 30)),
            now: "2026-08-25 07:00"
        )
        XCTAssertEqual(dates, ["2026-08-25 09:30"])
    }

    func testNothingIsSuggestedBeyondToday() {
        let dates = expect(
            anchor: "2026-08-18 09:30",
            schedule: SessionSchedule(cadenceDays: 7, usualDay: .tue),
            now: "2026-08-20 12:00"
        )
        XCTAssertEqual(dates, [], "a session that has not happened yet cannot be written up")
    }

    func testFortnightlyAndThreeWeekly() {
        XCTAssertEqual(
            expect(
                anchor: "2026-06-02 10:00",
                schedule: SessionSchedule(cadenceDays: 14, usualDay: .tue, usualTime: TimeOfDay(hour: 10, minute: 0)),
                now: "2026-07-01 12:00"
            ),
            ["2026-06-30 10:00", "2026-06-16 10:00"]
        )
        XCTAssertEqual(
            expect(
                anchor: "2026-06-02 10:00",
                schedule: SessionSchedule(cadenceDays: 21, usualDay: .tue, usualTime: TimeOfDay(hour: 10, minute: 0)),
                now: "2026-07-01 12:00"
            ),
            ["2026-06-23 10:00"]
        )
    }

    /// The single most important assertion in this file. GroundWork's `freqDays()` maps
    /// "Monthly" to a flat 28 days; a calendar month here would put the two apps three days
    /// apart by the fourth session and neither would look wrong on its own.
    func testMonthlyIsTwentyEightDaysNotACalendarMonth() {
        let dates = expect(
            anchor: "2026-01-06 10:00",
            schedule: SessionSchedule(cadenceDays: 28, usualDay: .tue, usualTime: TimeOfDay(hour: 10, minute: 0)),
            now: "2026-04-30 12:00"
        )
        XCTAssertEqual(dates, [
            "2026-04-28 10:00",
            "2026-03-31 10:00",
            "2026-03-03 10:00",
            "2026-02-03 10:00"
        ])
        XCTAssertFalse(dates.contains("2026-04-06 10:00"), "28-day stepping never lands on the same date each month")
    }

    // MARK: - Snapping

    func testASessionMovedToAnotherDaySnapsBackToTheUsualOne() {
        // The 6th was a Thursday, moved from the usual Tuesday. The series should return to
        // Tuesdays rather than being dragged onto Thursdays for good.
        let dates = expect(
            anchor: "2026-08-06 09:30",
            schedule: SessionSchedule(cadenceDays: 7, usualDay: .tue, usualTime: TimeOfDay(hour: 9, minute: 30)),
            now: "2026-08-19 12:00"
        )
        XCTAssertEqual(dates, ["2026-08-18 09:30", "2026-08-11 09:30"])
    }

    func testSnappingGoesToTheNearestUsualDayAndSoSkipsAnImplausiblyShortGap() {
        // Anchor on Friday the 7th for a client usually seen on Mondays. Stepping a week
        // lands on Friday the 14th, whose nearest Monday is the 17th — three days forward
        // rather than four back. So Monday the 10th is not offered, and it should not be:
        // three days after the last session is not a weekly client's next appointment.
        //
        // This is the whole reason the snap is "nearest, at most three days" rather than
        // "the next usual day after the anchor", which would suggest the 10th every time a
        // session ran late in its week.
        let dates = expect(
            anchor: "2026-08-07 15:00",
            schedule: SessionSchedule(cadenceDays: 7, usualDay: .mon, usualTime: TimeOfDay(hour: 15, minute: 0)),
            now: "2026-08-24 12:00"
        )
        XCTAssertEqual(dates, ["2026-08-24 15:00", "2026-08-17 15:00"])
    }

    /// Three days forward is the outer edge of the snap: it is kept, not pulled back a week.
    /// GroundWork asserts the same case in `scripts/check-schedule-parity.mjs`.
    func testAThreeDayForwardSnapIsKept() {
        // Anchor Monday the 3rd, usual day Thursday. Stepping a week lands on Monday the
        // 10th, three days short of Thursday the 13th — which is the answer.
        let dates = expect(
            anchor: "2026-08-03 09:00",
            schedule: SessionSchedule(cadenceDays: 7, usualDay: .thu, usualTime: TimeOfDay(hour: 9, minute: 0)),
            now: "2026-08-14 12:00"
        )
        XCTAssertEqual(dates, ["2026-08-13 09:00"])
    }

    func testWithoutAUsualDayTheAnchorsOwnDayAndTimeAreKept() {
        let dates = expect(
            anchor: "2026-08-06 16:45",
            schedule: SessionSchedule(cadenceDays: 7),
            now: "2026-08-21 12:00"
        )
        XCTAssertEqual(dates, ["2026-08-20 16:45", "2026-08-13 16:45"])
    }

    // MARK: - Excluding what is already written up

    func testASessionWithANoteIsNotSuggested() {
        let dates = expect(
            anchor: "2026-08-04 09:30",
            schedule: SessionSchedule(cadenceDays: 7, usualDay: .tue, usualTime: TimeOfDay(hour: 9, minute: 30)),
            recorded: ["2026-08-18 09:30"],
            now: "2026-08-25 14:00"
        )
        XCTAssertEqual(dates, ["2026-08-25 09:30", "2026-08-11 09:30"])
    }

    func testANoteFiledAtASlightlyDifferentTimeStillCountsAsThatSession() {
        // 09:35 against a 09:30 slot is the same appointment. Matching on the instant
        // rather than the day would suggest it again the moment anyone typed a real time.
        let dates = expect(
            anchor: "2026-08-04 09:30",
            schedule: SessionSchedule(cadenceDays: 7, usualDay: .tue, usualTime: TimeOfDay(hour: 9, minute: 30)),
            recorded: ["2026-08-11 09:35", "2026-08-18 08:00"],
            now: "2026-08-25 14:00"
        )
        XCTAssertEqual(dates, ["2026-08-25 09:30"])
    }

    // MARK: - Limits and degenerate input

    func testTheListIsCapped() {
        let dates = expect(
            anchor: "2025-01-07 09:00",
            schedule: SessionSchedule(cadenceDays: 7, usualDay: .tue, usualTime: TimeOfDay(hour: 9, minute: 0)),
            now: "2026-08-25 12:00",
            limit: 6
        )
        XCTAssertEqual(dates.count, 6)
        XCTAssertEqual(dates.first, "2026-08-25 09:00", "the most recent outstanding session comes first")
    }

    func testAnAnchorInTheFutureProducesNothing() {
        XCTAssertEqual(
            expect(
                anchor: "2027-01-05 09:00",
                schedule: SessionSchedule(cadenceDays: 7, usualDay: .tue),
                now: "2026-08-25 12:00"
            ),
            []
        )
    }

    func testAVeryOldAnchorTerminates() {
        // 1926 rather than 2026 is the plausible typo, and it must not walk forever.
        let dates = expect(
            anchor: "1926-01-05 09:00",
            schedule: SessionSchedule(cadenceDays: 7, usualDay: .tue, usualTime: TimeOfDay(hour: 9, minute: 0)),
            now: "2026-08-25 12:00"
        )
        XCTAssertEqual(dates.count, 6)
    }

    func testCadenceIsNeverZero() {
        XCTAssertEqual(SessionSchedule(cadenceDays: 0).cadenceDays, 1)
        XCTAssertEqual(SessionSchedule(cadenceDays: -7).cadenceDays, 1)
    }

    // MARK: - From the index

    func testPredictionFromTheIndexUsesTheLatestNoteAsTheAnchor() throws {
        let code = try ClientCode("SM2")
        let schedule = SessionSchedule(cadenceDays: 7, usualDay: .tue, usualTime: TimeOfDay(hour: 9, minute: 30))
        let notes = ["2026-08-04 09:30", "2026-07-28 09:30"].map { text in
            (
                note: NoteRecord(client: code, session: date(text), device: "mac", body: "x"),
                filename: "\(text).note"
            )
        }
        let index = VaultIndex.build(
            notes: notes,
            clientEvents: [code: ClientMetadataEvent(client: code, device: "mac", status: .active, schedule: schedule)]
        )

        let dates = SessionPrediction.expected(for: code, in: index, now: date("2026-08-18 12:00"), calendar: calendar)
        XCTAssertEqual(dates.count, 2, "11 and 18 August are outstanding; 28 July and 4 August are written up")
    }

    func testAClientWithNoNotesFallsBackToTheStartOfTheWork() throws {
        let code = try ClientCode("NN1")
        let index = VaultIndex.build(
            notes: [],
            clientEvents: [code: ClientMetadataEvent(
                client: code,
                device: "mac",
                status: .active,
                schedule: SessionSchedule(cadenceDays: 7, usualDay: .tue, usualTime: TimeOfDay(hour: 9, minute: 30)),
                seriesStart: date("2026-08-04")
            )]
        )
        let dates = SessionPrediction.expected(for: code, in: index, now: date("2026-08-18 12:00"), calendar: calendar)
        XCTAssertEqual(dates.count, 2)
    }

    func testAClientWithNoScheduleGetsNoSuggestions() throws {
        let code = try ClientCode("NS1")
        let index = VaultIndex.build(
            notes: [(NoteRecord(client: code, session: date("2026-08-04 09:30"), device: "mac", body: "x"), "a.note")],
            clientEvents: [:]
        )
        XCTAssertEqual(
            SessionPrediction.expected(for: code, in: index, now: date("2026-09-01 12:00"), calendar: calendar),
            [],
            "no cadence means nothing to predict from — an empty list, not a guess"
        )
    }

    // MARK: - The stored headers

    func testScheduleSurvivesARoundTripThroughTheFileFormat() throws {
        let event = ClientMetadataEvent(
            client: try ClientCode("SM2"),
            device: "mac",
            status: .active,
            schedule: SessionSchedule(cadenceDays: 14, usualDay: .thu, usualTime: TimeOfDay(hour: 16, minute: 5)),
            seriesStart: date("2026-04-07")
        )
        let parsed = try ClientMetadataEvent.parse(event.serialised())

        XCTAssertEqual(parsed.schedule, event.schedule)
        XCTAssertEqual(parsed.seriesStart, event.seriesStart)
        XCTAssertTrue(String(decoding: event.serialised(), as: UTF8.self).contains("usual-day: thu"))
        XCTAssertTrue(String(decoding: event.serialised(), as: UTF8.self).contains("usual-time: 16:05"))
    }

    func testTheNewHeadersAreNotLeftInExtraHeaders() throws {
        let event = ClientMetadataEvent(
            client: try ClientCode("SM2"),
            device: "mac",
            status: .active,
            schedule: SessionSchedule(cadenceDays: 7)
        )
        let parsed = try ClientMetadataEvent.parse(event.serialised())
        XCTAssertTrue(parsed.extraHeaders.isEmpty, "known headers must not be duplicated into extraHeaders and written twice")
    }

    func testAnEventWrittenByTheOlderBuildHasNoScheduleAndStillParses() throws {
        let text = """
        notesvault-client/1
        id: \(NoteID().rawValue)
        client: SM2
        written: 2026-08-01T09:00:00Z
        device: mac
        status: active
        retention: adult

        """
        let parsed = try ClientMetadataEvent.parse(Data(text.utf8))
        XCTAssertNil(parsed.schedule)
        XCTAssertNil(parsed.seriesStart)
    }

    func testAnUnreadableCadenceDropsTheWholeScheduleRatherThanGuessing() throws {
        let text = """
        notesvault-client/1
        id: \(NoteID().rawValue)
        client: SM2
        written: 2026-08-01T09:00:00Z
        device: mac
        status: active
        retention: adult
        cadence-days: soon
        usual-day: tue

        """
        let parsed = try ClientMetadataEvent.parse(Data(text.utf8))
        XCTAssertNil(parsed.schedule, "a wrong cadence would offer confident wrong dates; none offers nothing")
    }

    func testTimeOfDayRejectsAnythingItWasNotWritten() {
        XCTAssertEqual(TimeOfDay("09:30")?.description, "09:30")
        XCTAssertEqual(TimeOfDay("9:5")?.description, "09:05")
        XCTAssertNil(TimeOfDay("9.30"))
        XCTAssertNil(TimeOfDay("9am"))
        XCTAssertNil(TimeOfDay("25:00"))
        XCTAssertNil(TimeOfDay(""))
    }

    func testWeekdayNumbersMatchCalendarsConvention() {
        XCTAssertEqual(Weekday.sun.calendarWeekday, 1)
        XCTAssertEqual(Weekday.sat.calendarWeekday, 7)
        for day in Weekday.allCases {
            XCTAssertEqual(Weekday(calendarWeekday: day.calendarWeekday), day)
        }
    }
}
