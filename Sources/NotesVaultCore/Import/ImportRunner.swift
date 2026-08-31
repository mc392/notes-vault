import Foundation

/// What happened to one proposed note, once it was real.
public struct ImportOutcome: Identifiable, Sendable {
    public let itemID: UUID
    public let origin: ImportOrigin
    public let client: ClientCode
    public let session: Date
    /// The readable name inside the unlocked vault.
    public let filename: String?
    /// The name that actually exists in the sync folder.
    public let storedName: String?
    public let plaintextBytes: Int
    public let storedBytes: Int
    /// The stored file was searched for this note's own words and held none of them.
    public let heldNoPlaintext: Bool
    /// The note was read back out of the vault, through decryption, and matched what went in.
    public let verified: Bool
    public let error: String?

    public var id: UUID { itemID }
    public var succeeded: Bool { error == nil && verified }
}

/// The whole run.
public struct ImportReport: Sendable {
    public let outcomes: [ImportOutcome]
    public let issues: [VaultIssue]
    /// Clients that did not exist in this vault before this import.
    public let newClients: [ClientCode]

    public var written: Int { outcomes.filter(\.succeeded).count }
    public var failed: Int { outcomes.filter { !$0.succeeded }.count }
    /// True when every note that was written came back out of the vault intact.
    public var fullyVerified: Bool { !outcomes.isEmpty && outcomes.allSatisfy(\.succeeded) }
    public var everyFileHeldNoPlaintext: Bool { outcomes.filter { $0.filename != nil }.allSatisfy(\.heldNoPlaintext) }
}

/// Writing an approved plan into the vault.
///
/// **Every note takes the same path as one typed into the app**: build a `NoteRecord`,
/// hand it to `VaultStore`, which serialises it, encrypts it through the vault engine and
/// writes the ciphertext. There is no bulk path, no staging area, and nothing that writes
/// a file the ordinary path would not have written. That is deliberate — an import route
/// with its own writer would be a second place for the encryption to be got wrong, and the
/// one place nobody would think to look.
///
/// After each write the note is read back *out of the vault* and compared with what went
/// in. It costs one decryption per note and it converts "it says it saved" into "it saved,
/// and here is the note again". For someone moving their entire clinical history into an
/// app for the first time, that is the difference that matters.
public enum ImportRunner {
    public struct Progress: Sendable {
        public let completed: Int
        public let total: Int
        public let outcome: ImportOutcome
    }

    public static func run(
        plan: ImportPlan,
        store: VaultStore,
        existingClients: Set<ClientCode> = [],
        now: Date = Date(),
        onProgress: ((Progress) -> Void)? = nil
    ) -> ImportReport {
        var outcomes: [ImportOutcome] = []
        var issues: [VaultIssue] = []
        var newClients: [ClientCode] = []

        let notes = plan.groups.flatMap { group -> [(ClientCode, ImportedItem, NoteRecord)] in
            guard !group.isSkipped, let code = group.assignedCode else { return [] }
            return group.items.compactMap { item in
                guard let record = note(
                    from: item,
                    group: group,
                    code: code,
                    device: store.deviceName,
                    options: plan.options,
                    now: now
                ) else { return nil }
                return (code, item, record)
            }
        }

        for (offset, entry) in notes.enumerated() {
            let (code, item, record) = entry

            // A client the vault has never seen gets the same metadata event that "Add
            // client" writes. Only when they are new: folding an `active` event over a
            // client the counsellor has already marked ended would quietly reopen them.
            if !existingClients.contains(code), !newClients.contains(code) {
                do {
                    try store.write(event: ClientMetadataEvent(
                        client: code,
                        device: store.deviceName,
                        status: .active,
                        retentionBasis: .adult
                    ))
                    newClients.append(code)
                } catch {
                    issues.append(VaultIssue(
                        location: code.rawValue,
                        message: "The notes for \(code) imported, but their client record could not be written: \(message(error))"
                    ))
                }
            }

            let outcome: ImportOutcome
            do {
                let receipt = try store.writeWithReceipt(note: record)
                let readBack = try store.readNote(client: code, filename: receipt.filename)
                let matches = readBack.body == record.body
                    && readBack.id == record.id
                    && readBack.client == record.client

                outcome = ImportOutcome(
                    itemID: item.id,
                    origin: item.origin,
                    client: code,
                    session: record.session,
                    filename: receipt.filename,
                    storedName: receipt.storedName,
                    plaintextBytes: receipt.plaintextBytes,
                    storedBytes: receipt.storedBytes,
                    heldNoPlaintext: receipt.heldNoPlaintext,
                    verified: matches,
                    error: matches ? nil : "The note was written but did not read back the same. It has been left in place — check it before deleting the original."
                )
            } catch {
                outcome = ImportOutcome(
                    itemID: item.id,
                    origin: item.origin,
                    client: code,
                    session: record.session,
                    filename: nil,
                    storedName: nil,
                    plaintextBytes: 0,
                    storedBytes: 0,
                    heldNoPlaintext: true,
                    verified: false,
                    error: message(error)
                )
                issues.append(VaultIssue(location: item.origin.description, message: message(error)))
            }

            outcomes.append(outcome)
            onProgress?(Progress(completed: offset + 1, total: notes.count, outcome: outcome))
        }

        return ImportReport(outcomes: outcomes, issues: issues, newClients: newClients)
    }

    /// Builds the note exactly as the editor would, plus the headers that say where it
    /// came from.
    ///
    /// Those headers are not bookkeeping. An imported note is not a contemporaneous
    /// record — it was typed somewhere else, at some other time, and possibly transcribed
    /// by this app's own parser. A record that cannot tell the difference between a note
    /// written after a session and a note lifted out of a spreadsheet is a worse record,
    /// and both the app and a plain text editor will show these.
    public static func note(
        from item: ImportedItem,
        group: ImportGroup,
        code: ClientCode,
        device: String,
        options: ImportOptions = .default,
        now: Date = Date()
    ) -> NoteRecord? {
        guard let session = item.date.date else { return nil }

        var body = item.body
        if let title = item.sourceTitle,
           !title.isEmpty,
           !body.hasPrefix(title),
           title != group.key {
            body = title + "\n\n" + body
        }
        if group.replaceNamesInBodies {
            body = SensitiveTextScan.replacingNames(in: body, names: group.nameCandidates, with: code.rawValue)
        }

        var headers: [String: String] = [
            "imported-from": header(item.origin.description),
            "imported-on": VaultDate.utcString(now)
        ]
        if !item.date.isCertain {
            // Says so in the note itself, not only on the screen that imported it.
            headers["imported-session-date"] = "uncertain — \(header(item.date.explanation))"
        }

        return NoteRecord(
            client: code,
            session: session,
            sessionUTCOffset: options.timeZone.secondsFromGMT(for: session),
            written: now,
            device: device,
            template: .freeform,
            extraHeaders: headers,
            body: body
        )
    }

    /// A header is one line of `key: value`, so a newline in a filename would end the
    /// header block and swallow the note into it.
    private static func header(_ value: String) -> String {
        NoteFieldDefinition.sanitise(value: value)
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
