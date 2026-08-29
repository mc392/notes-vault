import XCTest
@testable import NotesVaultCore

/// Expected dates are worked out from the rule, never copied from what the code returned.
/// A test written by pasting in the current output only ever proves the code still does
/// what it did — which is worth nothing on the one screen that tells a counsellor it is
/// safe to destroy a clinical record.
final class RetentionTests: XCTestCase {
    private let policy = RetentionPolicy.bacpDefault

    private func assess(
        status: ClientStatus,
        basis: RetentionBasis,
        lastContact: Date?,
        now: String
    ) -> RetentionAssessment {
        RetentionEngine.assess(
            client: Fixture.code("SM2"),
            status: status,
            basis: basis,
            lastContact: lastContact,
            policy: policy,
            now: Fixture.date(now)
        )
    }

    // MARK: - Adults

    func testAdultClockIsSevenYearsFromLastContact() {
        let result = assess(
            status: .ended,
            basis: .adult,
            lastContact: Fixture.date("2020-03-10T00:00:00Z"),
            now: "2026-08-29T00:00:00Z"
        )
        // 10 March 2020 + 7 years.
        XCTAssertEqual(result.dueOn, Fixture.date("2027-03-10T00:00:00Z"))
        XCTAssertEqual(result.state, .counting)
    }

    func testPastTheRetentionPeriodIsDue() {
        let result = assess(
            status: .ended,
            basis: .adult,
            lastContact: Fixture.date("2018-01-01T00:00:00Z"),
            now: "2026-08-29T00:00:00Z"
        )
        XCTAssertEqual(result.state, .due)
        XCTAssertTrue(result.needsAttention)
    }

    func testTheLeadTimeIsWhatMakesItDueSoon() {
        // Due 1 Jan 2027; 90 days earlier is 3 October 2026.
        let justInside = assess(
            status: .ended,
            basis: .adult,
            lastContact: Fixture.date("2020-01-01T00:00:00Z"),
            now: "2026-10-04T00:00:00Z"
        )
        XCTAssertEqual(justInside.state, .dueSoon)

        let justOutside = assess(
            status: .ended,
            basis: .adult,
            lastContact: Fixture.date("2020-01-01T00:00:00Z"),
            now: "2026-10-02T00:00:00Z"
        )
        XCTAssertEqual(justOutside.state, .counting)
    }

    // MARK: - Minors

    /// A 16-year-old seen in 2026 is covered by the age ceiling, which falls well after
    /// seven years from last contact.
    func testMinorIsKeptUntilTwentyFive() {
        let basis = RetentionBasis.minor(dateOfBirth: Fixture.date("2010-05-02T00:00:00Z"))
        let result = assess(
            status: .ended,
            basis: basis,
            lastContact: Fixture.date("2026-06-01T00:00:00Z"),
            now: "2026-08-29T00:00:00Z"
        )
        // Born 2 May 2010, so 25 on 2 May 2035. Seven years from last contact is only 2033.
        XCTAssertEqual(result.dueOn, Fixture.date("2035-05-02T00:00:00Z"))
    }

    /// The other direction, which a naive "minors are kept to 25" rule gets wrong: someone
    /// seen as a minor years ago is now past 25, and the seven-year rule is what still
    /// applies.
    func testMinorSeenLongAgoStillGetsTheSevenYears() {
        let basis = RetentionBasis.minor(dateOfBirth: Fixture.date("1999-05-02T00:00:00Z"))
        let result = assess(
            status: .ended,
            basis: basis,
            lastContact: Fixture.date("2023-06-01T00:00:00Z"),
            now: "2026-08-29T00:00:00Z"
        )
        // 25 on 2 May 2024, but last contact 1 June 2023 + 7 years is 1 June 2030.
        XCTAssertEqual(result.dueOn, Fixture.date("2030-06-01T00:00:00Z"))
    }

    func testTheBasisStoresNoDateOfBirth() {
        let basis = RetentionBasis.minor(dateOfBirth: Fixture.date("2010-05-02T00:00:00Z"))
        XCTAssertEqual(basis.encodedString, "minor:2035-05-02T00:00:00Z")
        XCTAssertFalse(basis.encodedString.contains("2010"))
    }

    func testBasisRoundTrips() throws {
        for basis in [RetentionBasis.adult, .minor(reaches25On: Fixture.date("2035-05-02T00:00:00Z"))] {
            XCTAssertEqual(try RetentionBasis(encoded: basis.encodedString), basis)
        }
    }

    // MARK: - When the clock does not run

    /// Paused is not ended. These clients may come back, and flagging their notes for
    /// destruction would be actively wrong.
    func testPausedNeverStartsTheClock() {
        let result = assess(
            status: .paused,
            basis: .adult,
            lastContact: Fixture.date("2010-01-01T00:00:00Z"),
            now: "2026-08-29T00:00:00Z"
        )
        XCTAssertEqual(result.state, .notCounting)
        XCTAssertFalse(result.needsAttention)
    }

    func testActiveNeverStartsTheClock() {
        let result = assess(
            status: .active,
            basis: .adult,
            lastContact: Fixture.date("2010-01-01T00:00:00Z"),
            now: "2026-08-29T00:00:00Z"
        )
        XCTAssertEqual(result.state, .notCounting)
    }

    /// A client with no logged sessions has nothing to count from and must not appear as
    /// overdue on day one.
    func testNoSessionsMeansNoClock() {
        let result = assess(status: .ended, basis: .adult, lastContact: nil, now: "2026-08-29T00:00:00Z")
        XCTAssertEqual(result.state, .notCounting)
        XCTAssertNil(result.dueOn)
    }

    // MARK: - The review list

    func testReviewPutsWhatNeedsADecisionFirst() {
        let clients = [
            ClientSummary(code: Fixture.code("AAA"), status: .active, retentionBasis: .adult,
                          firstContact: nil, lastContact: Fixture.date("2026-01-01T00:00:00Z"),
                          noteCount: 3, supersededCount: 0),
            ClientSummary(code: Fixture.code("BBB"), status: .ended, retentionBasis: .adult,
                          firstContact: nil, lastContact: Fixture.date("2010-01-01T00:00:00Z"),
                          noteCount: 9, supersededCount: 0),
            ClientSummary(code: Fixture.code("CCC"), status: .ended, retentionBasis: .adult,
                          firstContact: nil, lastContact: Fixture.date("2025-01-01T00:00:00Z"),
                          noteCount: 4, supersededCount: 0)
        ]

        let review = RetentionEngine.review(clients: clients, policy: policy, now: Fixture.date("2026-08-29T00:00:00Z"))
        XCTAssertEqual(review.first?.client.rawValue, "BBB")
        XCTAssertEqual(review.filter(\.needsAttention).count, 1)
    }
}
