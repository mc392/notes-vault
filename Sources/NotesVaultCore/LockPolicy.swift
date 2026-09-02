import Foundation

/// When the app asks the counsellor to prove who they are.
///
/// The rule this encodes, and the reason it is one type rather than a number in three
/// places: **a check happens at the door, and hardly ever inside**. Coming back to the app
/// is the door. Once past it, the only two things worth asking about again are opening a
/// note — the actual clinical content — and changing something that decides who can get in
/// at all. Everything else (browsing the client list, retention, note fields, writing a
/// note) is behind the door already and asking again there is noise, not security.
public struct LockPolicy: Codable, Hashable, Sendable {
    /// How long the app may be off screen before coming back needs a fresh check.
    ///
    /// Zero — the default — means every reopen asks, which is the honest reading of "these
    /// are clinical records on a phone". It is a setting rather than a constant because a
    /// counsellor flicking between this and a calendar twenty times an hour is a real way
    /// of working, and an app that is exhausting to use is an app that gets left unlocked.
    public var reopenGrace: TimeInterval

    public init(reopenGrace: TimeInterval = 0) {
        self.reopenGrace = reopenGrace
    }

    public static let `default` = LockPolicy()

    /// The choices offered in Settings, in seconds.
    public static let graceChoices: [TimeInterval] = [0, 60, 300, 900]

    public static func graceLabel(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<1: return "Straight away"
        case ..<120: return "After 1 minute"
        case ..<600: return "After 5 minutes"
        default: return "After 15 minutes"
        }
    }

    /// How long a passed check stands for while the app is open and unlocked.
    ///
    /// Reading three notes in a row is one act of reading, not three, so a check taken a
    /// moment ago counts for the next one. A minute is short enough that a phone handed
    /// across a table is not a minute's worth of open notes.
    public static let checkStandsFor: TimeInterval = 60

    /// The longest the vault key is held in memory while the app is off screen, however
    /// generous the grace period. Past this the key is dropped and getting back in means a
    /// real unlock rather than a check.
    public static let keyHeldWhileAway: TimeInterval = 10 * 60

    public var hardLockAfter: TimeInterval { max(reopenGrace, Self.keyHeldWhileAway) }

    /// What coming back to the app after `seconds` away should cost.
    public enum Resume: Equatable, Sendable {
        /// Straight back to where they were: they have only just left.
        case straightBackIn
        /// Face ID, Touch ID or the device passcode, with the app still unlocked behind it.
        case needsCheck
        /// The key has been dropped; the unlock screen, and a passphrase or the biometric
        /// unlock behind it.
        case needsUnlock
    }

    public func resume(afterAwayFor seconds: TimeInterval) -> Resume {
        if seconds >= hardLockAfter { return .needsUnlock }
        if seconds >= reopenGrace { return .needsCheck }
        return .straightBackIn
    }

    /// Whether a check taken at `lastPassed` still counts at `now`.
    public static func checkStands(lastPassed: Date?, now: Date = Date()) -> Bool {
        guard let lastPassed else { return false }
        let age = now.timeIntervalSince(lastPassed)
        return age >= 0 && age < checkStandsFor
    }
}
