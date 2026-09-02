import Foundation
import LocalAuthentication

/// "Is this still the person who unlocked it?", asked of the device rather than of the
/// vault.
///
/// Distinct from `KeychainStore.passphrase(vaultID:reason:)`, which asks the same question
/// but only as a side effect of fetching the stored passphrase — that one exists to *open*
/// a locked vault. This one is for an app that is already open: it proves presence and
/// hands back nothing, so it can guard opening a note or changing a setting without the
/// passphrase being anywhere near the code path.
///
/// `.deviceOwnerAuthentication` rather than `...WithBiometrics`, for the same reason the
/// keychain items use `.userPresence`: it falls back to the passcode, so a counsellor whose
/// face is not recognised in a dim room reaches their own records by typing six digits
/// rather than being locked out of them.
public enum DeviceCheck {
    /// What the device can ask for, so screens can name it rather than saying "biometrics".
    public enum Method: Equatable, Sendable {
        case faceID
        case touchID
        case opticID
        /// A passcode or login password, with no biometry enrolled.
        case passcode
        /// Nothing at all — no biometry, no passcode set.
        case none

        public var displayName: String {
            switch self {
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .opticID: return "Optic ID"
            #if os(macOS)
            case .passcode: return "your password"
            #else
            case .passcode: return "your passcode"
            #endif
            case .none: return "a check"
            }
        }
    }

    /// The outcome of one check.
    ///
    /// The split that matters is `cancelled` from `failed`. Declining is a normal choice —
    /// the counsellor changed their mind, or handed the phone back — and costs them the
    /// action they asked for and nothing else. A *failed* check is a wrong face or a wrong
    /// passcode, which is the thing this app exists to stop, so it costs the whole session.
    public enum Outcome: Equatable, Sendable {
        case passed
        case cancelled
        case failed
        /// This device cannot ask: no biometry enrolled and no passcode set.
        case unavailable
    }

    public static var method: Method {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return .none }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        #if !os(macOS)
        case .opticID: return .opticID
        #endif
        default: return .passcode
        }
    }

    public static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Asks, and waits for the answer.
    ///
    /// A fresh `LAContext` every time on purpose: a reused one can satisfy a later check
    /// from an earlier success, which would quietly turn "ask again" into "asked once".
    public static func confirm(reason: String) async -> Outcome {
        let context = LAContext()
        // A refusal here is always a capability answer rather than a verdict on anyone:
        // `.deviceOwnerAuthentication` can only be unevaluatable if the device has neither
        // biometry nor a passcode. Biometry that is merely locked out still evaluates,
        // falling through to the passcode.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return .unavailable
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                continuation.resume(returning: success ? .passed : outcome(forEvaluation: error))
            }
        }
    }

    // MARK: - Mapping
    //
    // Pulled out as pure functions from an error code: nothing about a real check can run
    // in `swift test` — there is no face to show a simulator — so the decision these make
    // is the part that is tested.

    static func outcome(forEvaluation error: Error?) -> Outcome {
        guard let code = (error as? LAError)?.code else { return .failed }
        return outcome(for: code)
    }

    static func outcome(for code: LAError.Code) -> Outcome {
        switch code {
        case .userCancel, .appCancel, .systemCancel:
            return .cancelled
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
            // The device has nothing to ask with. Not a failure by the person holding it,
            // and the callers treat it differently from one.
            return .unavailable
        default:
            // A wrong face, a wrong passcode, a lockout, a fallback the user then abandoned,
            // or something unexplained. All of them mean the check did not pass, and an
            // unexplained one is not a reason to be generous.
            return .failed
        }
    }
}
