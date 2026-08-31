import XCTest
@testable import NotesVaultCore

private let london = TimeZone(identifier: "Europe/London")!
private let fixedNow = VaultDate.parse("2026-08-30T12:00:00Z")!
private let options = ImportOptions(dayFirst: true, splitLongDocuments: true, grouping: .folder, timeZone: london)

private func item(
    _ group: String,
    _ isoDate: String?,
    body: String,
    title: String? = nil,
    container: String = "notes.txt",
    locator: String? = nil
) -> ImportedItem {
    let date: ImportedDate = isoDate.flatMap { VaultDate.parse($0) }.map { .found($0, raw: "test") } ?? .unknown
    return ImportedItem(
        origin: ImportOrigin(container: container, locator: locator),
        sourceTitle: title,
        groupKey: group,
        date: date,
        body: body
    )
}

private func result(_ items: [ImportedItem]) -> ImportFileResult {
    ImportFileResult(file: "notes.txt", format: .plainText, items: items, table: nil, issues: [])
}

final class ImportPlanTests: XCTestCase {
    func testGroupsBySourceKeyAndOrdersByDate() {
        let plan = ImportPlan.make(
            results: [result([
                item("Sarah M", "2026-06-21T09:30:00Z", body: "Second"),
                item("John D", "2026-06-14T11:00:00Z", body: "Other client"),
                item("Sarah M", "2026-06-14T09:30:00Z", body: "First")
            ])],
            existingClients: [],
            options: options
        )
        XCTAssertEqual(plan.groups.map(\.key), ["Sarah M", "John D"])
        XCTAssertEqual(plan.groups[0].items.map(\.body), ["First", "Second"])
        XCTAssertEqual(plan.totalItemCount, 3)
    }

    /// Dragging in a folder and a zip of the same folder is an easy mistake and a nasty one
    /// to unpick afterwards, because the vault never overwrites — both copies would stay.
    func testTheSameNoteTwiceIsCollapsed() {
        let plan = ImportPlan.make(
            results: [
                result([item("Sarah M", "2026-06-14T09:30:00Z", body: "Discussed sleep.")]),
                result([item("Sarah M", "2026-06-14T09:30:00Z", body: "Discussed sleep.")])
            ],
            existingClients: [],
            options: options
        )
        XCTAssertEqual(plan.totalItemCount, 1)
        XCTAssertEqual(plan.duplicatesCollapsed, 1)
    }

    /// A client the counsellor already has must be offered, or the import quietly splits
    /// one person's record across two codes and the retention clock starts again.
    func testOffersExistingClientsBeforeInventingACode() {
        let suggestion = ClientCodeSuggestion.suggest(for: "Sarah M", existing: [Fixture.code("SM2"), Fixture.code("JD1")])
        XCTAssertEqual(suggestion.existing, [Fixture.code("SM2")])
        XCTAssertNotNil(suggestion.proposed)
    }

    /// A source that already uses the counsellor's own codes is the best case, and the
    /// suggestion should just be the code.
    func testASourceThatAlreadyUsesCodesIsTakenAtItsWord() {
        let suggestion = ClientCodeSuggestion.suggest(for: "SM2", existing: [Fixture.code("SM2")])
        XCTAssertEqual(suggestion.existing, [Fixture.code("SM2")])
        XCTAssertNil(suggestion.proposed)
    }

    func testNothingCanBeImportedUntilEveryGroupHasACode() {
        var plan = ImportPlan.make(
            results: [result([item("Sarah M", "2026-06-14T09:30:00Z", body: "One")])],
            existingClients: [],
            options: options
        )
        XCTAssertFalse(plan.canImport)
        XCTAssertEqual(plan.readyItemCount, 0)

        plan.assign(Fixture.code("SM2"), toGroup: "Sarah M")
        XCTAssertTrue(plan.canImport)
        XCTAssertEqual(plan.readyItemCount, 1)
    }

    /// A note with no date has nowhere to go: the filename, the timeline and the retention
    /// clock are all derived from it.
    func testANoteWithNoDateBlocksTheImportUntilOneIsGiven() {
        var plan = ImportPlan.make(
            results: [result([item("Sarah M", nil, body: "Undated")])],
            existingClients: [],
            options: options
        )
        plan.assign(Fixture.code("SM2"), toGroup: "Sarah M")
        XCTAssertFalse(plan.canImport)
        XCTAssertEqual(plan.undatedItemCount, 1)

        let id = plan.groups[0].items[0].id
        plan.setDate(Fixture.date("2026-06-14T09:30:00Z"), forItem: id)
        XCTAssertTrue(plan.canImport)
    }

