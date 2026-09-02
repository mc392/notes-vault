import XCTest
@testable import NotesVaultCore

final class LockPolicyTests: XCTestCase {
    /// The default is the whole point of the change: leaving the app and coming back is a
    /// new arrival, not a continuation.
    func testEveryReopenAsksUnlessAGraceIsChosen() {
        let policy = LockPolicy.default
        XCTAssertEqual(policy.reopenGrace, 0)
        XCTAssertEqual(policy.resume(afterAwayFor: 0), .needsCheck)
        XCTAssertEqual(policy.resume(afterAwayFor: 2), .needsCheck)
    }

    func testInsideTheGraceThereIsNoCheck() {
        let policy = LockPolicy(reopenGrace: 60)
        XCTAssertEqual(policy.resume(afterAwayFor: 30), .straightBackIn)
        XCTAssertEqual(policy.resume(afterAwayFor: 59.9), .straightBackIn)
        XCTAssertEqual(policy.resume(afterAwayFor: 60), .needsCheck)
    }

    /// However generous the grace period, the key is not held indefinitely: past the hard
    /// limit getting back in is a real unlock rather than a check.
    func testTheKeyIsDroppedAfterALongAbsence() {
        XCTAssertEqual(LockPolicy(reopenGrace: 0).resume(afterAwayFor: 10 * 60), .needsUnlock)
        XCTAssertEqual(LockPolicy(reopenGrace: 60).resume(afterAwayFor: 9 * 60), .needsCheck)
    }

    /// A grace period longer than the hard limit raises the limit with it — otherwise
    /// choosing "after 15 minutes" would produce a state where the app asks for nothing at
    /// 14 minutes and for a passphrase at 11.
    func testALongGraceRaisesTheHardLimitRatherThanContradictingIt() {
        let policy = LockPolicy(reopenGrace: 15 * 60)
        XCTAssertEqual(policy.hardLockAfter, 15 * 60)
        XCTAssertEqual(policy.resume(afterAwayFor: 14 * 60), .straightBackIn)
        XCTAssertEqual(policy.resume(afterAwayFor: 15 * 60), .needsUnlock)
    }

    func testACheckStandsForAMinuteAndNoLonger() {
        let now = Date()
        XCTAssertFalse(LockPolicy.checkStands(lastPassed: nil, now: now))
        XCTAssertTrue(LockPolicy.checkStands(lastPassed: now.addingTimeInterval(-30), now: now))
        XCTAssertFalse(LockPolicy.checkStands(lastPassed: now.addingTimeInterval(-61), now: now))
    }

    /// A clock that has gone backwards — a time zone change, a manual clock set — must not
    /// hand out an indefinitely valid check.
    func testACheckFromTheFutureDoesNotStand() {
        let now = Date()
        XCTAssertFalse(LockPolicy.checkStands(lastPassed: now.addingTimeInterval(30), now: now))
    }

    func testEveryChoiceHasALabel() {
        XCTAssertEqual(LockPolicy.graceChoices.map(LockPolicy.graceLabel), [
            "Straight away", "After 1 minute", "After 5 minutes", "After 15 minutes"
        ])
    }
}
