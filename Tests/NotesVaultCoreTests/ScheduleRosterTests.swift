import XCTest
@testable import NotesVaultCore

/// Reading GroundWork's schedule file, and working out what one sync would change.
final class ScheduleRosterTests: XCTestCase {
    private func roster(_ json: String) throws -> ScheduleRoster {
        try ScheduleRoster.parse(Data(json.utf8))
    }

    private let wellFormed = """
    {
      "app": "GroundWork",
      "kind": "schedules",
      "version": 1,
      "exportedAt": "2026-08-31T08:12:44Z",
      "clients": [
        {"code":"SM2","status":"active","cadenceDays":7,"usualDay":"tue","usualTime":"09:30","seriesStart":"2026-04-07"},
        {"code":"JB4","status":"ended","cadenceDays":14,"usualDay":"thu","usualTime":"16:00"}
      ]
    }
    """

    // MARK: - Parsing

    func testReadsAWellFormedRoster() throws {
        let parsed = try roster(wellFormed)
        XCTAssertEqual(parsed.entries.count, 2)
        XCTAssertTrue(parsed.issues.isEmpty)

        let sm2 = parsed.entries[0]
        XCTAssertEqual(sm2.code.rawValue, "SM2")
        XCTAssertEqual(sm2.status, .active)
        XCTAssertEqual(sm2.schedule?.cadenceDays, 7)
        XCTAssertEqual(sm2.schedule?.usualDay, .tue)
        XCTAssertEqual(sm2.schedule?.usualTime?.description, "09:30")
        XCTAssertNotNil(sm2.seriesStart)
        XCTAssertEqual(parsed.entries[1].status, .ended)
    }

    func testARowThatCannotBeUsedIsSkippedAndReportedRatherThanFatal() throws {
        let parsed = try roster("""
        {"app":"GroundWork","kind":"schedules","version":1,"clients":[
          {"code":"X","cadenceDays":7},
          {"code":"Sarah M","cadenceDays":7},
          {"code":"OK1","cadenceDays":7}
        ]}
        """)
        XCTAssertEqual(parsed.entries.map { $0.code.rawValue }, ["OK1"], "the good row still comes in")
        XCTAssertEqual(parsed.issues.count, 2)
        XCTAssertTrue(parsed.issues.contains { $0.location == "Sarah M" })
    }

    func testADuplicatedCodeIsReportedAndTheFirstWins() throws {
        let parsed = try roster("""
        {"app":"GroundWork","kind":"schedules","version":1,"clients":[
          {"code":"SM2","cadenceDays":7},
          {"code":"SM2","cadenceDays":28}
        ]}
        """)
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertEqual(parsed.entries[0].schedule?.cadenceDays, 7)
        XCTAssertEqual(parsed.issues.count, 1)
    }

    func testARowWithNoCadenceCarriesNoSchedule() throws {
        let parsed = try roster("""
        {"app":"GroundWork","kind":"schedules","version":1,"clients":[{"code":"SM2","status":"paused"}]}
        """)
        XCTAssertNil(parsed.entries[0].schedule)
        XCTAssertEqual(parsed.entries[0].status, .paused)
    }