    func testSpotsNotesAlreadyInTheVault() {
        var plan = ImportPlan.make(
            results: [result([item("Sarah M", "2026-06-14T09:30:00Z", body: "One")])],
            existingClients: [],
            options: options
        )
        plan.assign(Fixture.code("SM2"), toGroup: "Sarah M")

        let existing = NoteIndexEntry(
            note: NoteRecord(
                client: Fixture.code("SM2"),
                session: Fixture.date("2026-06-14T09:30:00Z"),
                sessionUTCOffset: london.secondsFromGMT(for: Fixture.date("2026-06-14T09:30:00Z")),
                device: "mac",
                body: "Already here"
            ),
            filename: "2026-06-14T1030-mac.note"
        )
        XCTAssertEqual(plan.clashes(with: [existing]).count, 1)
        XCTAssertEqual(plan.clashes(with: []).count, 0)
    }

    func testTwoGroupsPointingAtOneClientIsReportedNotForbidden() {
        var plan = ImportPlan.make(
            results: [result([
                item("Sarah M", "2026-06-14T09:30:00Z", body: "One"),
                item("S Mitchell", "2026-06-21T09:30:00Z", body: "Two")
            ])],
            existingClients: [],
            options: options
        )
        plan.assign(Fixture.code("SM2"), toGroup: "Sarah M")
        plan.assign(Fixture.code("SM2"), toGroup: "S Mitchell")
        XCTAssertEqual(plan.mergedCodes, [Fixture.code("SM2")])
        XCTAssertTrue(plan.canImport)
    }
}

final class ImportRunnerTests: XCTestCase {
    private func plan(_ items: [ImportedItem], code: String = "SM2", replaceNames: Bool = true) -> ImportPlan {
        var plan = ImportPlan.make(results: [result(items)], existingClients: [], options: options)
        for group in plan.groups {
            plan.assign(Fixture.code(code), toGroup: group.key)
            if let index = plan.groups.firstIndex(where: { $0.key == group.key }) {
                plan.groups[index].replaceNamesInBodies = replaceNames
            }
        }
        return plan
    }

    func testWritesEveryNoteAndReadsEachOneBackOut() throws {
        let (store, _, _) = Fixture.store()
        let report = ImportRunner.run(
            plan: plan([
                item("Sarah M", "2026-06-14T09:30:00Z", body: "Discussed sleep."),
                item("Sarah M", "2026-06-21T09:30:00Z", body: "Reviewed the week.")
            ]),
            store: store,
            now: fixedNow
        )

        XCTAssertEqual(report.written, 2)
        XCTAssertEqual(report.failed, 0)
        XCTAssertTrue(report.fullyVerified)

        let rebuilt = try store.rebuildIndex()
        XCTAssertEqual(rebuilt.index.notes(for: Fixture.code("SM2")).count, 2)
        XCTAssertTrue(rebuilt.issues.isEmpty)
    }

    /// The claim the whole import screen is built to demonstrate: what lands on disk is a
    /// ciphertext name, and the note's own words are not in the file.
    func testWhatLandsOnDiskIsNeitherTheNameNorTheWords() throws {
        let (store, files, _) = Fixture.store()
        let report = ImportRunner.run(
            plan: plan([item("Sarah M", "2026-06-14T09:30:00Z", body: "Discussed insomnia and bereavement.")]),
            store: store,
            now: fixedNow
        )
        let outcome = try XCTUnwrap(report.outcomes.first)

        XCTAssertEqual(outcome.filename, "2026-06-14T1030-mac.note")
        XCTAssertNotEqual(outcome.storedName, outcome.filename)
        XCTAssertTrue(outcome.storedName?.hasSuffix(".c9r") == true)
        XCTAssertTrue(outcome.heldNoPlaintext)
        XCTAssertTrue(report.everyFileHeldNoPlaintext)

        // And the same thing again, from the file store rather than from our own report.
        for (path, data) in files.files {
            XCTAssertFalse(path.contains("SM2"), "a client code reached a stored path")
            XCTAssertNil(data.range(of: Data("insomnia".utf8)), "note text reached a stored file")
        }
    }

