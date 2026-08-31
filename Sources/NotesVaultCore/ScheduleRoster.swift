import Foundation

/// The schedule file GroundWork writes and this app reads.
///
/// Client codes and appointment cadence — nothing else. No names, no fees, no attendance,
/// and above all nothing clinical. The format is written down in `docs/schedule-sync.md`,
/// which is the authority if this file and that one ever disagree.
///
/// It is deliberately forgiving. A row this app cannot make sense of is reported and
/// skipped, never fatal: a roster written by a later version of GroundWork, carrying a
/// client whose code was tidied up since, must still bring in the other forty.
public struct ScheduleRoster: Sendable {
    public static let expectedKind = "schedules"
    public static let supportedVersion = 1

    public struct Entry: Hashable, Sendable {
        public let code: ClientCode
        public let status: ClientStatus
        public let schedule: SessionSchedule?
        public let seriesStart: Date?

        public init(code: ClientCode, status: ClientStatus, schedule: SessionSchedule?, seriesStart: Date?) {
            self.code = code
            self.status = status
            self.schedule = schedule
            self.seriesStart = seriesStart
        }
    }

    public let exportedAt: Date?
    public let entries: [Entry]
    /// Rows that were skipped, with the reason. Shown on the sync screen — a client quietly
    /// missing from a sync is exactly the kind of failure this app refuses to have.
    public let issues: [VaultIssue]

    public init(exportedAt: Date?, entries: [Entry], issues: [VaultIssue]) {
        self.exportedAt = exportedAt
        self.entries = entries
        self.issues = issues
    }

    // MARK: - Parsing

    private struct Payload: Decodable {
        let app: String?
        let kind: String?
        let version: Int?
        let exportedAt: String?
        let clients: [Row]?
    }

    private struct Row: Decodable {
        let code: String
        let status: String?
        let cadenceDays: Int?
        let usualDay: String?
        let usualTime: String?
        let seriesStart: String?
    }

    public static func parse(_ data: Data) throws -> ScheduleRoster {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw VaultError.malformedNote("that file is not a GroundWork schedule file — it is not readable JSON")
        }

        guard payload.kind == expectedKind else {
            // The likeliest wrong file by far is a full GroundWork backup, which does hold
            // client codes and would half-work if we let it through. Say what it is.
            let what = payload.app == "GroundWork" ? "a GroundWork file, but not a schedule file" : "not a GroundWork schedule file"
            throw VaultError.malformedNote("that is \(what). In GroundWork, use Settings › GroundWork Notes › Sync schedules.")
        }
        if let version = payload.version, version > supportedVersion {
            throw VaultError.malformedNote("that schedule file was written by a newer version of GroundWork than this app understands. Update GroundWork Notes.")
        }

        var entries: [Entry] = []
        var issues: [VaultIssue] = []
        var seen: Set<ClientCode> = []

        for row in payload.clients ?? [] {
            let code: ClientCode
            do {
                code = try ClientCode(row.code)
            } catch {
                issues.append(VaultIssue(
                    location: row.code,
                    message: "\"\(row.code)\" is not a client code this app can use, so it was skipped."
                ))
                continue
            }
            guard seen.insert(code).inserted else {
                issues.append(VaultIssue(location: code.rawValue, message: "\(code) appears twice in the file. The first entry was used."))
                continue
            }

            var schedule: SessionSchedule?
            if let cadenceDays = row.cadenceDays, cadenceDays > 0 {
                schedule = SessionSchedule(
                    cadenceDays: cadenceDays,
                    usualDay: row.usualDay.flatMap { Weekday(rawValue: $0.lowercased()) },
                    usualTime: row.usualTime.flatMap { TimeOfDay($0) }
                )
            }

            entries.append(Entry(
                code: code,
                status: ClientStatus(rawValue: (row.status ?? "active").lowercased()) ?? .active,
                schedule: schedule,
                seriesStart: row.seriesStart.flatMap(parseDay)
            ))
        }

