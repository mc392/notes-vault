import Foundation

/// Something in the vault that could not be read, reported rather than thrown.
///
/// One damaged file must never make the other four hundred unreadable. Every bulk
/// operation collects these and carries on, and the app shows them — silently skipping a
/// note the counsellor believes is filed is the worst outcome available to this app.
public struct VaultIssue: Hashable, Sendable, Identifiable {
    public var id: String { "\(location)|\(message)" }
    public let location: String
    public let message: String

    public init(location: String, message: String) {
        self.location = location
        self.message = message
    }
}

public struct IndexBuildResult: Sendable {
    public let index: VaultIndex
    public let issues: [VaultIssue]
}

/// Reading and writing the vault, in the app's own vocabulary: clients, notes, corrections.
///
/// Everything here is append-only. There is no update method and no delete-note method by
/// design — a correction is a new note. The one destructive operation,
/// `destroyEverything(for:)`, removes a whole client at once and is reachable only through
/// the typed-confirmation flow in the UI; nothing automatic calls it.
public final class VaultStore {
    public static let noteExtension = "note"
    public static let clientEventExtension = "client"

    private let layout: VaultLayout
    private let files: VaultFileStore
    /// Written into every file this device creates, so two devices never collide and the
    /// record shows where each entry came from.
    public let deviceName: String

    private var directoryIDCache: [ClientCode: Data] = [:]

    public init(engine: VaultCryptoEngine, files: VaultFileStore, deviceName: String) {
        self.layout = VaultLayout(engine: engine)
        self.files = files
        self.deviceName = deviceName
    }

    // MARK: - Structure

    /// Creates the root data directory if this is a brand-new vault. Safe to call every
    /// time the vault is opened.
    public func prepareStructure() throws {
        let root = try layout.rootPath()
        if !files.directoryExists(at: root) {
            try files.createDirectory(at: root)
        }
    }

    // MARK: - Clients

    /// The client codes with a folder in the vault.
    ///
    /// Entries that do not decrypt are skipped, not fatal: a `.c9s` shortened name written
    /// by Cryptomator, or a sync conflict copy dropped in by iCloud, is somebody else's
    /// file and none of our business.
    public func listClientCodes() throws -> (codes: [ClientCode], issues: [VaultIssue]) {
        let rootID = VaultLayout.rootDirectoryID
        let rootPath = try layout.rootPath()
        guard files.directoryExists(at: rootPath) else { return ([], []) }

        var codes: [ClientCode] = []
        var issues: [VaultIssue] = []

        for entry in try files.contentsOfDirectory(at: rootPath).sorted() {
            guard files.directoryExists(at: rootPath + [entry]) else { continue }
            guard let cleartext = layout.cleartextName(for: entry, in: rootID) else {
                issues.append(VaultIssue(location: entry, message: "A folder in the vault could not be decrypted and was skipped."))
                continue
            }
            do {
                codes.append(try ClientCode(cleartext))
            } catch {
                issues.append(VaultIssue(location: cleartext, message: "\"\(cleartext)\" is not a valid client code and was skipped."))
            }
        }
        return (codes.sorted(), issues)
    }

    /// The directory ID of a client's folder, or nil if there is no such folder.
    public func directoryID(for code: ClientCode) throws -> Data? {
        if let cached = directoryIDCache[code] { return cached }
        let markerPath = try layout.directoryMarkerPath(forChildNamed: code.rawValue, in: VaultLayout.rootDirectoryID)
        guard files.fileExists(at: markerPath) else { return nil }
        let id = try files.read(at: markerPath)
        directoryIDCache[code] = id
        return id
    }

    /// Creates the client's folder if it does not exist yet, and returns its directory ID.
    @discardableResult
    public func ensureClient(_ code: ClientCode) throws -> Data {
        if let existing = try directoryID(for: code) { return existing }

        let rootID = VaultLayout.rootDirectoryID
        let rootPath = try layout.rootPath()
        if !files.directoryExists(at: rootPath) {
            try files.createDirectory(at: rootPath)
        }

        let folderName = try layout.ciphertextName(for: code.rawValue, in: rootID)
        let folderPath = rootPath + [folderName]
        if !files.directoryExists(at: folderPath) {
            try files.createDirectory(at: folderPath)
        }

        let newID = VaultLayout.newDirectoryID()
        try files.write(newID, at: folderPath + [VaultLayout.directoryMarker], overwrite: false)

        let contentPath = try layout.directoryPath(for: newID)
        if !files.directoryExists(at: contentPath) {
            try files.createDirectory(at: contentPath)
        }

        directoryIDCache[code] = newID
        return newID
    }

