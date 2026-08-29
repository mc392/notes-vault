import XCTest
import NotesVaultCore
@testable import NotesVaultCrypto

/// End-to-end tests with the real cryptography, against a real folder on disk.
///
/// The core tests use a stub engine, which proves the layout logic and nothing about the
/// bytes. These use `CryptomatorEngine`, `MasterkeyFile` and a real `FileSystemVaultStore`,
/// so a wrong directory hash, an unsigned vault config or a masterkey that cannot be
/// unwrapped fails here — on a CI runner, not on a counsellor's phone.
///
/// They are slow by design: every vault creation is two scrypt derivations at the
/// production cost parameter. Lowering it for tests would mean testing something other than
/// what ships.
final class VaultIntegrationTests: XCTestCase {
    private var root: URL!
    private var files: FileSystemVaultStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notesvault-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Not security scoped: this is a plain temp folder, not something the document
        // picker handed us.
        files = try FileSystemVaultStore(root: root, securityScoped: false)
    }

    override func tearDownWithError() throws {
        files = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func makeVault(passphrase: String = "correct horse battery staple") throws -> (session: VaultSession, recoveryKey: RecoveryKey) {
        try VaultBootstrap.createVault(in: files, passphrase: passphrase)
    }

    private func store(_ session: VaultSession) -> VaultStore {
        VaultStore(engine: session.engine, files: files, deviceName: "mac")
    }

    /// Every file under the vault root, as (relative path, bytes).
    private func everythingOnDisk() throws -> [(path: String, data: Data)] {
        var found: [(String, Data)] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = url.path.replacingOccurrences(of: root.path, with: "")
            found.append((relative, (try? Data(contentsOf: url)) ?? Data()))
        }
        return found
    }

    // MARK: - Creating

    func testCreatesARecognisableFormat8Vault() throws {
        _ = try makeVault()

        XCTAssertTrue(VaultBootstrap.isVault(files))
        XCTAssertTrue(VaultBootstrap.hasRecoveryKey(files))
        XCTAssertTrue(files.fileExists(at: [VaultLayout.masterkeyFilename]))
        XCTAssertTrue(files.fileExists(at: [VaultLayout.vaultConfigFilename]))
        XCTAssertTrue(files.directoryExists(at: [VaultLayout.dataDirectory]))

        let configuration = try VaultBootstrap.decodeConfiguration(try files.read(at: [VaultLayout.vaultConfigFilename]))
        XCTAssertEqual(configuration.format, 8)
        XCTAssertEqual(configuration.cipherCombo, "SIV_GCM")
        XCTAssertEqual(configuration.shorteningThreshold, VaultLayout.shorteningThreshold)
        XCTAssertFalse(configuration.jti.isEmpty)
    }

    func testRefusesToCreateASecondVaultOverTheFirst() throws {
        _ = try makeVault()
        XCTAssertThrowsError(try makeVault())
    }

    /// The root data directory is sharded two characters deep, which is what Cryptomator's
    /// own clients expect to find.
    func testRootDirectoryIsShardedTheWayTheFormatRequires() throws {
        let created = try makeVault()
        let shards = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent(VaultLayout.dataDirectory).path
        )
        XCTAssertEqual(shards.count, 1)
        XCTAssertEqual(shards.first?.count, 2)

        let layout = VaultLayout(engine: created.session.engine)
        let rootPath = try layout.rootPath()
        XCTAssertEqual(rootPath[1].count, 2)
        XCTAssertEqual(rootPath[2].count, 30)
    }

    // MARK: - Unlocking

    func testOpensWithTheRightPassphraseAndRefusesTheWrongOne() throws {
        _ = try makeVault(passphrase: "a passphrase worth typing")

        XCTAssertNoThrow(try VaultBootstrap.open(files, passphrase: "a passphrase worth typing"))
        XCTAssertThrowsError(try VaultBootstrap.open(files, passphrase: "nearly right")) { error in
            XCTAssertEqual(error as? VaultError, .wrongPassphrase)
        }
    }

    func testOpensWithTheRecoveryKey() throws {
        let created = try makeVault()
        XCTAssertNoThrow(try VaultBootstrap.open(files, recoveryKey: created.recoveryKey))
    }

    func testARecoveryKeyFromADifferentVaultDoesNotOpenThisOne() throws {
        _ = try makeVault()
        XCTAssertThrowsError(try VaultBootstrap.open(files, recoveryKey: RecoveryKey()))
    }

    /// A tampered vault config must fail rather than be obeyed — the config names the
    /// cipher, so an attacker who could edit it unchallenged could ask for a weaker one.
    func testATamperedVaultConfigIsRejected() throws {
        _ = try makeVault(passphrase: "a passphrase worth typing")

        let original = try XCTUnwrap(String(data: try files.read(at: [VaultLayout.vaultConfigFilename]), encoding: .utf8))
        var segments = original.split(separator: ".").map(String.init)
        XCTAssertEqual(segments.count, 3)
        // Corrupt the *first* character of the signature, not the last. A 32-byte HMAC is
        // 43 base64url characters, and the final one carries two padding bits that decode
        // to nothing — flipping those would leave the signature bytes identical and the
        // test would pass while proving nothing.
        let signature = Array(segments[2])
        segments[2] = (signature.first == "A" ? "B" : "A") + String(signature.dropFirst())
        try files.write(Data(segments.joined(separator: ".").utf8), at: [VaultLayout.vaultConfigFilename], overwrite: true)

        XCTAssertThrowsError(try VaultBootstrap.open(files, passphrase: "a passphrase worth typing"))
    }

    // MARK: - Passphrase and recovery management

    /// The property that matters most about the recovery design: changing the passphrase
    /// must not invalidate the piece of paper in the counsellor's safe.
    func testChangingThePassphraseLeavesTheRecoveryKeyWorking() throws {
        let created = try makeVault(passphrase: "first passphrase here")

        try VaultBootstrap.changePassphrase(in: files, current: "first passphrase here", new: "second passphrase here")

        XCTAssertThrowsError(try VaultBootstrap.open(files, passphrase: "first passphrase here"))
        XCTAssertNoThrow(try VaultBootstrap.open(files, passphrase: "second passphrase here"))
        XCTAssertNoThrow(try VaultBootstrap.open(files, recoveryKey: created.recoveryKey))
    }

    func testRecoveryKeySetsANewPassphraseAndTheNotesSurvive() throws {
        let created = try makeVault(passphrase: "the forgotten one")
        let code = try ClientCode("SM2")
        _ = try store(created.session).write(note: NoteRecord(
            client: code,
            session: Date(),
            device: "mac",
            body: "Written before the passphrase was lost."
        ))

        try VaultBootstrap.resetPassphrase(in: files, recoveryKey: created.recoveryKey, newPassphrase: "the replacement one")

        let reopened = try VaultBootstrap.open(files, passphrase: "the replacement one")
        let rebuilt = try store(reopened).rebuildIndex()
        XCTAssertEqual(rebuilt.index.notes.count, 1)
        XCTAssertTrue(rebuilt.issues.isEmpty)

        let entry = try XCTUnwrap(rebuilt.index.notes.first)
        let note = try store(reopened).readNote(client: code, filename: entry.filename)
        XCTAssertEqual(note.body, "Written before the passphrase was lost.")
    }

    func testReissuingARecoveryKeyRetiresTheOldOne() throws {
        let created = try makeVault(passphrase: "a passphrase worth typing")

        let replacement = try VaultBootstrap.regenerateRecoveryKey(in: files, passphrase: "a passphrase worth typing")

        XCTAssertNotEqual(replacement.entropy, created.recoveryKey.entropy)
        XCTAssertNoThrow(try VaultBootstrap.open(files, recoveryKey: replacement))
        XCTAssertThrowsError(try VaultBootstrap.open(files, recoveryKey: created.recoveryKey))
    }

    // MARK: - Notes, for real

    func testANoteSurvivesBeingClosedAndReopened() throws {
        let created = try makeVault()
        let code = try ClientCode("SM2")
        let written = NoteRecord(
            client: code,
            session: Date(),
            device: "mac",
            template: .soap,
            body: "Presented flat. Agreed to try the sleep diary again."
        )
        let filename = try store(created.session).write(note: written)

        // Drop the session entirely and come back to the folder cold, the way a second
        // launch does.
        let reopened = try VaultBootstrap.open(files, passphrase: "correct horse battery staple")
        let readBack = try store(reopened).readNote(client: code, filename: filename)

        XCTAssertEqual(readBack.id, written.id)
        XCTAssertEqual(readBack.body, written.body)
        XCTAssertEqual(readBack.template, .soap)
    }

    /// The whole promise of the product, asserted against real bytes on a real disk.
    func testNothingIdentifyingReachesTheFolder() throws {
        let created = try makeVault()
        let code = try ClientCode("SM2")
        _ = try store(created.session).write(note: NoteRecord(
            client: code,
            session: Fixture.date("2026-06-14T09:30:00Z"),
            device: "mac",
            body: "Discussed the bereavement and the anniversary coming up."
        ))

        let needles = ["SM2", "2026-06-14", "bereavement", "anniversary", "notesvault/1"]
        for (path, data) in try everythingOnDisk() {
            let text = String(data: data, encoding: .utf8) ?? ""
            for needle in needles {
                XCTAssertFalse(path.contains(needle), "\"\(needle)\" appears in the path \(path)")
                XCTAssertFalse(text.contains(needle), "\"\(needle)\" appears inside \(path)")
            }
        }
    }

    func testTheIndexCanBeRebuiltFromTheFolderAlone() throws {
        let created = try makeVault()
        let store = store(created.session)
        let code = try ClientCode("AB1")

        _ = try store.write(note: NoteRecord(client: code, session: Fixture.date("2026-05-01T09:00:00Z"), device: "mac", body: "One."))
        _ = try store.write(note: NoteRecord(client: code, session: Fixture.date("2026-05-08T09:00:00Z"), device: "mac", body: "Two."))
        try store.write(event: ClientMetadataEvent(client: code, device: "mac", status: .ended))

        let reopened = try VaultBootstrap.open(files, passphrase: "correct horse battery staple")
        let rebuilt = try self.store(reopened).rebuildIndex()

        XCTAssertTrue(rebuilt.issues.isEmpty, "\(rebuilt.issues)")
        XCTAssertEqual(rebuilt.index.notes.count, 2)
        XCTAssertEqual(rebuilt.index.client(code)?.status, .ended)
        XCTAssertEqual(rebuilt.index.client(code)?.lastContact, Fixture.date("2026-05-08T09:00:00Z"))
    }

    func testExportProducesReadablePlainText() throws {
        let created = try makeVault()
        let code = try ClientCode("SM2")
        _ = try store(created.session).write(note: NoteRecord(
            client: code,
            session: Fixture.date("2026-06-14T09:30:00Z"),
            device: "mac",
            body: "Readable afterwards, on any machine, forever."
        ))

        var exported: [String: String] = [:]
        let issues = try store(created.session).exportPlaintext { components, data in
            exported[components.joined(separator: "/")] = String(data: data, encoding: .utf8)
        }

        XCTAssertTrue(issues.isEmpty)
        let only = try XCTUnwrap(exported.first)
        XCTAssertTrue(only.key.hasPrefix("SM2/"))
        XCTAssertTrue(only.value.contains("Readable afterwards"))
        XCTAssertTrue(only.value.hasPrefix("notesvault/1"))
    }
}

enum Fixture {
    static func date(_ iso: String) -> Date {
        guard let date = VaultDate.parse(iso) else { fatalError("bad fixture date \(iso)") }
        return date
    }
}