        return ScheduleRoster(
            exportedAt: payload.exportedAt.flatMap { VaultDate.parse($0) },
            entries: entries,
            issues: issues
        )
    }

    /// `2026-04-07`, the form GroundWork writes dates in. Also accepts a full timestamp, so
    /// a future GroundWork that starts writing one does not break this.
    private static func parseDay(_ text: String) -> Date? {
        if let full = VaultDate.parse(text) { return full }
        let formatter = DateFormatter()
        formatter.calendar = .gregorianUTC
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

/// What one sync would change, worked out before anything is written.
///
/// The vault is append-only, so a sync that wrote an event per client per run would leave
/// a file per client every time the button was pressed — hundreds of them within a year,
/// all identical. Everything here exists to write only what actually differs.
public struct RosterSyncPlan: Sendable {
    public struct Change: Identifiable, Sendable {
        public enum Kind: Sendable {
            case created
            case updated
        }

        public var id: ClientCode { event.client }
        public let kind: Kind
        /// What the change amounts to, in words, for the confirmation screen.
        public let summary: String
        public let event: ClientMetadataEvent

        public init(kind: Kind, summary: String, event: ClientMetadataEvent) {
            self.kind = kind
            self.summary = summary
            self.event = event
        }
    }

    public let changes: [Change]
    /// Clients in the roster whose metadata already matches. Counted, not listed.
    public let unchanged: Int
    /// Clients in this vault that the roster says nothing about. Left completely alone —
    /// the roster is authoritative about cadence, never about who exists.
    public let untouched: [ClientCode]
    public let issues: [VaultIssue]

    public init(changes: [Change], unchanged: Int, untouched: [ClientCode], issues: [VaultIssue]) {
        self.changes = changes
        self.unchanged = unchanged
        self.untouched = untouched
        self.issues = issues
    }

    public var isEmpty: Bool { changes.isEmpty }
    public var created: Int { changes.filter { $0.kind == .created }.count }
    public var updated: Int { changes.filter { $0.kind == .updated }.count }
}

public enum RosterSync {
    /// Works out the difference between a roster and what the vault already holds.
    ///
    /// `existing` is the folded current metadata per client — the same thing
    /// `VaultStore.currentMetadata(for:)` returns, gathered once for the whole vault rather
    /// than per client.
    public static func plan(
        roster: ScheduleRoster,
        existing: [ClientCode: ClientMetadataEvent],
        knownClients: [ClientCode],
        device: String,
        now: Date = Date()
    ) -> RosterSyncPlan {
        var changes: [RosterSyncPlan.Change] = []
        var unchanged = 0

        for entry in roster.entries.sorted(by: { $0.code < $1.code }) {
            let current = existing[entry.code]

            // A schedule GroundWork does not know is left alone rather than cleared. The
            // counsellor may have set a cadence here by hand for a client GroundWork has
            // no sessions for yet, and a sync should not quietly take it away.
            let schedule = entry.schedule ?? current?.schedule
            let seriesStart = entry.seriesStart ?? current?.seriesStart

            guard let current else {
                changes.append(RosterSyncPlan.Change(
                    kind: .created,
                    summary: schedule.map { "New client — \($0.summary)" } ?? "New client",
                    event: ClientMetadataEvent(
                        client: entry.code,
                        written: now,
                        device: device,
                        status: entry.status,
                        retentionBasis: .adult,
                        schedule: schedule,
                        seriesStart: seriesStart
                    )
                ))
                continue
            }

            let statusChanged = current.status != entry.status
            let scheduleChanged = current.schedule != schedule
            let startChanged = current.seriesStart != seriesStart

            guard statusChanged || scheduleChanged || startChanged else {
                unchanged += 1
                continue
            }

            var parts: [String] = []
            if scheduleChanged {
                parts.append(schedule.map { $0.summary } ?? "schedule removed")
            }
            if statusChanged {
                parts.append("\(current.status.displayName) → \(entry.status.displayName)")
            }
            if startChanged && !scheduleChanged && !statusChanged {
                parts.append("start date corrected")
            }

            changes.append(RosterSyncPlan.Change(
                kind: .updated,
                summary: parts.joined(separator: " · "),
                event: ClientMetadataEvent(
                    client: entry.code,
                    written: now,
                    device: device,
                    // Everything not in the roster is carried across from the current
                    // event. The vault's metadata log is folded latest-wins, so an event
                    // that omitted the retention basis would silently reset it to adult.
                    status: entry.status,
                    retentionBasis: current.retentionBasis,
                    lastContactOverride: current.lastContactOverride,
                    schedule: schedule,
                    seriesStart: seriesStart,
                    extraHeaders: current.extraHeaders
                )
            ))
        }

        let inRoster = Set(roster.entries.map(\.code))
        return RosterSyncPlan(
            changes: changes,
            unchanged: unchanged,
            untouched: knownClients.filter { !inRoster.contains($0) }.sorted(),
            issues: roster.issues
        )
    }
}