    /// An imported note is not a contemporaneous record, and the note itself says so — in
    /// a header that survives export to plain text.
    func testEveryImportedNoteSaysWhereItCameFrom() throws {
        let (store, _, _) = Fixture.store()
        let report = ImportRunner.run(
            plan: plan([item("Sarah M", "2026-06-14T09:30:00Z", body: "One", container: "sessions.csv", locator: "row 12")]),
            store: store,
            now: fixedNow
        )
        let filename = try XCTUnwrap(report.outcomes.first?.filename)
        let note = try store.readNote(client: Fixture.code("SM2"), filename: filename)

        XCTAssertEqual(note.extraHeaders["imported-from"], "sessions.csv · row 12")
        XCTAssertEqual(note.extraHeaders["imported-on"], "2026-08-30T12:00:00Z")
        // And it is readable in a text editor, with no reference to this app.
        let text = String(decoding: note.serialised(), as: UTF8.self)
        XCTAssertTrue(text.contains("imported-from: sessions.csv · row 12"))
    }

    func testAnUncertainDateIsMarkedInTheNoteItself() throws {
        let (store, _, _) = Fixture.store()
        var uncertain = ImportPlan.make(
            results: [result([ImportedItem(
                origin: ImportOrigin(container: "notes.txt"),
                groupKey: "Sarah M",
                date: .fromFile(Fixture.date("2026-06-14T09:30:00Z")),
                body: "No date in the file itself."
            )])],
            existingClients: [],
            options: options
        )
        uncertain.assign(Fixture.code("SM2"), toGroup: "Sarah M")

        let report = ImportRunner.run(plan: uncertain, store: store, now: fixedNow)
        let filename = try XCTUnwrap(report.outcomes.first?.filename)
        let note = try store.readNote(client: Fixture.code("SM2"), filename: filename)
        XCTAssertTrue(note.extraHeaders["imported-session-date"]?.hasPrefix("uncertain") == true)
    }

    func testTheClientsOwnNameIsReplacedByTheirCode() throws {
        let (store, _, _) = Fixture.store()
        let report = ImportRunner.run(
            plan: plan([item("Sarah Mitchell", "2026-06-14T09:30:00Z", body: "Sarah arrived on time. Sarah Mitchell agreed a plan.")]),
            store: store,
            now: fixedNow
        )
        let filename = try XCTUnwrap(report.outcomes.first?.filename)
        let note = try store.readNote(client: Fixture.code("SM2"), filename: filename)

        XCTAssertFalse(note.body.contains("Sarah"))
        XCTAssertTrue(note.body.contains("SM2 arrived on time."))
    }

    func testLeavingTheNamesAloneIsRespected() throws {
        let (store, _, _) = Fixture.store()
        let report = ImportRunner.run(
            plan: plan([item("Sarah Mitchell", "2026-06-14T09:30:00Z", body: "Sarah arrived on time.")], replaceNames: false),
            store: store,
            now: fixedNow
        )
        let filename = try XCTUnwrap(report.outcomes.first?.filename)
        let note = try store.readNote(client: Fixture.code("SM2"), filename: filename)
        XCTAssertTrue(note.body.contains("Sarah arrived"))
    }

    func testANewClientGetsTheSameRecordAddingOneByHandWouldGive() throws {
        let (store, _, _) = Fixture.store()
        let report = ImportRunner.run(
            plan: plan([item("Sarah M", "2026-06-14T09:30:00Z", body: "One")]),
            store: store,
            now: fixedNow
        )
        XCTAssertEqual(report.newClients, [Fixture.code("SM2")])
        let metadata = try store.currentMetadata(for: Fixture.code("SM2"))
        XCTAssertEqual(metadata?.status, .active)
    }

    /// Folding an `active` event over a client the counsellor has already ended would
    /// quietly reopen them, and the retention review would stop flagging them.
    func testImportingIntoAnEndedClientDoesNotReopenThem() throws {
        let (store, _, _) = Fixture.store()
        try store.write(event: ClientMetadataEvent(
            client: Fixture.code("SM2"),
            device: "mac",
            status: .ended,
            retentionBasis: .adult
        ))

        _ = ImportRunner.run(
            plan: plan([item("Sarah M", "2026-06-14T09:30:00Z", body: "One")]),
            store: store,
            existingClients: [Fixture.code("SM2")],
            now: fixedNow
        )
        XCTAssertEqual(try store.currentMetadata(for: Fixture.code("SM2"))?.status, .ended)
    }