    /// A full GroundWork backup holds client codes too, and would half-work if it were let
    /// through — so the file is identified by `kind`, not by looking hopeful.
    func testAGroundWorkBackupIsRefusedByName() {
        XCTAssertThrowsError(try roster(#"{"app":"GroundWork","version":1,"state":{"clients":[]}}"#)) { error in
            let message = (error as? VaultError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("not a schedule file"), message)
        }
    }

    func testSomethingThatIsNotJSONIsRefused() {
        XCTAssertThrowsError(try roster("Dear diary,"))
    }

    func testAFutureFormatIsRefusedRatherThanHalfRead() {
        XCTAssertThrowsError(try roster(#"{"kind":"schedules","version":99,"clients":[]}"#)) { error in
            XCTAssertTrue(((error as? VaultError)?.errorDescription ?? "").contains("newer version"))
        }
    }

    // MARK: - Planning

    private func plan(
        _ json: String,
        existing: [ClientMetadataEvent] = [],
        known: [String] = []
    ) throws -> RosterSyncPlan {
        var byCode: [ClientCode: ClientMetadataEvent] = [:]
        for event in existing { byCode[event.client] = event }
        return RosterSync.plan(
            roster: try roster(json),
            existing: byCode,
            knownClients: try known.map { try ClientCode($0) } + byCode.keys,
            device: "mac"
        )
    }

    func testAClientTheVaultHasNeverSeenIsCreated() throws {
        let result = try plan(wellFormed)
        XCTAssertEqual(result.created, 2)
        XCTAssertEqual(result.updated, 0)
        // The plan is sorted by client code, so JB4 comes before SM2 regardless of the
        // order they appear in the file.
        XCTAssertEqual(result.changes.map { $0.event.client.rawValue }, ["JB4", "SM2"])
        XCTAssertEqual(result.changes.first { $0.event.client.rawValue == "SM2" }?.event.schedule?.cadenceDays, 7)
    }

    /// The whole reason the plan exists. The vault is append-only: a sync that wrote every
    /// client every time would leave a file per client per press of the button.
    func testASecondSyncOfTheSameFileChangesNothing() throws {
        let first = try plan(wellFormed)
        let second = try plan(wellFormed, existing: first.changes.map(\.event))

        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(second.unchanged, 2)
    }

    func testAChangedSlotIsAnUpdateAndSaysWhatChanged() throws {
        let existing = ClientMetadataEvent(
            client: try ClientCode("SM2"),
            device: "iphone",
            status: .active,
            schedule: SessionSchedule(cadenceDays: 7, usualDay: .mon, usualTime: TimeOfDay(hour: 9, minute: 30))
        )
        let result = try plan(
            #"{"kind":"schedules","version":1,"clients":[{"code":"SM2","status":"active","cadenceDays":14,"usualDay":"tue","usualTime":"09:30"}]}"#,
            existing: [existing]
        )
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.changes[0].event.schedule?.cadenceDays, 14)
        XCTAssertEqual(result.changes[0].event.schedule?.usualDay, .tue)
        XCTAssertTrue(result.changes[0].summary.contains("Every 2 weeks"), result.changes[0].summary)
    }

    /// A metadata event is a complete snapshot and the log folds latest-wins, so anything
    /// the roster does not carry has to be copied forward or it is silently reset.
    func testEverythingTheRosterDoesNotCarryIsPreserved() throws {
        let reaches25 = Date(timeIntervalSince1970: 2_000_000_000)
        let lastContact = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = ClientMetadataEvent(
            client: try ClientCode("SM2"),
            device: "iphone",
            status: .active,
            retentionBasis: .minor(reaches25On: reaches25),
            lastContactOverride: lastContact,
            schedule: SessionSchedule(cadenceDays: 7),
            extraHeaders: ["written-by": "a future version"]
        )
        let result = try plan(
            #"{"kind":"schedules","version":1,"clients":[{"code":"SM2","status":"active","cadenceDays":28}]}"#,
            existing: [existing]
        )
        let event = try XCTUnwrap(result.changes.first?.event)

        XCTAssertEqual(event.retentionBasis, .minor(reaches25On: reaches25))
        XCTAssertEqual(event.lastContactOverride, lastContact)
        XCTAssertEqual(event.extraHeaders["written-by"], "a future version")
        XCTAssertEqual(event.schedule?.cadenceDays, 28)
    }

    func testAStatusChangeAloneIsEnoughToBeAnUpdate() throws {
        let existing = ClientMetadataEvent(
            client: try ClientCode("JB4"),
            device: "iphone",
            status: .active,
            schedule: SessionSchedule(cadenceDays: 14, usualDay: .thu, usualTime: TimeOfDay(hour: 16, minute: 0))
        )
        let result = try plan(wellFormed, existing: [existing])
        let change = try XCTUnwrap(result.changes.first { $0.event.client.rawValue == "JB4" })

        XCTAssertEqual(change.event.status, .ended)
        XCTAssertTrue(change.summary.contains("Active → Ended"), change.summary)
    }

    /// A cadence set here by hand for a client GroundWork has no sessions for must not be
    /// wiped by a sync that simply says nothing about it.
    func testARosterWithNoCadenceLeavesAnExistingScheduleAlone() throws {
        let existing = ClientMetadataEvent(
            client: try ClientCode("SM2"),
            device: "mac",
            status: .active,
            schedule: SessionSchedule(cadenceDays: 21, usualDay: .wed)
        )
        let result = try plan(
            #"{"kind":"schedules","version":1,"clients":[{"code":"SM2","status":"active"}]}"#,
            existing: [existing]
        )
        XCTAssertTrue(result.isEmpty, "nothing changed, so nothing should be written")
    }

    func testClientsMissingFromTheRosterAreListedAndLeftAlone() throws {
        let result = try plan(wellFormed, known: ["ZZ9"])
        XCTAssertEqual(result.untouched.map(\.rawValue), ["ZZ9"])
        XCTAssertFalse(result.changes.contains { $0.event.client.rawValue == "ZZ9" })
    }

    /// A day is not an instant. Reading `2026-04-07` as midnight UTC puts it in the small
    /// hours in London and on the 6th in New York; midday is on the 7th wherever it is read.
    func testADayWithNoTimeIsReadAsMidday() throws {
        let parsed = try roster(wellFormed)
        let start = try XCTUnwrap(parsed.entries[0].seriesStart)
        let parts = Calendar.gregorianUTC.dateComponents([.year, .month, .day, .hour], from: start)

        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 4)
        XCTAssertEqual(parts.day, 7)
        XCTAssertEqual(parts.hour, 12)
    }

    /// The vault is append-only, so a series start written as midnight by an older build
    /// must not read as a change now that this one writes midday. It is the same day, and
    /// the same day is not a change — otherwise one sync rewrites every client in the vault.
    func testAStartDateWrittenAtADifferentTimeOfDayIsNotAChange() throws {
        let existing = ClientMetadataEvent(
            client: try ClientCode("SM2"),
            device: "mac",
            status: .active,
            schedule: SessionSchedule(cadenceDays: 7, usualDay: .tue, usualTime: TimeOfDay(hour: 9, minute: 30)),
            seriesStart: try XCTUnwrap(VaultDate.parse("2026-04-07T00:00:00Z"))
        )
        let result = try plan(wellFormed, existing: [existing])

        XCTAssertFalse(result.changes.contains { $0.event.client.rawValue == "SM2" },
                       "same schedule, same status, same day — nothing to write")
    }

    func testSkippedRowsAreCarriedIntoThePlan() throws {
        let result = try plan(#"{"kind":"schedules","version":1,"clients":[{"code":"Sarah M","cadenceDays":7}]}"#)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.isEmpty)
    }
}
