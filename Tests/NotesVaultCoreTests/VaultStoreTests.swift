import XCTest
@testable import NotesVaultCore

final class VaultLayoutTests: XCTestCase {
    private let layout = VaultLayout(engine: TransparentEngine())

    func testRootShardsIntoTwoCharactersAndThirty() throws {
        let path = try layout.rootPath()
        XCTAssertEqual(path.count, 3)
        XCTAssertEqual(path[0], "d")
        XCTAssertEqual(path[1].count, 2)
        XCTAssertEqual(path[2].count, 30)
    }

    func testDifferentDirectoriesLandInDifferentPlaces() throws {
        let a = try layout.directoryPath(for: Data("one".utf8))
        let b = try layout.directoryPath(for: Data("two".utf8))
        XCTAssertNotEqual(a, b)
    }

    func testNamesRoundTrip() throws {
        let stored = try layout.ciphertextName(for: "2026-06-14T0930-mac.note", in: VaultLayout.rootDirectoryID)
        XCTAssertTrue(stored.hasSuffix(".c9r"))
        XCTAssertEqual(
            layout.cleartextName(for: stored, in: VaultLayout.rootDirectoryID),
            "2026-06-14T0930-mac.note"
        )
    }

    /// Foreign files in the vault folder — a `.DS_Store`, a sync conflict copy, a `.c9s`
    /// name written by Cryptomator itself — must be skipped, not crash a listing.
    func testForeignNamesAreSkippedNotFatal() {
        XCTAssertNil(layout.cleartextName(for: ".DS_Store", in: VaultLayout.rootDirectoryID))
        XCTAssertNil(layout.cleartextName(for: "something.c9s", in: VaultLayout.rootDirectoryID))
        XCTAssertNil(layout.cleartextName(for: ".c9r", in: VaultLayout.rootDirectoryID))
    }

    func testRefusesANameTooLongForTheVault() {
        let huge = String(repeating: "A", count: 400)
        XCTAssertThrowsError(try layout.ciphertextName(for: huge, in: VaultLayout.rootDirectoryID))
    }
}

final class VaultStoreTests: XCTestCase {
    private func note(_ client: String, _ session: String, device: String = "mac", body: String = "Body.", supersedes: NoteID? = nil) -> NoteRecord {
        NoteRecord(
            client: Fixture.code(client),
            session: Fixture.date(session),
            sessionUTCOffset: 0,
            device: device,
            supersedes: supersedes,
            body: body
        )
    }

    func testWritesAndReadsBackANote() throws {
        let (store, _, _) = Fixture.store()
        let original = note("SM2", "2026-06-14T09:30:00Z")

        let filename = try store.write(note: original)
        XCTAssertEqual(filename, "2026-06-14T0930-mac.note")

        let readBack = try store.readNote(client: Fixture.code("SM2"), filename: filename)
        XCTAssertEqual(readBack.id, original.id)
        XCTAssertEqual(readBack.body, "Body.")
    }

    /// Nothing readable may reach the folder. If the store ever wrote a note without going
    /// through the engine, this is what catches it.
    func testNothingIsStoredInTheClear() throws {
        let (store, files, _) = Fixture.store()
        _ = try store.write(note: note("SM2", "2026-06-14T09:30:00Z", body: "Discussed bereavement."))

        for (path, data) in files.files {
            let text = String(data: data, encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains("Discussed bereavement"), "note text found in \(path)")
            XCTAssertFalse(path.contains("SM2"), "client code found in the path \(path)")
            XCTAssertFalse(path.contains("2026-06-14"), "session date found in the path \(path)")
        }
    }

