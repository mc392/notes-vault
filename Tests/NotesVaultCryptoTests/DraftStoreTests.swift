import XCTest
import CryptoKit
import NotesVaultCore
@testable import NotesVaultCrypto

/// The autosaved-draft store, against a real folder and a fixed key.
///
/// The key is injected rather than fetched: `KeychainStore` prompts, needs an entitled
/// process and would leave items behind on whichever machine ran the tests, none of which
/// belongs in a test run. What is *not* stubbed is the encryption — these write real sealed
/// boxes to a real disk, which is the only way the "no plaintext on disk" check below means
/// anything.
final class DraftStoreTests: XCTestCase {
    private var directory: URL!
    private var store: DraftStore!

    private let key = SymmetricKey(data: Data(repeating: 0x2b, count: 32))
    private let vaultID = "vault-one"
    private let otherVaultID = "vault-two"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notesvault-drafts")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DraftStore(directory: directory, key: { [key] _ in key })
    }

    override func tearDownWithError() throws {
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // Whole seconds: the draft round-trips through ISO 8601, which does not carry
    // fractions, so a `Date()` here would fail an equality check for the wrong reason.
    private let session = Date(timeIntervalSince1970: 1_780_000_000)
    private let saved = Date(timeIntervalSince1970: 1_780_003_600)

    private func draft(
        client: String = "SM2",
        correcting: NoteID? = nil,
        body: String = "Discussed the bereavement anniversary approaching next fortnight."
    ) throws -> NoteDraft {
        NoteDraft(
            client: try ClientCode(client),
            correcting: correcting,
            body: body,
            sessionDate: session,
            template: .soap,
            fieldValues: ["session-number": "7", "location": "Room 2"],
            savedAt: saved
        )
    }

    private func filesOnDisk() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    // MARK: - Round trip

    func testSavedDraftLoadsBackUnchanged() throws {
        let original = try draft()
        XCTAssertTrue(store.save(original, vaultID: vaultID))

        let loaded = store.load(vaultID: vaultID, client: original.client, correcting: nil)
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded?.template, .soap)
    }

    func testClearRemovesTheDraft() throws {
        let original = try draft()
        store.save(original, vaultID: vaultID)

        store.clear(vaultID: vaultID, client: original.client, correcting: nil)

        XCTAssertNil(store.load(vaultID: vaultID, client: original.client, correcting: nil))
        XCTAssertEqual(try filesOnDisk().count, 0)
    }

    func testADraftBelongsToOneClientOneVaultAndOneCorrection() throws {
        let original = try draft()
        store.save(original, vaultID: vaultID)

        XCTAssertNil(store.load(vaultID: vaultID, client: try ClientCode("JT9"), correcting: nil))
        XCTAssertNil(store.load(vaultID: otherVaultID, client: original.client, correcting: nil))
        // A correction to one of this client's notes is separate work from a new note for
        // them, so it must not read back the new note's draft.
        XCTAssertNil(store.load(vaultID: vaultID, client: original.client, correcting: NoteID()))
    }

    func testNewNoteAndCorrectionDraftsCoexist() throws {
        let correctedNote = NoteID()
        let fresh = try draft(body: "New note, not yet filed.")
        let correction = try draft(correcting: correctedNote, body: "Correction: the referral came from the GP.")

        store.save(fresh, vaultID: vaultID)
        store.save(correction, vaultID: vaultID)

        XCTAssertEqual(store.load(vaultID: vaultID, client: fresh.client, correcting: nil), fresh)
        XCTAssertEqual(store.load(vaultID: vaultID, client: fresh.client, correcting: correctedNote), correction)
    }

    // MARK: - What lands on disk

    func testTheStoredFileHoldsNoPlaintext() throws {
        let original = try draft()
        store.save(original, vaultID: vaultID)

        let files = try filesOnDisk()
        XCTAssertEqual(files.count, 1)
        let ciphertext = try Data(contentsOf: try XCTUnwrap(files.first))

        XCTAssertTrue(CiphertextCheck.holdsNoPlaintext(of: Data(original.body.utf8), in: ciphertext))
        XCTAssertFalse(ciphertext.isEmpty)
    }

    func testTheFilenameCarriesNoClientCode() throws {
        let original = try draft(client: "SM2")
        store.save(original, vaultID: vaultID)

        let name = try XCTUnwrap(try filesOnDisk().first).lastPathComponent
        XCTAssertFalse(name.contains("SM2"))
        // The vault's own random identifier is there on purpose — it is what makes
        // `clearAll` possible, and it says nothing about the counsellor or their clients.
        XCTAssertTrue(name.hasPrefix("\(vaultID)-"))
    }

    // MARK: - Destroying

    func testClearAllLeavesNothingForThatVault() throws {
        let first = try draft(client: "SM2")
        let second = try draft(client: "JT9")
        let elsewhere = try draft(client: "SM2", body: "A draft in another vault entirely.")
        store.save(first, vaultID: vaultID)
        store.save(second, vaultID: vaultID)
        store.save(elsewhere, vaultID: otherVaultID)

        store.clearAll(vaultID: vaultID)

        XCTAssertNil(store.load(vaultID: vaultID, client: first.client, correcting: nil))
        XCTAssertNil(store.load(vaultID: vaultID, client: second.client, correcting: nil))
        // Another vault's drafts are not this vault's business.
        XCTAssertEqual(store.load(vaultID: otherVaultID, client: elsewhere.client, correcting: nil), elsewhere)
    }

    // MARK: - No key

    /// The constraint that matters most: with no index key there is no plaintext fallback.
    /// The draft is held in memory for the rest of the run and the disk stays empty.
    func testWithoutAKeyNothingIsWrittenToDisk() throws {
        let keyless = DraftStore(directory: directory, key: { _ in nil })
        let original = try draft(body: "Held in memory because the keychain would not answer.")

        XCTAssertFalse(keyless.save(original, vaultID: vaultID))

        XCTAssertEqual(try filesOnDisk().count, 0)
        XCTAssertEqual(keyless.load(vaultID: vaultID, client: original.client, correcting: nil), original)

        keyless.clear(vaultID: vaultID, client: original.client, correcting: nil)
        XCTAssertNil(keyless.load(vaultID: vaultID, client: original.client, correcting: nil))
    }
}