    /// One note that cannot be written must not stop the other three hundred and ninety-nine.
    func testOneFailureDoesNotStopTheRest() {
        let (store, files, _) = Fixture.store()
        files.failNextWrite = true

        let report = ImportRunner.run(
            plan: plan([
                item("Sarah M", "2026-06-14T09:30:00Z", body: "One"),
                item("Sarah M", "2026-06-21T09:30:00Z", body: "Two"),
                item("Sarah M", "2026-06-28T09:30:00Z", body: "Three")
            ]),
            store: store,
            now: fixedNow
        )
        XCTAssertEqual(report.written, 3 - report.failed)
        XCTAssertGreaterThan(report.written, 0)
        XCTAssertFalse(report.issues.isEmpty)
    }

    func testProgressIsReportedOnceForEachNote() {
        let (store, _, _) = Fixture.store()
        var seen: [Int] = []
        _ = ImportRunner.run(
            plan: plan([
                item("Sarah M", "2026-06-14T09:30:00Z", body: "One"),
                item("Sarah M", "2026-06-21T09:30:00Z", body: "Two")
            ]),
            store: store,
            now: fixedNow,
            onProgress: { seen.append($0.completed) }
        )
        XCTAssertEqual(seen, [1, 2])
    }

    /// End to end, in the shape a counsellor actually arrives in: a spreadsheet.
    func testASpreadsheetImportsFromFileToVault() throws {
        let (store, _, _) = Fixture.store()
        let csv = """
        Client,Session date,Notes
        Sarah M,14/06/2026,"Discussed sleep.
        Agreed homework."
        Sarah M,21/06/2026,Reviewed the week.
        John D,21/06/2026,Reviewed medication.
        """
        let file = ImportFile(name: "sessions.csv", data: Data(csv.utf8))
        let probe = ImportReader.read(file, options: options, now: fixedNow)
        let table = try XCTUnwrap(probe.table)

        let mapped = TabularImport.items(
            from: table,
            mapping: ColumnMapping.suggest(for: table),
            container: file.name,
            options: options,
            now: fixedNow
        )
        var plan = ImportPlan.make(
            results: [ImportFileResult(file: file.name, format: .delimited, items: mapped.items, table: nil, issues: mapped.issues)],
            existingClients: [],
            options: options
        )
        XCTAssertEqual(plan.groups.count, 2)
        XCTAssertFalse(plan.canImport)

        plan.assign(Fixture.code("SM2"), toGroup: "Sarah M")
        plan.assign(Fixture.code("JD1"), toGroup: "John D")
        XCTAssertTrue(plan.canImport)

        let report = ImportRunner.run(plan: plan, store: store, now: fixedNow)
        XCTAssertEqual(report.written, 3)
        XCTAssertTrue(report.fullyVerified)

        let index = try store.rebuildIndex().index
        XCTAssertEqual(index.clients.map(\.code.rawValue).sorted(), ["JD1", "SM2"])
        XCTAssertEqual(index.notes(for: Fixture.code("SM2")).count, 2)
        XCTAssertEqual(index.client(Fixture.code("SM2"))?.firstContact, index.notes(for: Fixture.code("SM2")).last?.session)
    }
}

final class ImportSkippingTests: XCTestCase {
    private func twoGroups() -> ImportPlan {
        ImportPlan.make(
            results: [ImportFileResult(
                file: "notes.txt",
                format: .plainText,
                items: [
                    ImportedItem(origin: ImportOrigin(container: "notes.txt"), groupKey: "Sarah M", date: .found(Fixture.date("2026-06-14T09:30:00Z"), raw: "t"), body: "One"),
                    ImportedItem(origin: ImportOrigin(container: "notes.txt"), groupKey: "Old backup", date: .found(Fixture.date("2026-06-21T09:30:00Z"), raw: "t"), body: "Two")
                ],
                table: nil,
                issues: []
            )],
            existingClients: [],
            options: options
        )
    }

    /// "Not decided yet" and "deliberately left out" have to be different states, or a
    /// counsellor with forty folders cannot tell which ones they have dealt with.
    func testAGroupLeftOutOnPurposeDoesNotBlockTheImport() {
        var plan = twoGroups()
        plan.assign(Fixture.code("SM2"), toGroup: "Sarah M")
        XCTAssertFalse(plan.canImport)

        plan.setSkipped(true, forGroup: "Old backup")
        XCTAssertTrue(plan.canImport)
        XCTAssertEqual(plan.readyItemCount, 1)
        XCTAssertEqual(plan.skippedItemCount, 1)
    }

    func testASkippedGroupIsNotWritten() throws {
        let (store, _, _) = Fixture.store()
        var plan = twoGroups()
        plan.assign(Fixture.code("SM2"), toGroup: "Sarah M")
        plan.setSkipped(true, forGroup: "Old backup")

        let report = ImportRunner.run(plan: plan, store: store, now: fixedNow)
        XCTAssertEqual(report.written, 1)
        XCTAssertEqual(try store.rebuildIndex().index.notes.count, 1)
    }