    /// Principle 04. Two notes for one client, one device, one minute must produce two
    /// files — this is the case a naive implementation silently overwrites.
    func testNeverOverwritesAnExistingNote() throws {
        let (store, _, _) = Fixture.store()
        let first = try store.write(note: note("SM2", "2026-06-14T09:30:00Z", body: "First."))
        let second = try store.write(note: note("SM2", "2026-06-14T09:30:00Z", body: "Second."))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try store.readNote(client: Fixture.code("SM2"), filename: first).body, "First.")
        XCTAssertEqual(try store.readNote(client: Fixture.code("SM2"), filename: second).body, "Second.")
        // Both are on disk: the second write added a file rather than replacing one.
        let listed = try store.listFilenames(for: Fixture.code("SM2")).notes
        XCTAssertEqual(Set(listed), [first, second])
    }

    func testTwoDevicesDoNotCollide() throws {
        let (store, _, _) = Fixture.store()
        let onMac = try store.write(note: note("SM2", "2026-06-14T09:30:00Z", device: "mac"))
        let onPhone = try store.write(note: note("SM2", "2026-06-14T09:30:00Z", device: "iphone"))
        XCTAssertEqual(onMac, "2026-06-14T0930-mac.note")
        XCTAssertEqual(onPhone, "2026-06-14T0930-iphone.note")
    }

    func testListsClientsItHasCreated() throws {
        let (store, _, _) = Fixture.store()
        _ = try store.write(note: note("SM2", "2026-06-14T09:30:00Z"))
        _ = try store.write(note: note("AB1", "2026-06-15T09:30:00Z"))

        let listing = try store.listClientCodes()
        XCTAssertEqual(listing.codes.map(\.rawValue), ["AB1", "SM2"])
        XCTAssertTrue(listing.issues.isEmpty)
    }

    func testClientFolderIsReusedNotRecreated() throws {
        let (store, _, _) = Fixture.store()
        let first = try store.ensureClient(Fixture.code("SM2"))
        let second = try store.ensureClient(Fixture.code("SM2"))
        XCTAssertEqual(first, second)
    }

    func testMetadataFoldsToTheLatestWrite() throws {
        let (store, _, _) = Fixture.store()
        let code = Fixture.code("SM2")

        try store.write(event: ClientMetadataEvent(
            client: code, written: Fixture.date("2026-01-01T00:00:00Z"),
            device: "mac", status: .active
        ))
        try store.write(event: ClientMetadataEvent(
            client: code, written: Fixture.date("2026-06-01T00:00:00Z"),
            device: "iphone", status: .ended, retentionBasis: .adult
        ))

        let current = try store.currentMetadata(for: code)
        XCTAssertEqual(current?.status, .ended)
        XCTAssertEqual(current?.device, "iphone")
    }

    func testRebuildsTheIndexFromTheVaultAlone() throws {
        let (store, _, _) = Fixture.store()
        _ = try store.write(note: note("SM2", "2026-05-01T09:30:00Z"))
        _ = try store.write(note: note("SM2", "2026-06-01T09:30:00Z"))
        _ = try store.write(note: note("AB1", "2026-06-02T09:30:00Z"))
        try store.write(event: ClientMetadataEvent(client: Fixture.code("SM2"), device: "mac", status: .ended))

        let result = try store.rebuildIndex()
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.index.notes.count, 3)
        XCTAssertEqual(result.index.clients.count, 2)

        let sm2 = result.index.client(Fixture.code("SM2"))
        XCTAssertEqual(sm2?.noteCount, 2)
        XCTAssertEqual(sm2?.status, .ended)
        XCTAssertEqual(sm2?.lastContact, Fixture.date("2026-06-01T09:30:00Z"))
        XCTAssertEqual(sm2?.firstContact, Fixture.date("2026-05-01T09:30:00Z"))
    }

    /// A client whose metadata file is missing — created by writing a note and nothing else
    /// — must still be listed. A missing metadata file making notes invisible would be the
    /// worst failure mode available here.
    func testAClientWithNoMetadataIsStillListed() throws {
        let (store, _, _) = Fixture.store()
        _ = try store.write(note: note("SM2", "2026-06-14T09:30:00Z"))

        let result = try store.rebuildIndex()
        XCTAssertEqual(result.index.client(Fixture.code("SM2"))?.status, .active)
        XCTAssertEqual(result.index.client(Fixture.code("SM2"))?.noteCount, 1)
    }

    /// One damaged file must not take the other notes with it.
    func testADamagedFileIsReportedAndTheRestStillLoad() throws {
        let (store, files, engine) = Fixture.store()
        let code = Fixture.code("SM2")
        let doomed = try store.write(note: note("SM2", "2026-06-01T09:30:00Z"))
        _ = try store.write(note: note("SM2", "2026-06-08T09:30:00Z"))

        // Damage one specific note, addressed the same way the store addresses it, so the
        // test cannot accidentally corrupt the directory marker instead.
        let layout = VaultLayout(engine: engine)
        let directoryID = try XCTUnwrap(try store.directoryID(for: code))
        let path = try layout.filePath(named: doomed, in: directoryID)
        try files.write(Data("not a note at all".utf8), at: path, overwrite: true)

        let result = try store.rebuildIndex()
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.index.notes.count, 1)
        XCTAssertEqual(result.index.client(code)?.noteCount, 1)
    }

    func testExportsEveryNoteAsPlainText() throws {
        let (store, _, _) = Fixture.store()
        _ = try store.write(note: note("SM2", "2026-06-01T09:30:00Z", body: "Session one."))
        _ = try store.write(note: note("AB1", "2026-06-02T09:30:00Z", body: "Session two."))

        var exported: [String: String] = [:]
        let issues = try store.exportPlaintext { components, data in
            exported[components.joined(separator: "/")] = String(data: data, encoding: .utf8)
        }

        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(exported.count, 2)
        XCTAssertEqual(exported["SM2/2026-06-01T0930-mac.note"]?.contains("Session one."), true)
        XCTAssertEqual(exported["AB1/2026-06-02T0930-mac.note"]?.contains("Session two."), true)
    }

    func testDestroyingAClientLeavesTheOthersAlone() throws {
        let (store, _, _) = Fixture.store()
        _ = try store.write(note: note("SM2", "2026-06-01T09:30:00Z"))
        _ = try store.write(note: note("AB1", "2026-06-02T09:30:00Z"))

        try store.destroyEverything(for: Fixture.code("SM2"))

        let result = try store.rebuildIndex()
        XCTAssertEqual(result.index.clients.map(\.code.rawValue), ["AB1"])
        XCTAssertEqual(result.index.notes.count, 1)
    }
}

