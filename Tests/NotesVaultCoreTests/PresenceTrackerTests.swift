import XCTest
@testable import NotesVaultCore

/// The lock and shield rules, run without a device. Each test is one of the ways the app
/// has actually gone wrong, or one of the promises it makes about leaving and coming back.
final class PresenceTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Leaving

    /// The app switcher photographs the app on its way out, so the shield has to be up
    /// before it goes rather than after it comes back.
    func testLeavingRaisesTheShieldAndStartsTheClock() {
        var tracker = PresenceTracker()
        tracker.leaveForeground(reallyAway: true, at: start)
        XCTAssertTrue(tracker.isShielded)
        XCTAssertEqual(tracker.awaySince, start)
    }

    /// Inactive is not away: a notification banner pulled down, or Control Centre, shields
    /// the app but does not start the clock that decides whether to ask again.
    func testInactiveShieldsWithoutCountingAsAway() {
        var tracker = PresenceTracker()
        tracker.leaveForeground(reallyAway: false, at: start)
        XCTAssertTrue(tracker.isShielded)
        XCTAssertNil(tracker.awaySince)
    }

    /// Our own Face ID prompt makes the app inactive. Shielding for it is how the app ended
    /// up showing the launch screen at somebody who never left.
    func testOurOwnPromptDoesNotShieldTheApp() {
        var tracker = PresenceTracker()
        tracker.beginCheck()
        tracker.leaveForeground(reallyAway: false, at: start)
        XCTAssertFalse(tracker.isShielded)
    }

    /// Swiping away in the middle of a prompt still shields, but does not start a second
    /// clock on top of the check that is already running.
    func testReallyLeavingDuringAPromptShieldsButDoesNotStartTheClock() {
        var tracker = PresenceTracker()
        tracker.beginCheck()
        tracker.leaveForeground(reallyAway: true, at: start)
        XCTAssertTrue(tracker.isShielded)
        XCTAssertNil(tracker.awaySince)
    }

    /// Two backgroundings in a row keep the first time: the time away is measured from when
    /// the counsellor actually left.
    func testTheClockStartsAtTheFirstDeparture() {
        var tracker = PresenceTracker()
        tracker.leaveForeground(reallyAway: true, at: start)
        tracker.leaveForeground(reallyAway: true, at: start.addingTimeInterval(100))
        XCTAssertEqual(tracker.awaySince, start)
    }

    // MARK: - Coming back

    func testComingBackInsideTheGraceLowersTheShieldAndAsksNothing() {
        var tracker = PresenceTracker()
        tracker.leaveForeground(reallyAway: true, at: start)
        let action = tracker.becameActive(
            at: start.addingTimeInterval(30),
            isUnlocked: true,
            policy: LockPolicy(reopenGrace: 60)
        )
        XCTAssertEqual(action, .nothing)
        XCTAssertFalse(tracker.isShielded)
        XCTAssertNil(tracker.awaySince)
    }

    /// A check on the way back in keeps the shield up until the check has finished, and
    /// does not let a check from before the app went away stand for it.
    func testComingBackPastTheGraceAsksWithTheShieldStillUp() {
        var tracker = PresenceTracker()
        tracker.recordCheckPassed(at: start)
        tracker.leaveForeground(reallyAway: true, at: start)
        let action = tracker.becameActive(at: start.addingTimeInterval(5), isUnlocked: true, policy: .default)
        XCTAssertEqual(action, .confirmPresence)
        XCTAssertTrue(tracker.isShielded)
        XCTAssertTrue(tracker.checkInFlight)
        XCTAssertNil(tracker.lastCheckPassed)
    }

    /// The check's own ending takes the shield down, whichever of "the scene became active"
    /// and "the check answered" arrives first. This is the stuck launch screen.
    func testEndingTheResumeCheckLowersTheShield() {
        var tracker = PresenceTracker()
        tracker.leaveForeground(reallyAway: true, at: start)
        _ = tracker.becameActive(at: start.addingTimeInterval(5), isUnlocked: true, policy: .default)

        // The scene turns active again as the prompt closes, before the answer lands.
        XCTAssertEqual(tracker.becameActive(at: start.addingTimeInterval(6), isUnlocked: true, policy: .default), .nothing)
        XCTAssertTrue(tracker.isShielded)

        tracker.endCheck()
        XCTAssertFalse(tracker.isShielded)
        XCTAssertFalse(tracker.checkInFlight)
    }

    func testALongAbsenceLocks() {
        var tracker = PresenceTracker()
        tracker.leaveForeground(reallyAway: true, at: start)
        let action = tracker.becameActive(
            at: start.addingTimeInterval(LockPolicy.keyHeldWhileAway),
            isUnlocked: true,
            policy: .default
        )
        XCTAssertEqual(action, .lock)
    }

    /// Already locked: the unlock screen is the check, so there is nothing to pay except
    /// the shield, and the biometric unlock is started for them.
    func testComingBackToALockedAppOffersTheBiometricUnlock() {
        var tracker = PresenceTracker()
        tracker.leaveForeground(reallyAway: true, at: start)
        let action = tracker.becameActive(at: start.addingTimeInterval(5), isUnlocked: false, policy: .default)
        XCTAssertEqual(action, .offerBiometricUnlock)
        XCTAssertFalse(tracker.isShielded)
    }

    /// A missed scene-phase edge must not leave the shield up for good over an app that is
    /// running perfectly behind it. Being active with nothing owed is enough.
    func testBeingActiveWithNothingOwedAlwaysLowersTheShield() {
        var tracker = PresenceTracker()
        tracker.leaveForeground(reallyAway: false, at: start)
        XCTAssertEqual(tracker.becameActive(at: start, isUnlocked: true, policy: .default), .nothing)
        XCTAssertFalse(tracker.isShielded)
    }

    // MARK: - Checks inside the app

    func testACheckStandsForAMinute() {
        var tracker = PresenceTracker()
        XCTAssertFalse(tracker.checkStands(now: start))
        tracker.recordCheckPassed(at: start)
        XCTAssertTrue(tracker.checkStands(now: start.addingTimeInterval(30)))
        XCTAssertFalse(tracker.checkStands(now: start.addingTimeInterval(61)))
    }

    func testLockingForgetsThePassedCheck() {
        var tracker = PresenceTracker()
        tracker.recordCheckPassed(at: start)
        tracker.forgetCheck()
        XCTAssertFalse(tracker.checkStands(now: start))
    }

    /// A check inside the app while it is genuinely away (swiped away mid-prompt) must not
    /// take the shield down: that is `becameActive`'s job once the time away is paid.
    func testEndingACheckWhileAwayLeavesTheShieldUp() {
        var tracker = PresenceTracker()
        tracker.leaveForeground(reallyAway: true, at: start)
        tracker.beginCheck()
        tracker.endCheck()
        XCTAssertTrue(tracker.isShielded)
    }
}
