import Foundation

/// One row of the local index: everything the app needs to draw a list without decrypting
/// a single note body.
public struct NoteIndexEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: NoteID
    public let client: ClientCode
    public let session: Date
    public let sessionUTCOffset: Int
    public let written: Date
    public let device: String
    public let template: NoteTemplate
    public let supersedes: NoteID?
    public let wordCount: Int
    /// The cleartext filename inside the client's folder. The ciphertext name is derived
    /// from this on demand and is never cached — it is a function of the vault key, and
    /// caching it would put a key-dependent value in a file with a different lifetime.
    public let filename: String

    public init(note: NoteRecord, filename: String) {
        self.id = note.id
        self.client = note.client
        self.session = note.session
        self.sessionUTCOffset = note.sessionUTCOffset
        self.written = note.written
        self.device = note.device
        self.template = note.template
        self.supersedes = note.supersedes
        self.wordCount = note.wordCount
        self.filename = filename
    }

    public var sessionTimeZone: TimeZone {
        TimeZone(secondsFromGMT: sessionUTCOffset) ?? .current
    }
}

public struct ClientSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: ClientCode { code }

    public let code: ClientCode
    public let status: ClientStatus
    public let retentionBasis: RetentionBasis
    public let firstContact: Date?
    /// The date the retention clock counts from: the latest session, unless the counsellor
    /// recorded a later contact that produced no note.
    public let lastContact: Date?
    public let noteCount: Int
    /// Notes that have been superseded by a correction. Counted separately so a client
    /// showing "12 notes" means twelve sessions, not twelve files.
    public let supersededCount: Int

    public init(
        code: ClientCode,
        status: ClientStatus,
        retentionBasis: RetentionBasis,
        firstContact: Date?,
        lastContact: Date?,
        noteCount: Int,
        supersededCount: Int
    ) {
        self.code = code
        self.status = status
        self.retentionBasis = retentionBasis
        self.firstContact = firstContact
        self.lastContact = lastContact
        self.noteCount = noteCount
        self.supersededCount = supersededCount
    }
}

/// The encrypted on-device cache described in the architecture: dates, client codes and
/// word counts, rebuilt from the vault.
///
/// It is a cache and nothing else. Every field can be recomputed by walking the vault, so
/// losing it, corrupting it or finding it stale is never data loss — the app rebuilds and
/// carries on. Nothing is ever read from here that has not also been written to a vault
/// file first.
public struct VaultIndex: Codable, Sendable {
    public static let formatVersion = 1

    public var version: Int
    public var builtAt: Date
    public var notes: [NoteIndexEntry]
    public var clients: [ClientSummary]

    public init(version: Int = VaultIndex.formatVersion, builtAt: Date = Date(), notes: [NoteIndexEntry] = [], clients: [ClientSummary] = []) {
        self.version = version
        self.builtAt = builtAt
        self.notes = notes
        self.clients = clients
    }

    public static let empty = VaultIndex(builtAt: Date(timeIntervalSince1970: 0))

    // MARK: - Queries

    public func client(_ code: ClientCode) -> ClientSummary? {
        clients.first { $0.code == code }
    }

    /// Every note for a client, newest session first.
    public func notes(for code: ClientCode) -> [NoteIndexEntry] {
        notes.filter { $0.client == code }.sorted { lhs, rhs in
            if lhs.session == rhs.session { return lhs.written > rhs.written }
            return lhs.session > rhs.session
        }
    }

    /// The IDs of notes that some later note replaces.
    public var supersededIDs: Set<NoteID> {
        Set(notes.compactMap { $0.supersedes })
    }

    /// The current record for a client: corrections shown, the notes they replace hidden.
    /// The superseded files are still in the vault and still readable — this is what the
    /// timeline shows by default, not what exists.
    public func currentNotes(for code: ClientCode) -> [NoteIndexEntry] {
        let superseded = supersededIDs
        return notes(for: code).filter { !superseded.contains($0.id) }
    }

    public func corrections(of id: NoteID) -> [NoteIndexEntry] {
        notes.filter { $0.supersedes == id }
    }

    /// Case-insensitive match on the client code. There is nothing else to search on —
    /// searching note bodies would mean decrypting every file on every keystroke, and is
    /// deferred rather than done badly.
    public func searchClients(_ query: String) -> [ClientSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return clients.sorted { $0.code < $1.code } }
        let needle = trimmed.uppercased()
        return clients
            .filter { $0.code.rawValue.contains(needle) }
            .sorted { $0.code < $1.code }
    }

    // MARK: - Building

    /// Rebuilds the whole index from what is actually in the vault.
    ///
    /// `clientEvents` is the *folded* metadata for each client — one event each, already
    /// resolved by `ClientMetadataEvent.fold`. A client with notes but no metadata event is
    /// still listed, as active with an adult retention basis, because a missing metadata
    /// file must never make a client's notes invisible.
    public static func build(
        notes: [(note: NoteRecord, filename: String)],
        clientEvents: [ClientCode: ClientMetadataEvent],
        builtAt: Date = Date()
    ) -> VaultIndex {
        let entries = notes.map { NoteIndexEntry(note: $0.note, filename: $0.filename) }
        let superseded = Set(entries.compactMap { $0.supersedes })

        var codes = Set(entries.map { $0.client })
        codes.formUnion(clientEvents.keys)

        let summaries: [ClientSummary] = codes.map { code in
            let mine = entries.filter { $0.client == code }
            let current = mine.filter { !superseded.contains($0.id) }
            let event = clientEvents[code]

            let latestSession = current.map(\.session).max() ?? mine.map(\.session).max()
            let lastContact: Date?
            if let override = event?.lastContactOverride {
                lastContact = max(override, latestSession ?? override)
            } else {
                lastContact = latestSession
            }

            return ClientSummary(
                code: code,
                status: event?.status ?? .active,
                retentionBasis: event?.retentionBasis ?? .adult,
                firstContact: current.map(\.session).min() ?? mine.map(\.session).min(),
                lastContact: lastContact,
                noteCount: current.count,
                supersededCount: mine.count - current.count
            )
        }

        return VaultIndex(
            builtAt: builtAt,
            notes: entries.sorted { $0.session > $1.session },
            clients: summaries.sorted { $0.code < $1.code }
        )
    }
}
