import Foundation

/// The bookkeeping behind "is this still the counsellor?": when a check last passed, when
/// the app went away, whether a check is on screen, and whether the shield is up.
///
/// Pulled out of `AppModel` so the rules are testable. Every decision below used to be made
/// inline, next to a Face ID prompt that `swift test` has no face to show — so the part of
/// the app most likely to strand a counsellor behind a launch screen, or let a phone handed
/// across a table straight back in, was the part nothing could run. This type makes the
/// decisions; `AppModel` asks the device and does what it is told.
///
/// It performs no check itself and knows nothing about the vault. A decision that needs
/// one — `becameActive` returning `.confirmPresence` — is handed back to the caller, which
/// runs the check and reports the answer through `endCheck` and `recordCheckPassed`.
public struct PresenceTracker: Equatable, Sendable {
    /// Whether the launch screen is covering the app.
    ///
    /// Raised the moment the app leaves the foreground — so the card in the app switcher is
    /// the launch screen and not a client's notes — and kept up while a resume check runs,
    /// so nothing is on screen until the check has passed.
    public private(set) var isShielded = false
    /// When the last check passed. Nil while locked, and cleared by every lock, so a check
    /// can never outlive the session it was taken in.
    public private(set) var lastCheckPassed: Date?
    /// When the app left the foreground. Only set for a real backgrounding — a system
    /// prompt makes the app inactive without it having gone anywhere.
    public private(set) var awaySince: Date?
    /// True while a check is on screen, so the app going inactive *because of that check*
    /// is not mistaken for the counsellor leaving.
    public private(set) var checkInFlight = false

    public init() {}

    /// What coming back to the app requires of the caller.
    public enum ResumeAction: Equatable, Sendable {
        /// Nothing: the shield is already down, or a check in flight will take it down.
        case nothing
        /// The vault was already locked. The shield is down; start the biometric unlock
        /// rather than making them reach for a button they were always going to press.
        case offerBiometricUnlock
        /// A check is now in flight and the shield stays up. Run it, then call `endCheck`
        /// and act on the outcome.
        case confirmPresence
        /// Away too long: drop the key, lower the shield, then offer the biometric unlock.
        case lock
    }

    // MARK: - Checks

    /// Whether a check taken earlier still counts for an action now.
    public func checkStands(now: Date = Date()) -> Bool {
        LockPolicy.checkStands(lastPassed: lastCheckPassed, now: now)
    }

    public mutating func recordCheckPassed(at date: Date = Date()) {
        lastCheckPassed = date
    }

    public mutating func beginCheck() {
        checkInFlight = true
    }

    /// Ends a check, and takes the shield down with it.
    ///
    /// Whoever starts a check has to finish it, because `becameActive` will not: it returns
    /// immediately while a check is in flight, unable to tell "the prompt came back" from
    /// "the counsellor did". The two events race — the scene turns active as the prompt
    /// closes, and the check's answer arrives on a hop back to the main actor — so a check
    /// that left the shield to `becameActive` would strand it up whenever the scene won.
    /// That is the stuck launch screen: the app open behind it, the shield accepting the
    /// taps, and the only way out backgrounding it, which asks for Face ID again.
    public mutating func endCheck() {
        checkInFlight = false
        // Not while the app is genuinely away: there the shield is doing its actual job,
        // and `becameActive` owns taking it down once the time away has been paid for.
        if awaySince == nil { isShielded = false }
    }

    /// The vault was locked. A check can never outlive the session it was taken in.
    public mutating func forgetCheck() {
        lastCheckPassed = nil
    }

    public mutating func lowerShield() {
        isShielded = false
    }

    // MARK: - Leaving and coming back

    /// The app is leaving the foreground.
    ///
    /// The shield goes up on the way out rather than on the way back, so the app switcher's
    /// card is the launch screen. `awaySince` is only set for a real backgrounding: an
    /// inactive app is often just an app with a system prompt in front of it.
    public mutating func leaveForeground(reallyAway: Bool, at date: Date = Date()) {
        // A check of our own makes the app inactive too — a Face ID prompt is a system
        // window in front of it — and shielding then is how the app ends up showing the
        // launch screen at somebody who never left. Only a real backgrounding shields
        // during a check; `.background` still does, so swiping away mid-prompt is covered.
        if !reallyAway && checkInFlight { return }
        isShielded = true
        guard reallyAway, !checkInFlight, awaySince == nil else { return }
        awaySince = date
    }

    /// The app is back on screen. Works out what the time away costs; the caller pays it.
    public mutating func becameActive(
        at date: Date = Date(),
        isUnlocked: Bool,
        policy: LockPolicy
    ) -> ResumeAction {
        // A check is on screen: this is the prompt returning, not the counsellor. The check
        // itself will take the shield down when it finishes.
        guard !checkInFlight else { return .nothing }

        // Everything here is driven by scene-phase *edges*, and an edge can be missed — a
        // blocked main thread, two transitions collapsed into one, a prompt that came and
        // went while the app was busy. A shield that is only ever lowered by an edge is a
        // shield that stays up for good when one goes astray, over an app that is running
        // perfectly behind it. So being active at all is enough to take it down when
        // nothing is asking for it.
        guard let since = awaySince else {
            isShielded = false
            return .nothing
        }
        awaySince = nil

        guard isUnlocked else {
            // Already locked: the unlock screen is the check.
            isShielded = false
            return .offerBiometricUnlock
        }

        switch policy.resume(afterAwayFor: date.timeIntervalSince(since)) {
        case .straightBackIn:
            isShielded = false
            return .nothing
        case .needsCheck:
            // Deliberately not the grace period: coming back is a new arrival, whatever
            // happened a minute ago inside the app.
            lastCheckPassed = nil
            checkInFlight = true
            return .confirmPresence
        case .needsUnlock:
            return .lock
        }
    }
}
