import XCTest
import LocalAuthentication
@testable import NotesVaultCrypto

/// A real check needs a face to show a simulator, so what is tested is the decision made
/// about each way one can end — which is the part that decides whether a wrong face costs
/// somebody the session or costs them nothing.
final class DeviceCheckTests: XCTestCase {
    func testCancellingIsNotAFailure() {
        XCTAssertEqual(DeviceCheck.outcome(for: .userCancel), .cancelled)
        XCTAssertEqual(DeviceCheck.outcome(for: .appCancel), .cancelled)
        XCTAssertEqual(DeviceCheck.outcome(for: .systemCancel), .cancelled)
    }

    func testAWrongFaceOrPasscodeIsAFailure() {
        XCTAssertEqual(DeviceCheck.outcome(for: .authenticationFailed), .failed)
        XCTAssertEqual(DeviceCheck.outcome(for: .biometryLockout), .failed)
    }

    /// A fallback the counsellor then abandoned still means the check did not pass. It is
    /// the default branch, and the default branch must not be generous.
    func testAnUnexplainedEndingIsAFailure() {
        XCTAssertEqual(DeviceCheck.outcome(for: .invalidContext), .failed)
        XCTAssertEqual(DeviceCheck.outcome(for: .notInteractive), .failed)
    }

    func testNothingToAskWithIsUnavailableRatherThanFailed() {
        XCTAssertEqual(DeviceCheck.outcome(for: .biometryNotAvailable), .unavailable)
        XCTAssertEqual(DeviceCheck.outcome(for: .biometryNotEnrolled), .unavailable)
        XCTAssertEqual(DeviceCheck.outcome(for: .passcodeNotSet), .unavailable)
    }

    func testEvaluationWithNoErrorAtAllStillCountsAsFailed() {
        XCTAssertEqual(DeviceCheck.outcome(forEvaluation: nil), .failed)
    }
}
