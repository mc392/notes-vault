import Foundation

/// How long notes are kept. Editable, because retention is the counsellor's professional
/// decision and their insurer's, not ours — but it always has a value, never a blank that
/// silently means "forever".
public struct RetentionPolicy: Hashable, Sendable, Codable {
    /// BACP good practice for adult clients: around seven years after last contact.
    public var adultYears: Int
    /// Notes for a client seen as a minor are kept at least until they turn 25.
    public var minorAgeCeiling: Int
    /// How far ahead of the due date a client starts appearing in the review list, so the
    /// decision is made deliberately rather than discovered late.
    public var reviewLeadDays: Int

    public static let bacpDefault = RetentionPolicy(adultYears: 7, minorAgeCeiling: 25, reviewLeadDays: 90)

    public init(adultYears: Int = 7, minorAgeCeiling: Int = 25, reviewLeadDays: Int = 90) {
        self.adultYears = adultYears
        self.minorAgeCeiling = minorAgeCeiling
        self.reviewLeadDays = reviewLeadDays
    }
}

public struct RetentionAssessment: Hashable, Sendable, Identifiable {
    public enum State: String, Sendable {
        /// Still in contact, or nothing to count from yet.
        case notCounting
        /// The clock is running and the date is a long way off.
        case counting
        /// Inside the review lead time.
        case dueSoon
        /// Past the retention period.
        case due
    }

    public var id: ClientCode { client }

    public let client: ClientCode
    public let state: State
    public let dueOn: Date?
    public let lastContact: Date?
    /// Written for the counsellor, not the log — this is the sentence shown on the review
    /// row, and it has to be defensible if anyone ever asks why a record was destroyed.
    public let explanation: String

    public var needsAttention: Bool { state == .due || state == .dueSoon }
}

public enum RetentionEngine {
    /// Works out when a client's notes fall out of retention.
    ///
    /// Flags only. Nothing in this file deletes anything, and nothing calls a deletion
    /// path — the review screen hands off to the same typed-confirmation gesture used
    /// everywhere else. "Deliberate, not silent, destruction" is a compliance requirement
    /// (COSCA / BACP), so the automation deliberately stops one step short.
    public static func assess(
        client: ClientCode,
        status: ClientStatus,
        basis: RetentionBasis,
        lastContact: Date?,
        policy: RetentionPolicy = .bacpDefault,
        now: Date = Date(),
        calendar: Calendar = .gregorianUTC
    ) -> RetentionAssessment {
        guard let lastContact else {
            return RetentionAssessment(
                client: client,
                state: .notCounting,
                dueOn: nil,
                lastContact: nil,
                explanation: "No sessions logged yet, so there is nothing to count from."
            )
        }

        guard status.startsRetentionClock else {
            let reason = status == .paused
                ? "Paused, not ended — the retention clock starts when the work is finished."
                : "Still an active client."
            return RetentionAssessment(
                client: client,
                state: .notCounting,
                dueOn: lastContact,
                lastContact: lastContact,
                explanation: reason
            )
        }

        let adultDue = calendar.date(byAdding: .year, value: policy.adultYears, to: lastContact) ?? lastContact

        let dueOn: Date
        let basisSentence: String
        switch basis {
        case .adult:
            dueOn = adultDue
            basisSentence = "\(policy.adultYears) years after the last session."
        case let .minor(reaches25On):
            // Whichever is later. A 17-year-old seen for a year is covered by the age
            // ceiling; a 24-year-old seen as a minor years earlier is covered by the
            // seven-year rule. Taking the maximum is the only reading that satisfies both.
            dueOn = max(adultDue, reaches25On)
            basisSentence = dueOn == reaches25On
                ? "Seen as a minor — kept until age \(policy.minorAgeCeiling)."
                : "Seen as a minor, but \(policy.adultYears) years after the last session falls later."
        }

        let leadStart = calendar.date(byAdding: .day, value: -policy.reviewLeadDays, to: dueOn) ?? dueOn

        let state: RetentionAssessment.State
        let explanation: String
        if now >= dueOn {
            state = .due
            explanation = "Past the retention period. \(basisSentence) Review and destroy, or record why it is being kept."
        } else if now >= leadStart {
            state = .dueSoon
            explanation = "Due for review soon. \(basisSentence)"
        } else {
            state = .counting
            explanation = basisSentence
        }

        return RetentionAssessment(
            client: client,
            state: state,
            dueOn: dueOn,
            lastContact: lastContact,
            explanation: explanation
        )
    }

    /// The review list: everything needing attention, soonest first, then everything else.
    public static func review(
        clients: [ClientSummary],
        policy: RetentionPolicy = .bacpDefault,
        now: Date = Date(),
        calendar: Calendar = .gregorianUTC
    ) -> [RetentionAssessment] {
        clients
            .map {
                assess(
                    client: $0.code,
                    status: $0.status,
                    basis: $0.retentionBasis,
                    lastContact: $0.lastContact,
                    policy: policy,
                    now: now,
                    calendar: calendar
                )
            }
            .sorted { lhs, rhs in
                if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
                switch (lhs.dueOn, rhs.dueOn) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.client < rhs.client
                }
            }
    }
}
