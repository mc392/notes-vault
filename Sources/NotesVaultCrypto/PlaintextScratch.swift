import Foundation

/// A short-lived place for plaintext that has to exist as a file.
///
/// **Why this type exists at all.** Cryptomator's library exposes content encryption only
/// as `encryptContent(from: URL, to: URL)` — the stream overloads that would keep a note in
/// memory are `internal`. So encrypting a note means the cleartext touches the filesystem
/// for the length of one call. For an app whose entire promise is that plaintext never
/// leaves the device unencrypted, that is worth handling deliberately rather than reaching
/// for `NSTemporaryDirectory()` and moving on.
///
/// What this does about it:
/// - the scratch directory is unique per operation and removed immediately afterwards;
/// - on iOS every file is created with complete protection, so its key is evicted when the
///   device locks and the bytes are unreadable even to a thief holding the hardware;
/// - contents are overwritten before unlinking. On flash storage an overwrite is not a
///   guarantee — wear levelling may leave the original block intact — which is exactly why
///   the protection class above is doing the real work and this is only a second line.
///
/// The proper fix is upstream: expose the stream overloads and this file disappears. That
/// is recorded in the README as an open item, not left as a comment nobody reads.
enum PlaintextScratch {
    static func withScratchDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("notesvault-scratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: protectionAttributes)
        defer { shredDirectory(base) }
        return try body(base)
    }

    private static var protectionAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
        return [.protectionKey: FileProtectionType.complete]
        #else
        return [:]
        #endif
    }

    /// Write options for anything landing in the scratch directory. On iOS this is what
    /// actually protects the plaintext — the file's key is evicted when the device locks.
    static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }

    private static func shredDirectory(_ directory: URL) {
        let manager = FileManager.default
        if let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            for entry in entries {
                shredFile(entry)
            }
        }
        try? manager.removeItem(at: directory)
    }

    private static func shredFile(_ url: URL) {
        let manager = FileManager.default
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
            var noise = Data(count: size)
            noise.withUnsafeMutableBytes { buffer in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
                for offset in 0..<size { base[offset] = UInt8.random(in: UInt8.min...UInt8.max) }
            }
            try? noise.write(to: url, options: [])
        }
        try? manager.removeItem(at: url)
    }
}
