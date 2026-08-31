import Foundation
import Compression

/// A read-only zip reader, enough to open the two zip files a counsellor is likely to
/// hand this app: a `.docx` and an `.xlsx`.
///
/// **Why this is here rather than a package.** Word and Excel files are the two most
/// common places a counsellor's previous notes actually live, and both are zips. Pulling
/// in an archive library to open them would put third-party code directly in the path that
/// handles a folder of unencrypted clinical history — the one code path where "what else
/// does this dependency do?" is not a rhetorical question. Reading a zip's central
/// directory is a hundred lines, and the decompression itself is Apple's own `Compression`
/// framework, which is in the OS rather than in this repository.
///
/// Deliberately not supported: encrypted entries, Zip64, and writing. All three throw or
/// report rather than half-working. A password-protected export is a real thing a person
/// might hand us, and "that file is password-protected — open it in Word first" is a much
/// better answer than a garbled note.
public struct ZipArchive {
    public struct Entry: Hashable, Sendable {
        public let path: String
        public let compressedSize: Int
        public let uncompressedSize: Int
        let method: UInt16
        let localHeaderOffset: Int
        let isEncrypted: Bool
    }

    public let entries: [Entry]
    private let bytes: [UInt8]

    public var paths: [String] { entries.map(\.path) }

    public func entry(at path: String) -> Entry? {
        entries.first { $0.path == path }
    }

    /// Is this data a zip at all? Checked before extension, because `.pages`, `.numbers`,
    /// `.key`, `.docx` and `.xlsx` are all zips and a renamed file is common.
    public static func looksLikeZip(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B
    }

    public static func open(_ data: Data) throws -> ZipArchive {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else {
            throw ImportError.unreadableArchive("the file is too small to be a zip")
        }

        // The end-of-central-directory record is at the end, unless the file has a comment
        // — so scan backwards for its signature rather than assuming the last 22 bytes.
        var eocd: Int?
        let lowest = max(0, bytes.count - 22 - 65535)
        var cursor = bytes.count - 22
        while cursor >= lowest {
            if read32(bytes, cursor) == 0x0605_4B50 { eocd = cursor; break }
            cursor -= 1
        }
        guard let eocd else {
            throw ImportError.unreadableArchive("this does not end like a zip file — it may be damaged or only partly downloaded")
        }

        let entryCount = Int(read16(bytes, eocd + 10))
        let directoryOffset = Int(read32(bytes, eocd + 16))
        guard directoryOffset >= 0, directoryOffset < bytes.count else {
            throw ImportError.unreadableArchive("the zip's index points outside the file")
        }

        var entries: [Entry] = []
        var offset = directoryOffset
        for _ in 0..<entryCount {
            guard offset + 46 <= bytes.count, read32(bytes, offset) == 0x0201_4B50 else { break }
            let flags = read16(bytes, offset + 8)
            let method = read16(bytes, offset + 10)
            let compressed = Int(read32(bytes, offset + 20))
            let uncompressed = Int(read32(bytes, offset + 24))
            let nameLength = Int(read16(bytes, offset + 28))
            let extraLength = Int(read16(bytes, offset + 30))
            let commentLength = Int(read16(bytes, offset + 32))
            let localOffset = Int(read32(bytes, offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            entries.append(Entry(
                path: name,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                method: method,
                localHeaderOffset: localOffset,
                isEncrypted: flags & 0x0001 != 0
            ))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return ZipArchive(entries: entries, bytes: bytes)
    }

    /// The bytes of one entry, or nil if there is no such entry.
    public func data(for path: String) throws -> Data? {
        guard let entry = entry(at: path) else { return nil }
        return try data(for: entry)
    }

    public func data(for entry: Entry) throws -> Data {
        guard !entry.isEncrypted else {
            throw ImportError.unreadableArchive("\(entry.path) is password-protected. Open it in the app that made it, save an unprotected copy, and import that.")
        }
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, Self.read32(bytes, header) == 0x0403_4B50 else {
            throw ImportError.unreadableArchive("\(entry.path) is not where the zip's index says it is")
        }
        let nameLength = Int(Self.read16(bytes, header + 26))
        let extraLength = Int(Self.read16(bytes, header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= bytes.count else {
            throw ImportError.unreadableArchive("\(entry.path) runs past the end of the file")
        }
        let payload = Array(bytes[start..<end])

        switch entry.method {
        case 0:
            return Data(payload)
        case 8:
            guard let inflated = Self.inflate(payload, expecting: entry.uncompressedSize) else {
                throw ImportError.unreadableArchive("\(entry.path) could not be decompressed")
            }
            return inflated
        default:
            throw ImportError.unreadableArchive("\(entry.path) uses a compression method this app does not read (\(entry.method))")
        }
    }

    /// Raw DEFLATE, which is what `COMPRESSION_ZLIB` means in Apple's API — no zlib
    /// wrapper, which is exactly what a zip entry holds.
    private static func inflate(_ payload: [UInt8], expecting size: Int) -> Data? {
        guard size > 0 else { return Data() }
        // Some writers leave the size at zero in the header; give the buffer room rather
        // than truncating a note at an arbitrary point.
        let capacity = size
        var destination = [UInt8](repeating: 0, count: capacity)
        let written = payload.withUnsafeBufferPointer { source -> Int in
            guard let base = source.baseAddress else { return 0 }
            return destination.withUnsafeMutableBufferPointer { target -> Int in
                guard let targetBase = target.baseAddress else { return 0 }
                return compression_decode_buffer(
                    targetBase, capacity,
                    base, payload.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return Data(destination[0..<written])
    }

    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