    // MARK: - Notes

    /// Writes a note and returns the cleartext filename it was stored under.
    ///
    /// Never overwrites. If the preferred name is taken — one client, one device, the same
    /// minute, which in practice means a correction written immediately — it falls back to
    /// the name carrying the note ID rather than replacing what is there.
    @discardableResult
    public func write(note: NoteRecord) throws -> String {
        let folderID = try ensureClient(note.client)

        var filename = note.preferredFilename
        if files.fileExists(at: try layout.filePath(named: filename, in: folderID)) {
            filename = note.disambiguatedFilename
        }
        let path = try layout.filePath(named: filename, in: folderID)
        guard !files.fileExists(at: path) else {
            throw VaultError.malformedNote("a note is already stored as \(filename)")
        }

        let ciphertext = try layout.engine.encryptContent(note.serialised())
        try files.write(ciphertext, at: path, overwrite: false)
        return filename
    }

    public func readNote(client code: ClientCode, filename: String) throws -> NoteRecord {
        guard let folderID = try directoryID(for: code) else {
            throw VaultError.clientNotFound(code)
        }
        let path = try layout.filePath(named: filename, in: folderID)
        guard files.fileExists(at: path) else {
            throw VaultError.malformedNote("\(filename) is no longer in the vault")
        }
        let plaintext = try layout.engine.decryptContent(try files.read(at: path))
        return try NoteRecord.parse(plaintext)
    }

    /// Cleartext filenames in a client's folder, split by what they are.
    public func listFilenames(for code: ClientCode) throws -> (notes: [String], events: [String], issues: [VaultIssue]) {
        guard let folderID = try directoryID(for: code) else {
            throw VaultError.clientNotFound(code)
        }
        let path = try layout.directoryPath(for: folderID)
        guard files.directoryExists(at: path) else { return ([], [], []) }

        var notes: [String] = []
        var events: [String] = []
        var issues: [VaultIssue] = []

        for entry in try files.contentsOfDirectory(at: path).sorted() {
            if entry == VaultLayout.directoryMarker { continue }
            guard let cleartext = layout.cleartextName(for: entry, in: folderID) else {
                issues.append(VaultIssue(location: "\(code)/\(entry)", message: "A file in this client's folder could not be decrypted and was skipped."))
                continue
            }
            if cleartext.hasSuffix(".\(Self.noteExtension)") {
                notes.append(cleartext)
            } else if cleartext.hasSuffix(".\(Self.clientEventExtension)") {
                events.append(cleartext)
            } else {
                issues.append(VaultIssue(location: "\(code)/\(cleartext)", message: "Unrecognised file in the vault, left alone."))
            }
        }
        return (notes.sorted(), events.sorted(), issues)
    }

    // MARK: - Client metadata

    public func write(event: ClientMetadataEvent) throws {
        let folderID = try ensureClient(event.client)
        let path = try layout.filePath(named: event.filename, in: folderID)
        let ciphertext = try layout.engine.encryptContent(event.serialised())
        try files.write(ciphertext, at: path, overwrite: false)
    }

    /// The folded, current metadata for a client — or nil if they have never had any
    /// written, which is normal for a client created by writing their first note.
    public func currentMetadata(for code: ClientCode) throws -> ClientMetadataEvent? {
        guard let folderID = try directoryID(for: code) else { return nil }
        let filenames = try listFilenames(for: code).events

        var events: [ClientMetadataEvent] = []
        for filename in filenames {
            let path = try layout.filePath(named: filename, in: folderID)
            guard files.fileExists(at: path) else { continue }
            if let plaintext = try? layout.engine.decryptContent(try files.read(at: path)),
               let event = try? ClientMetadataEvent.parse(plaintext) {
                events.append(event)
            }
        }
        return ClientMetadataEvent.fold(events)
    }

    // MARK: - Index

