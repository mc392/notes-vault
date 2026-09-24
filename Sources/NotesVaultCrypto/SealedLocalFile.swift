import Foundation
import CryptoKit

/// The one way this app writes anything of its own outside the vault folder: JSON, sealed
/// with AES-GCM under a key from this device's keychain, into Application Support.
///
/// The index cache and the drafts both do this, and each used to have its own copy of it.
/// That matters more than tidiness here: these are the only files the app writes that are
/// not in a Cryptomator vault, so they are exactly where "nothing readable is left on the
/// device" could quietly stop being true — and one copy is one place to check.
///
/// Every failure is soft and returns nil or false. What is stored here is a cache or a
/// convenience; losing it costs a rebuild or an autosave, never a note.
enum SealedLocalFile {
    /// `Application Support/NotesVault/<components…>`, created if needed.
    static func directory(_ components: String...) -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }

        let directory = components.reduce(support.appendingPathComponent("NotesVault", isDirectory: true)) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    static func write<Value: Encodable>(_ value: Value, to url: URL, key: SymmetricKey) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let plaintext = try? encoder.encode(value),
              let sealed = try? AES.GCM.seal(plaintext, using: key).combined else { return false }

        do {
            // Complete protection on iOS: no sync daemon ever needs to read these, so the
            // strictest class — the file's key evicted whenever the device locks — is
            // simply the right one.
            #if os(iOS)
            try sealed.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try sealed.write(to: url, options: [.atomic])
            #endif
            return true
        } catch {
            return false
        }
    }

    static func read<Value: Decodable>(_ type: Value.Type, from url: URL, key: SymmetricKey) -> Value? {
        guard let sealed = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plaintext = try? AES.GCM.open(box, using: key) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: plaintext)
    }
}
