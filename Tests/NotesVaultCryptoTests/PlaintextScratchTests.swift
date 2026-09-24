import XCTest
@testable import NotesVaultCrypto

final class PlaintextScratchTests: XCTestCase {
    /// A run killed mid-encryption leaves its scratch directory behind. The next launch
    /// shreds it rather than leaving plaintext in the temporary folder.
    func testLeftoverPlaintextIsSweptAtLaunch() throws {
        let leftover = FileManager.default.temporaryDirectory
            .appendingPathComponent("notesvault-scratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("Discussed the anniversary of the bereavement.".utf8)
            .write(to: leftover.appendingPathComponent("in"))

        PlaintextScratch.sweepLeftovers()

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    /// The ordinary path still cleans up after itself, so the sweep is only ever a backstop.
    func testAScratchDirectoryIsGoneOnceItsWorkIsDone() throws {
        var used: URL?
        try PlaintextScratch.withScratchDirectory { directory in
            used = directory
            try Data("plaintext".utf8).write(to: directory.appendingPathComponent("in"))
        }
        let directory = try XCTUnwrap(used)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