    /// Walks the whole vault and rebuilds the index from what is actually stored.
    ///
    /// This is the only source of truth for the index. It is not incremental on purpose:
    /// a vault that two devices have both been writing to has no ordering guarantee worth
    /// trusting, and a full walk of a few hundred small files is fast enough that being
    /// clever here would only buy the chance of a stale index.
    public func rebuildIndex(progress: ((Int, Int) -> Void)? = nil) throws -> IndexBuildResult {
        try prepareStructure()

        let listing = try listClientCodes()
        var issues = listing.issues
        var notes: [(note: NoteRecord, filename: String)] = []
        var events: [ClientCode: ClientMetadataEvent] = [:]

        for (offset, code) in listing.codes.enumerated() {
            progress?(offset, listing.codes.count)
            guard let folderID = try directoryID(for: code) else { continue }

            let contents: (notes: [String], events: [String], issues: [VaultIssue])
            do {
                contents = try listFilenames(for: code)
            } catch {
                issues.append(VaultIssue(location: code.rawValue, message: error.localizedDescription))
                continue
            }
            issues.append(contentsOf: contents.issues)

            for filename in contents.notes {
                do {
                    let path = try layout.filePath(named: filename, in: folderID)
                    let plaintext = try layout.engine.decryptContent(try files.read(at: path))
                    notes.append((try NoteRecord.parse(plaintext), filename))
                } catch {
                    issues.append(VaultIssue(location: "\(code)/\(filename)", message: error.localizedDescription))
                }
            }

            var clientEvents: [ClientMetadataEvent] = []
            for filename in contents.events {
                do {
                    let path = try layout.filePath(named: filename, in: folderID)
                    let plaintext = try layout.engine.decryptContent(try files.read(at: path))
                    clientEvents.append(try ClientMetadataEvent.parse(plaintext))
                } catch {
                    issues.append(VaultIssue(location: "\(code)/\(filename)", message: error.localizedDescription))
                }
            }
            if let folded = ClientMetadataEvent.fold(clientEvents) {
                events[code] = folded
            }
        }
        progress?(listing.codes.count, listing.codes.count)

        return IndexBuildResult(
            index: VaultIndex.build(notes: notes, clientEvents: events),
            issues: issues
        )
    }

    // MARK: - Export

    /// Decrypts the whole vault and hands each file to the caller as a cleartext relative
    /// path plus its bytes.
    ///
    /// Principle 05: the counsellor can always get everything out, in a format that needs
    /// nothing from us to read. The caller decides where it goes, so the same walk serves
    /// "export to a folder" and "export to a zip" without this layer knowing about either.
    public func exportPlaintext(_ emit: ([String], Data) throws -> Void) throws -> [VaultIssue] {
        let listing = try listClientCodes()
        var issues = listing.issues

        for code in listing.codes {
            guard let folderID = try directoryID(for: code) else { continue }
            let contents = try listFilenames(for: code)
            issues.append(contentsOf: contents.issues)

            for filename in contents.notes + contents.events {
                do {
                    let path = try layout.filePath(named: filename, in: folderID)
                    let plaintext = try layout.engine.decryptContent(try files.read(at: path))
                    try emit([code.rawValue, filename], plaintext)
                } catch {
                    issues.append(VaultIssue(location: "\(code)/\(filename)", message: error.localizedDescription))
                }
            }
        }
        return issues
    }

    // MARK: - Destruction

    /// Removes every file belonging to one client, and the folder itself.
    ///
    /// Deliberately not called by anything automatic. The retention review flags; a human
    /// types the client code to confirm; only then does this run. That separation is the
    /// compliance requirement, not a UI preference.
    public func destroyEverything(for code: ClientCode) throws {
        guard let folderID = try directoryID(for: code) else {
            throw VaultError.clientNotFound(code)
        }
        let contentPath = try layout.directoryPath(for: folderID)
        if files.directoryExists(at: contentPath) {
            for entry in try files.contentsOfDirectory(at: contentPath) {
                try files.remove(at: contentPath + [entry])
            }
            try files.remove(at: contentPath)
        }

        let folderName = try layout.ciphertextName(for: code.rawValue, in: VaultLayout.rootDirectoryID)
        let folderPath = try layout.rootPath() + [folderName]
        if files.directoryExists(at: folderPath) {
            for entry in try files.contentsOfDirectory(at: folderPath) {
                try files.remove(at: folderPath + [entry])
            }
            try files.remove(at: folderPath)
        }
        directoryIDCache[code] = nil
    }
}