    /// Giving a skipped group a code brings it back, rather than leaving it in a state
    /// where it has a code and is still ignored.
    func testAssigningACodeUnskipsAGroup() {
        var plan = twoGroups()
        plan.setSkipped(true, forGroup: "Old backup")
        plan.assign(Fixture.code("JD1"), toGroup: "Old backup")
        XCTAssertFalse(plan.groups.first { $0.key == "Old backup" }!.isSkipped)
    }
}

final class NoteHeaderScanTests: XCTestCase {
    private let block = """
    Session 4
    Date: 14/06/2026
    Session number: 4
    Duration: 50 minutes
    Room: 2

    Client presented as flat. We talked about: sleep, work, and the move.
    Agreed: homework before next week.
    """

    func testFindsTheMetadataBlockAndNothingBelowIt() {
        let found = NoteHeaderScan.detect(in: block)
        XCTAssertEqual(found.map(\.label), ["Session number", "Duration", "Room"])
        XCTAssertEqual(found.map(\.value), ["4", "50 minutes", "2"])
    }

    /// A colon in a sentence is not a field. Getting this wrong would strip the first line
    /// of a clinical note and file it as metadata.
    func testASentenceWithAColonIsNotAField() {
        XCTAssertNil(NoteHeaderScan.field(from: "Client presented as flat. We talked about: sleep, work, and the move."))
        XCTAssertNil(NoteHeaderScan.field(from: "09:30"))
        XCTAssertNil(NoteHeaderScan.field(from: "14/06/2026 09:30 - session"))
    }

    /// The date is the note's session date already, and a name has nowhere to go in this
    /// app — so neither is ever offered as a field.
    func testDatesAndIdentitiesAreNeverOffered() {
        let found = NoteHeaderScan.detect(in: "Date: 14/06/2026\nName: Sarah Mitchell\nDOB: 14/06/1990\nRoom: 2")
        XCTAssertEqual(found.map(\.label), ["Room"])
    }

    /// Markdown survives an export from Apple Notes.
    func testReadsMarkdownEmphasisAroundTheLabel() {
        XCTAssertEqual(NoteHeaderScan.field(from: "**Session number:** 4")?.label, "Session number")
        XCTAssertEqual(NoteHeaderScan.field(from: "- Location: Room 2")?.value, "Room 2")
    }

    func testKeepsWhatWasNotAccepted() {
        let result = NoteHeaderScan.apply(to: block, accepting: ["session-number": "session-number"])
        XCTAssertEqual(result.headers, ["session-number": "4"])
        XCTAssertFalse(result.body.contains("Session number: 4"))
        XCTAssertTrue(result.body.contains("Duration: 50 minutes"))
        XCTAssertTrue(result.body.contains("Date: 14/06/2026"))
        XCTAssertTrue(result.body.contains("Client presented as flat"))
    }

    /// The default is to change nothing.
    func testWithNoDecisionsTheNoteIsUntouched() {
        XCTAssertEqual(NoteHeaderScan.apply(to: block, accepting: [:]).body, block)
    }

    func testMatchesAFieldTheDeviceAlreadyHas() {
        var settings = NoteFieldSettings.default
        settings.setEnabled(true, forKey: "session-number")

        let items = [ImportedItem(
            origin: ImportOrigin(container: "n.txt"),
            groupKey: "Sarah M",
            date: .unknown,
            body: block
        )]
        let candidates = ImportFieldCandidate.gather(from: items, noteFields: settings)

        let sessionNumber = candidates.first { $0.key == "session-number" }
        XCTAssertEqual(sessionNumber?.matchingFieldLabel, "Session number")
        XCTAssertTrue(sessionNumber?.matchingFieldIsEnabled == true)
        XCTAssertEqual(sessionNumber?.suggestedKind, .number)

        // Nothing on this device is called "Room", so it arrives as a suggestion only.
        let room = candidates.first { $0.key == "room" }
        XCTAssertNil(room?.matchingFieldKey)
        XCTAssertEqual(room?.examples, ["2"])
    }

