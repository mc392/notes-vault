import XCTest
import NotesVaultCore
@testable import NotesVaultCrypto

/// Remembering GroundWork's schedule file, against real files on disk.
///
/// The bug these were written for cannot be reproduced off a device — it was the sandbox
/// refusing a URL whose security scope nobody had opened, and a test process is not
/// sandboxed. What *can* be pinned down here is everything around it: that a chosen file
/// survives to the next launch, that a file which has gone is reported as a schedule file
/// rather than as the vault, and that an unreadable choice never replaces a good one.
final class RosterBookmarkTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var savedDefaults: [String: Any] = [:]

    private static let keys = ["roster.bookmark", "roster.displayName", "roster.lastSync"]

    private let sample = Data("""
    {"app":"GroundWork","kind":"schedules","version":1,
     "clients":[{"code":"AA","status":"active","cadenceDays":7,"usualDay":"wed","usualTime":"10:00"}]}
    """.utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        for key in Self.keys {
            if let value = UserDefaults.standard.object(forKey: key) { savedDefaults[key] = value }
        }
        RosterBookmark.clear()

        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notesvault-roster")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("groundwork-schedules.json")
        try sample.write(to: file)
    }

    override func tearDownWithError() throws {
        RosterBookmark.clear()
        for (key, value) in savedDefaults { UserDefaults.standard.set(value, forKey: key) }
        savedDefaults = [:]
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    func testChosenFileIsRememberedAndResolvesBack() throws {
        try RosterBookmark.store(file)

        XCTAssertTrue(RosterBookmark.exists)
        XCTAssertEqual(RosterBookmark.storedDisplayName, "groundwork-schedules.json")

        let resolved = try XCTUnwrap(RosterBookmark.resolve())
        // Not URL equality: /var is a symlink to /private/var on macOS, so the resolved
        // URL is the same file by a different spelling.
        XCTAssertEqual(resolved.lastPathComponent, file.lastPathComponent)
        XCTAssertEqual(try RosterBookmark.read(resolved), sample)
    }

    func testWhatIsReadBackIsAGroundWorkRoster() throws {
        try RosterBookmark.store(file)
        let url = try XCTUnwrap(RosterBookmark.resolve())

        let roster = try ScheduleRoster.parse(try RosterBookmark.read(url))
        XCTAssertEqual(roster.entries.map(\.code.rawValue), ["AA"])
        XCTAssertEqual(roster.entries.first?.schedule?.cadenceDays, 7)
    }

    func testNothingChosenResolvesToNil() throws {
        XCTAssertNil(try RosterBookmark.resolve())
        XCTAssertFalse(RosterBookmark.exists)
    }

    /// A file deleted between one sync and the next is a schedule-file problem, and saying
    /// "the vault folder can't be reached" would tell a counsellor their notes were gone.
    func testAMissingFileIsReportedAsTheScheduleFile() throws {
        try RosterBookmark.store(file)
        let url = try XCTUnwrap(RosterBookmark.resolve())
        try FileManager.default.removeItem(at: file)

        XCTAssertThrowsError(try RosterBookmark.read(url, downloadTimeout: 0)) { error in
            guard let vaultError = error as? VaultError,
                  case let .scheduleFileUnavailable(detail) = vaultError else {
                return XCTFail("expected a schedule-file error, got \(error)")
            }
            XCTAssertTrue(detail.contains("no longer there"), detail)
        }
    }

    func testAFileThatIsNotThereIsNotRememberedOverOneThatIs() throws {
        try RosterBookmark.store(file)

        let missing = directory.appendingPathComponent("not-here.json")
        XCTAssertThrowsError(try RosterBookmark.store(missing))

        // The good choice survives the bad one: a failed pick must not leave the sync
        // screen pointing at a file that was never readable.
        XCTAssertEqual(RosterBookmark.storedDisplayName, "groundwork-schedules.json")
        let resolved = try XCTUnwrap(RosterBookmark.resolve())
        XCTAssertEqual(try RosterBookmark.read(resolved), sample)
    }

    func testLastSyncRoundTripsAndClears() {
        XCTAssertNil(RosterBookmark.lastSync)
        let when = Date(timeIntervalSince1970: 1_780_000_000)
        RosterBookmark.lastSync = when
        XCTAssertEqual(RosterBookmark.lastSync?.timeIntervalSince1970, when.timeIntervalSince1970)

        RosterBookmark.clear()
        XCTAssertNil(RosterBookmark.lastSync)
    }
}
