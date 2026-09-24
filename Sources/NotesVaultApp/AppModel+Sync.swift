import Foundation
import NotesVaultCore
import NotesVaultCrypto

/// GroundWork's schedule file: choosing it, reading it, and writing what it changes.
extension AppModel {
    public var rosterFileName: String? { RosterBookmark.storedDisplayName }
    public var rosterLastSync: Date? { RosterBookmark.lastSync }

    /// Called with the file the picker returned. Remembers it, then reads it — choosing the
    /// file and syncing it are one action as far as the counsellor is concerned.
    ///
    /// Bookmarking goes through `run` rather than being done here, because a file freshly
    /// exported into iCloud Drive may still be a placeholder: it is worth waiting a few
    /// seconds for, and waiting on the main thread is how an app gets killed by the
    /// watchdog instead.
    public func chooseRosterFile(_ url: URL) async -> RosterSyncPlan? {
        // Not session-bound: remembering a file is not about the open vault.
        let remembered = await run("Remembering that file…", sessionBound: false) {
            try RosterBookmark.store(url, downloadTimeout: 15)
        } then: { _ in }
        guard remembered else { return nil }
        // `rosterFileName` reads UserDefaults rather than published state, so nothing has
        // told the settings screen its name just changed.
        objectWillChange.send()
        return await planScheduleSync()
    }

    public func forgetRosterFile() {
        RosterBookmark.clear()
        objectWillChange.send()
    }

    /// Reads the roster and works out what would change. Writes nothing.
    ///
    /// Split from `applyScheduleSync` on purpose: a sync can end a client, which starts a
    /// retention clock, so it is shown before it happens rather than reported afterwards.
    public func planScheduleSync() async -> RosterSyncPlan? {
        guard let store else { return nil }
        let url: URL?
        do {
            url = try RosterBookmark.resolve()
        } catch {
            report(error)
            return nil
        }
        guard let url else { return nil }

        let device = store.deviceName
        var plan: RosterSyncPlan?
        await run("Reading GroundWork's schedules…") { () -> RosterSyncPlan in
            let roster = try ScheduleRoster.parse(try RosterBookmark.read(url))
            let current = try store.allCurrentMetadata()
            var built = RosterSync.plan(
                roster: roster,
                existing: current.events,
                knownClients: Array(current.events.keys),
                device: device
            )
            if !current.issues.isEmpty {
                built = RosterSyncPlan(
                    changes: built.changes,
                    unchanged: built.unchanged,
                    untouched: built.untouched,
                    issues: built.issues + current.issues
                )
            }
            return built
        } then: { result in
            plan = result
        }
        return plan
    }

    /// Writes an approved plan. One metadata event per client that actually changed.
    ///
    /// `progress` is called from the vault queue as each client lands, so a sync of two
    /// hundred clients shows a bar that moves rather than a spinner that does not.
    ///
    /// A sync writes client metadata and nothing else, so the index is updated in place
    /// afterwards. It used to call `refreshIndex(force:)`, which re-reads and decrypts every
    /// note in the vault — on a full vault that is tens of seconds of work after a sync that
    /// could not have changed a single note, and it is what made a big sync feel endless.
    ///
    /// Locking the vault stops it between clients. What was written stays written — each
    /// client's event is whole — and the next unlock's rebuild picks it up.
    @discardableResult
    public func applyScheduleSync(
        _ plan: RosterSyncPlan,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> Int {
        guard let store, !plan.isEmpty else {
            RosterBookmark.lastSync = Date()
            return 0
        }
        var applied: [ClientCode: ClientMetadataEvent] = [:]
        let total = plan.changes.count
        let token = sessionToken

        // No busy message: the sync screen shows its own progress, client by client, and a
        // modal spinner over the top of it would hide the one thing worth watching.
        await run(nil) { () -> [ClientCode: ClientMetadataEvent] in
            var written: [ClientCode: ClientMetadataEvent] = [:]
            for (offset, change) in plan.changes.enumerated() {
                guard !token.isRevoked else { break }
                try store.write(event: change.event)
                written[change.event.client] = change.event
                progress(offset + 1, total)
            }
            return written
        } then: { written in
            applied = written
        }

        if !applied.isEmpty {
            RosterBookmark.lastSync = Date()
            applyToIndex(applied)
        }
        return applied.count
    }
}