    /// A built-in that exists but has never been switched on is a suggestion, not a match:
    /// turning a field on changes what every future note screen shows, and that is the
    /// counsellor's call.
    func testAFieldThatExistsButIsOffIsNotUsedWithoutAsking() {
        let plan = ImportPlan.make(
            results: [ImportFileResult(
                file: "n.txt",
                format: .plainText,
                items: [ImportedItem(origin: ImportOrigin(container: "n.txt"), groupKey: "Sarah M", date: .found(Fixture.date("2026-06-14T09:30:00Z"), raw: "t"), body: block)],
                table: nil,
                issues: []
            )],
            existingClients: [],
            noteFields: .default,
            options: options
        )
        XCTAssertTrue(plan.acceptedFields.isEmpty)
        XCTAssertEqual(plan.fieldCandidates.first { $0.key == "session-number" }?.matchingFieldIsEnabled, false)
    }
}

final class ImportFieldWritingTests: XCTestCase {
    private let body = "Session number: 4\nDuration: 50 minutes\n\nSarah arrived on time."

    private func plan(accepting: [String: ImportFieldDecision]) -> ImportPlan {
        var settings = NoteFieldSettings.default
        settings.setEnabled(true, forKey: "session-number")

        var plan = ImportPlan.make(
            results: [ImportFileResult(
                file: "n.txt",
                format: .plainText,
                items: [ImportedItem(
                    origin: ImportOrigin(container: "n.txt"),
                    groupKey: "Sarah Mitchell",
                    date: .found(Fixture.date("2026-06-14T09:30:00Z"), raw: "t"),
                    body: body
                )],
                table: nil,
                issues: []
            )],
            existingClients: [],
            noteFields: settings,
            options: options
        )
        plan.assign(Fixture.code("SM2"), toGroup: "Sarah Mitchell")
        for (key, decision) in accepting { plan.setFieldDecision(decision, forKey: key) }
        return plan
    }

    /// The whole point: a session number written as a line of prose becomes a value on the
    /// field the counsellor already uses for it.
    func testAnAcceptedFieldBecomesANoteHeader() throws {
        let (store, _, _) = Fixture.store()
        let report = ImportRunner.run(plan: plan(accepting: [:]), store: store, now: fixedNow)
        let filename = try XCTUnwrap(report.outcomes.first?.filename)
        let note = try store.readNote(client: Fixture.code("SM2"), filename: filename)

        XCTAssertEqual(note.extraHeaders["session-number"], "4")
        XCTAssertFalse(note.body.contains("Session number"))
        // Not chosen, so left exactly where it was.
        XCTAssertTrue(note.body.contains("Duration: 50 minutes"))
    }

    func testADeclinedFieldStaysInTheNote() throws {
        let (store, _, _) = Fixture.store()
        let report = ImportRunner.run(
            plan: plan(accepting: ["session-number": .leaveInNote]),
            store: store,
            now: fixedNow
        )
        let filename = try XCTUnwrap(report.outcomes.first?.filename)
        let note = try store.readNote(client: Fixture.code("SM2"), filename: filename)

        XCTAssertNil(note.extraHeaders["session-number"])
        XCTAssertTrue(note.body.contains("Session number: 4"))
    }

    func testANewlyAddedFieldCanBeStoredToo() throws {
        let (store, _, _) = Fixture.store()
        let report = ImportRunner.run(
            plan: plan(accepting: ["duration": .store(fieldKey: "duration")]),
            store: store,
            now: fixedNow
        )
        let filename = try XCTUnwrap(report.outcomes.first?.filename)
        let note = try store.readNote(client: Fixture.code("SM2"), filename: filename)

        XCTAssertEqual(note.extraHeaders["duration"], "50 minutes")
        XCTAssertEqual(note.extraHeaders["session-number"], "4")
        XCTAssertEqual(note.body, "SM2 arrived on time.")
    }

    /// A field value is as capable of holding a name as the note is.
    func testNamesAreReplacedInFieldValuesToo() throws {
        let (store, _, _) = Fixture.store()
        var built = plan(accepting: ["room": .store(fieldKey: "room")])
        built.groups[0].items = [ImportedItem(
            origin: ImportOrigin(container: "n.txt"),
            groupKey: "Sarah Mitchell",
            date: .found(Fixture.date("2026-06-14T09:30:00Z"), raw: "t"),
            body: "Room: Sarah's front room\n\nA home visit."
        )]

        let report = ImportRunner.run(plan: built, store: store, now: fixedNow)
        let filename = try XCTUnwrap(report.outcomes.first?.filename)
        let note = try store.readNote(client: Fixture.code("SM2"), filename: filename)
        XCTAssertEqual(note.extraHeaders["room"], "SM2's front room")
    }
}
