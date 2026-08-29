import Foundation
@testable import NotesVaultCore

/// A reversible stand-in for the real crypto.
///
/// It is not encryption and does not pretend to be — it exists so the layout, the store and
/// the index can be tested exhaustively without scrypt costing a second per case. What it
/// *does* preserve is the shape the real engine imposes: names change on the way in,
/// content changes on the way in, and both round-trip. A bug where the store forgets to go
/// through the engine still fails these tests, because the stored bytes would not carry the
/// marker.
final class TransparentEngine: VaultCryptoEngine {
    static let contentMarker = "enc:"

    /// Recorded so a test can assert the store asked for the right directory.
    private(set) var lastDirectoryID: Data?

    func hashedDirectoryID(_ directoryID: Data) throws -> String {
        lastDirectoryID = directoryID
        // 20 bytes of digest renders as exactly 32 Base32 characters, which is the width
        // the real format produces — so the sharding logic is exercised for real.
        var digest = [UInt8]()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var round: UInt8 = 0
        while digest.count < 20 {
            for byte in directoryID + [round] {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
            for shift in stride(from: 56, through: 0, by: -8) where digest.count < 20 {
                digest.append(UInt8((hash >> UInt64(shift)) & 0xFF))
            }
            round &+= 1
        }
        return CrockfordBase32.encode(digest)
    }

    func encryptFilename(_ cleartext: String, directoryID: Data) throws -> String {
        CrockfordBase32.encode(Array(cleartext.utf8))
    }

    func decryptFilename(_ ciphertext: String, directoryID: Data) throws -> String {
        let bytes = try CrockfordBase32.decode(ciphertext)
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw VaultError.cryptoFailure("not decodable")
        }
        return text
    }

    /// Obscured, not encrypted — but obscured is the property the tests need. A store that
    /// wrote a note straight to the file store without going through the engine would leave
    /// readable text behind, and `testNothingIsStoredInTheClear` would catch it. If this
    /// were a passthrough, that test would pass no matter what the store did.
    func encryptContent(_ plaintext: Data) throws -> Data {
        Data(Self.contentMarker.utf8) + Data(plaintext.map { $0 ^ 0x5A })
    }

    func decryptContent(_ ciphertext: Data) throws -> Data {
        let marker = Data(Self.contentMarker.utf8)
        guard ciphertext.starts(with: marker) else {
            throw VaultError.cryptoFailure("content was not written through the engine")
        }
        return Data(ciphertext.dropFirst(marker.count).map { $0 ^ 0x5A })
    }
}

/// An in-memory `VaultFileStore`.
///
/// Enforces the one rule the format depends on — no silent overwrite — so a store that
/// stopped passing `overwrite: false` would fail here rather than on somebody's phone.
final class InMemoryFileStore: VaultFileStore {
    private(set) var files: [String: Data] = [:]
    private(set) var directories: Set<String> = [""]

    /// Set to make the next write fail, for testing the error paths.
    var failNextWrite = false

    private func key(_ path: [String]) -> String { path.joined(separator: "/") }

    func directoryExists(at path: [String]) -> Bool { directories.contains(key(path)) }
    func fileExists(at path: [String]) -> Bool { files[key(path)] != nil }

    func contentsOfDirectory(at path: [String]) throws -> [String] {
        let prefix = path.isEmpty ? "" : key(path) + "/"
        var names = Set<String>()
        for candidate in files.keys where candidate.hasPrefix(prefix) {
            if let first = candidate.dropFirst(prefix.count).split(separator: "/").first {
                names.insert(String(first))
            }
        }
        for candidate in directories where candidate.hasPrefix(prefix) && candidate != key(path) {
            if let first = candidate.dropFirst(prefix.count).split(separator: "/").first {
                names.insert(String(first))
            }
        }
        return Array(names)
    }

    func createDirectory(at path: [String]) throws {
        var accumulated: [String] = []
        for component in path {
            accumulated.append(component)
            directories.insert(key(accumulated))
        }
    }

    func read(at path: [String]) throws -> Data {
        guard let data = files[key(path)] else {
            throw VaultError.folderUnavailable("no file at \(key(path))")
        }
        return data
    }

    func write(_ data: Data, at path: [String], overwrite: Bool) throws {
        if failNextWrite {
            failNextWrite = false
            throw VaultError.folderUnavailable("simulated write failure")
        }
        if !overwrite && files[key(path)] != nil {
            throw VaultError.folderUnavailable("\(key(path)) already exists")
        }
        try createDirectory(at: Array(path.dropLast()))
        files[key(path)] = data
    }

    func remove(at path: [String]) throws {
        files.removeValue(forKey: key(path))
        directories.remove(key(path))
    }
}

enum Fixture {
    static func date(_ iso: String) -> Date {
        guard let date = VaultDate.parse(iso) else {
            fatalError("bad fixture date \(iso)")
        }
        return date
    }

    static func code(_ raw: String) -> ClientCode {
        (try? ClientCode(raw)) ?? ClientCode(validated: raw)
    }

    static func store() -> (store: VaultStore, files: InMemoryFileStore, engine: TransparentEngine) {
        let engine = TransparentEngine()
        let files = InMemoryFileStore()
        let store = VaultStore(engine: engine, files: files, deviceName: "mac")
        try? store.prepareStructure()
        return (store, files, engine)
    }
}
