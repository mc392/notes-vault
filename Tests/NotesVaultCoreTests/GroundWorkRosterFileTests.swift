import XCTest
@testable import NotesVaultCore

/// A real file, produced by GroundWork, read the whole way through.
///
/// Every other test in this suite builds its own input, which proves this app is
/// self-consistent and proves nothing at all about the other one. This is the byte-for-byte
/// output of GroundWork's own `scheduleRoster()`, run over a practice with a weekly client, a
/// fortnightly one whose session was cancelled, a monthly one with the day and time set by
/// hand, a finished client, a paused one, and two codes this app cannot accept.
///
/// **Regenerate rather than hand-edit.** If GroundWork's writer changes, produce a new file
/// from it and paste it in — the point of this fixture is that no hand of ours shaped it.
final class GroundWorkRosterFileTests: XCTestCase {
    private let file = """
    {
      "app": "GroundWork",
      "kind": "schedules",
      "version": 1,
      "exportedAt": "2026-08-31T10:31:20.193Z",
      "note": "Client codes and appointment cadence only. No names and no clinical content.",
      "clients": [
        {
          "code": "SM2",
          "status": "active",
          "cadenceDays": 7,
          "usualDay": "tue",
          "usualTime": "09:30",
          "seriesStart": "2026-07-07"
        },
        {
          "code": "JB4",
          "status": "active",
          "cadenceDays": 14,
          "usualDay": "thu",
          "usualTime": "16:00",
          "seriesStart": "2026-06-11"
        },
        {
          "code": "KL9",
          "status": "active",
          "cadenceDays": 28,
          "usualDay": "wed",
          "usualTime": "18:00",
          "seriesStart": "2026-05-06"
        },
        {
          "code": "RT1",
          "status": "ended",
          "cadenceDays": 7,
          "usualDay": "tue",
          "usualTime": "11:00",
          "seriesStart": "2025-11-04"
        },
        {
          "code": "PP3",
          "status": "paused",
          "cadenceDays": 21,
          "usualDay": "tue",
          "usualTime": "14:00",
          "seriesStart": "2026-02-17"
        }
      ]
    }
    """

    private func parsed() throws -> ScheduleRoster {
        try ScheduleRoster.parse(Data(file.utf8))
    }

    func testGroundWorksOwnOutputIsReadWithoutIssues() throws {
        let roster = try parsed()
        XCTAssertEqual(roster.entries.count, 5)
        XCTAssertTrue(roster.issues.isEmpty, "GroundWork leaves unusable codes out of the file rather than sending them")
        XCTAssertNotNil(roster.exportedAt)
    }

    func testEveryCadenceAndSlotArrivesIntact() throws {
        let byCode = Dictionary(uniqueKeysWithValues: try parsed().entries.map { ($0.code.rawValue, $0) })

        XCTAssertEqual(byCode["SM2"]?.schedule, SessionSchedule(cadenceDays: 7, usualDay: .tue, usualTime: TimeOfDay(hour: 9, minute: 30)))
        XCTAssertEqual(byCode["KL9"]?.schedule?.cadenceDays, 28, "Monthly is 28 days on both sides")
        XCTAssertEqual(byCode["KL9"]?.schedule?.usualTime?.description, "18:00")
        XCTAssertEqual(byCode["PP3"]?.schedule?.cadenceDays, 21)
    }

    /// JB4's most recent session was a late cancellation on the Friday. GroundWork excludes
    /// missed sessions when it reads the usual slot, so the file says Thursday — and this app
    /// must not quietly turn that into something else.
    func testACancelledSessionDidNotMoveTheClientsSlot() throws {
        let jb4 = try XCTUnwrap(try parsed().entries.first { $0.code.rawValue == "JB4" })
        XCTAssertEqual(jb4.schedule?.usualDay, .thu)
        XCTAssertEqual(jb4.schedule?.cadenceDays, 14)
    }

    func testStatusesMapOntoThisAppsOwn() throws {
        let byCode = Dictionary(uniqueKeysWithValues: try parsed().entries.map { ($0.code.rawValue, $0.status) })
        XCTAssertEqual(byCode["SM2"], .active)
        XCTAssertEqual(byCode["RT1"], .ended, "GroundWork's Finished starts the retention clock here")
        XCTAssertEqual(byCode["PP3"], .paused, "Paused deliberately does not — they may come back")
    }

    /// The whole point of the exchange: a file from GroundWork, applied to an empty vault, then
    /// used to work out which sessions are outstanding — with no further contact between the
    /// two apps.
    func testTheFileTurnsIntoSuggestedDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let plan = RosterSync.plan(
            roster: try parsed(),
            existing: [:],
            knownClients: [],
            device: "mac"
        )
        XCTAssertEqual(plan.created, 5)
        XCTAssertEqual(plan.updated, 0)

        // The vault as it would be after applying that plan, holding one note for SM2 — their
        // 4 August session, already written up.
        let sm2 = try ClientCode("SM2")
        var events: [ClientCode: ClientMetadataEvent] = [:]
        for change in plan.changes { events[change.event.client] = change.event }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let written = formatter.date(from: "2026-08-04 09:30")!
        let index = VaultIndex.build(
            notes: [(NoteRecord(client: sm2, session: written, device: "mac", body: "seen"), "a.note")],
            clientEvents: events
        )

        let suggestions = SessionPrediction.expected(
            for: sm2,
            in: index,
            now: formatter.date(from: "2026-08-25 14:00")!,
            calendar: calendar
        ).map(formatter.string(from:))

        XCTAssertEqual(suggestions, ["2026-08-25 09:30", "2026-08-18 09:30", "2026-08-11 09:30"],
                       "three Tuesdays since the last note, none of them written up")
    }

    /// A client whose first note has not been written yet still gets suggestions, anchored on
    /// the series start GroundWork sent.
    func testAClientWithNoNotesYetIsAnchoredOnTheSeriesStart() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let plan = RosterSync.plan(roster: try parsed(), existing: [:], knownClients: [], device: "mac")
        var events: [ClientCode: ClientMetadataEvent] = [:]
        for change in plan.changes { events[change.event.client] = change.event }

        let index = VaultIndex.build(notes: [], clientEvents: events)
        let kl9 = try ClientCode("KL9")

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        // Series started 6 May, seen every 28 days on a Wednesday at 18:00.
        let suggestions = SessionPrediction.expected(
            for: kl9,
            in: index,
            now: formatter.date(from: "2026-07-08 12:00")!,
            calendar: calendar
        ).map(formatter.string(from:))

        XCTAssertEqual(suggestions, ["2026-07-01 18:00", "2026-06-03 18:00"])
    }
}
