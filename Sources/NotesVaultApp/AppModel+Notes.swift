import Foundation
import NotesVaultCore
import NotesVaultCrypto

/// The clinical record itself: the index, notes, drafts, clients and the sessions they are
/// owed.
extension AppModel {
    // MARK: - Index

    /// Loads the cached index, then rebuilds from the vault.
    ///
    /// Cache first so the list is on screen immediately, rebuild always so it is right —
    /// another device may have added notes since this one last looked, and there is no
    /// server to tell us. The rebuild replaces the cache when it finishes.
    public func refreshIndex(force: Bool) async {
        guard let store else { return }

        if !force, let cached = indexStore?.load() {
            index = cached
        }

        let token = sessionToken
        await run("Reading the vault…") {
            try store.rebuildIndex(shouldContinue: { !token.isRevoked })
        } then: { [weak self] result in
            guard let self else { return }
            self.index = result.index
            self.issues = result.issues
            self.indexStore?.save(result.index)
        }
    }

    // MARK: - Notes

    /// Writes a note. Returns whether it is in the vault — which the editor needs to know
    /// before it throws away the draft, and before it closes.
    @discardableResult
    public func addNote(
        client: ClientCode,
        sessionDate: Date,
        template: NoteTemplate,
        body: String,
        fieldValues: [String: String] = [:],
        supersedes: NoteID? = nil
    ) async -> Bool {
        guard let store else { return false }
        let note = NoteRecord(
            client: client,
            session: sessionDate,
            written: Date(),
            device: store.deviceName,
            template: template,
            supersedes: supersedes,
            extraHeaders: noteFields.headers(from: fieldValues),
            body: body
        )
        return await run("Saving…") {
            _ = try store.write(note: note)
        } then: { [weak self] _ in
            Task { await self?.refreshIndex(force: true) }
        }
    }

    /// Nil when the note could not be read — or when the vault was locked while it was
    /// being read, in which case there is nobody left to show it to.
    public func readNote(_ entry: NoteIndexEntry) async -> NoteRecord? {
        guard let store else { return nil }
        var result: NoteRecord?
        await run(nil) {
            try store.readNote(client: entry.client, filename: entry.filename)
        } then: { note in
            result = note
        }
        return result
    }

    // MARK: - Drafts

    /// Everything the editor does with a half-written note goes through here, so views
    /// never reach into the crypto module themselves — and so all three calls can be
    /// no-ops the moment the vault is locked.
    ///
    /// Saving is fire-and-forget onto the vault queue rather than awaited: it happens as
    /// the counsellor types, and a draft is never worth a pause between two keystrokes.
    /// The queue is serial, so a save enqueued just before a clear still lands first and
    /// the clear still wins.
    public func saveDraft(_ draft: NoteDraft) {
        guard store != nil, let vaultID, let draftStore else { return }
        Self.queue.async { draftStore.save(draft, vaultID: vaultID) }
    }

    public func loadDraft(client: ClientCode, correcting: NoteID?) async -> NoteDraft? {
        guard store != nil, let vaultID, let draftStore else { return nil }
        var draft: NoteDraft?
        await run(nil) {
            draftStore.load(vaultID: vaultID, client: client, correcting: correcting)
        } then: { found in
            draft = found
        }
        return draft
    }

    public func clearDraft(client: ClientCode, correcting: NoteID?) {
        guard store != nil, let vaultID, let draftStore else { return }
        Self.queue.async { draftStore.clear(vaultID: vaultID, client: client, correcting: correcting) }
    }

    // MARK: - Clients

    public func createClient(_ code: ClientCode) async {
        guard let store else { return }
        let event = ClientMetadataEvent(
            client: code,
            device: store.deviceName,
            status: .active,
            retentionBasis: .adult
        )
        await run("Adding \(code)…") {
            try store.write(event: event)
        } then: { [weak self] _ in
            // Client metadata only: no note has changed, so the index is brought up to date
            // in place rather than by re-reading and decrypting the whole vault.
            self?.applyToIndex([code: event])
        }
    }

    public func updateClient(
        _ code: ClientCode,
        status: ClientStatus,
        retentionBasis: RetentionBasis,
        lastContactOverride: Date?,
        schedule: SessionSchedule?,
        seriesStart: Date?
    ) async {
        guard let store else { return }
        let event = ClientMetadataEvent(
            client: code,
            device: store.deviceName,
            status: status,
            retentionBasis: retentionBasis,
            lastContactOverride: lastContactOverride,
            schedule: schedule,
            seriesStart: seriesStart
        )
        await run("Saving…") {
            try store.write(event: event)
        } then: { [weak self] _ in
            self?.applyToIndex([code: event])
        }
    }

    /// Folds freshly written client metadata into the index and saves it.
    ///
    /// The event this app has just written is, by definition, the latest in that client's
    /// log, and the log folds latest-wins — so this is the same answer a full rebuild would
    /// give, without opening a single note. See `VaultIndex.updatingClients`.
    func applyToIndex(_ events: [ClientCode: ClientMetadataEvent]) {
        guard !events.isEmpty else { return }
        index = index.updatingClients(events)
        indexStore?.save(index)
    }

    // MARK: - Predicted sessions

    /// Every session this client should have had since their first note, and has not.
    ///
    /// Not only the ones since the *latest* note: writing one of them up must not make the
    /// rest disappear, which is exactly what anchoring on the latest note used to do.
    ///
    /// Computed entirely from the vault — the notes already stored and the cadence in the
    /// client's metadata — so it is right on a Mac that has never been in contact with
    /// GroundWork, as long as iCloud has brought the vault across. See
    /// `docs/schedule-sync.md`. Read from `outstanding`, which is worked out once per index;
    /// `SessionPrediction` guarantees the per-client and whole-vault answers agree.
    public func predictedSessions(for code: ClientCode) -> [PredictedSession] {
        outstanding[code] ?? []
    }

    // MARK: - Retention

    /// Destroys every note for one client. Only ever reached through `DestroyClientView`,
    /// which requires the code to be typed out in full first.
    public func destroy(client code: ClientCode) async {
        guard let store else { return }
        // A destroyed client whose half-written note survived in Application Support would
        // make a liar of the destruction promise, so the drafts go with the notes.
        let drafts = draftStore
        let vaultID = self.vaultID
        await run("Removing \(code)…") {
            try store.destroyEverything(for: code)
            if let drafts, let vaultID { drafts.clearAll(vaultID: vaultID) }
        } then: { [weak self] _ in
            Task { await self?.refreshIndex(force: true) }
        }
    }
}