final class VaultIndexTests: XCTestCase {
    private func entry(_ client: String, _ session: String, id: NoteID = NoteID(), supersedes: NoteID? = nil) -> (note: NoteRecord, filename: String) {
        let note = NoteRecord(
            id: id,
            client: Fixture.code(client),
            session: Fixture.date(session),
            sessionUTCOffset: 0,
            device: "mac",
            supersedes: supersedes,
            body: "Body."
        )
        return (note, note.preferredFilename)
    }

    /// A correction hides the note it replaces from the timeline, but nothing is deleted
    /// and the earlier note is still there to be shown on request.
    func testCorrectionsHideTheirOriginalWithoutLosingIt() {
        let originalID = NoteID(generatedAt: Fixture.date("2026-06-01T10:00:00Z"))
        let index = VaultIndex.build(
            notes: [
                entry("SM2", "2026-06-01T09:30:00Z", id: originalID),
                entry("SM2", "2026-06-01T09:30:00Z", supersedes: originalID)
            ],
            clientEvents: [:]
        )

        XCTAssertEqual(index.notes(for: Fixture.code("SM2")).count, 2)
        XCTAssertEqual(index.currentNotes(for: Fixture.code("SM2")).count, 1)
        XCTAssertEqual(index.client(Fixture.code("SM2"))?.noteCount, 1)
        XCTAssertEqual(index.client(Fixture.code("SM2"))?.supersededCount, 1)
        XCTAssertEqual(index.corrections(of: originalID).count, 1)
    }

    /// The retention clock counts from the recorded last contact when the work ended with a
    /// phone call that produced no note.
    func testLastContactOverrideWinsWhenItIsLater() {
        let event = ClientMetadataEvent(
            client: Fixture.code("SM2"),
            device: "mac",
            status: .ended,
            lastContactOverride: Fixture.date("2026-07-01T00:00:00Z")
        )
        let index = VaultIndex.build(
            notes: [entry("SM2", "2026-06-01T09:30:00Z")],
            clientEvents: [Fixture.code("SM2"): event]
        )
        XCTAssertEqual(index.client(Fixture.code("SM2"))?.lastContact, Fixture.date("2026-07-01T00:00:00Z"))
    }

    /// ...and never *shortens* it. An override earlier than the last logged session would
    /// otherwise bring a destruction date forward.
    func testLastContactOverrideNeverShortensTheClock() {
        let event = ClientMetadataEvent(
            client: Fixture.code("SM2"),
            device: "mac",
            status: .ended,
            lastContactOverride: Fixture.date("2020-01-01T00:00:00Z")
        )
        let index = VaultIndex.build(
            notes: [entry("SM2", "2026-06-01T09:30:00Z")],
            clientEvents: [Fixture.code("SM2"): event]
        )
        XCTAssertEqual(index.client(Fixture.code("SM2"))?.lastContact, Fixture.date("2026-06-01T09:30:00Z"))
    }

    func testSearchMatchesCodesOnly() {
        let index = VaultIndex.build(
            notes: [entry("SM2", "2026-06-01T09:30:00Z"), entry("AB1", "2026-06-01T09:30:00Z")],
            clientEvents: [:]
        )
        XCTAssertEqual(index.searchClients("sm").map(\.code.rawValue), ["SM2"])
        XCTAssertEqual(index.searchClients("").count, 2)
    }

    func testAClientWithOnlyMetadataStillAppears() {
        let event = ClientMetadataEvent(client: Fixture.code("NEW1"), device: "mac", status: .active)
        let index = VaultIndex.build(notes: [], clientEvents: [Fixture.code("NEW1"): event])
        XCTAssertEqual(index.clients.map(\.code.rawValue), ["NEW1"])
        XCTAssertEqual(index.clients.first?.noteCount, 0)
        XCTAssertNil(index.clients.first?.lastContact)
    }
}
