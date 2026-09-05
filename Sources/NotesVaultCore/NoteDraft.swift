import Foundation

/// A note that is being written and has not been saved to the vault.
///
/// The vault's append-only guarantees start at Save. Everything before it lived in the
/// editor's `@State` and nowhere else, which is fine on a Mac and is not fine on a phone
/// that kills backgrounded apps — 400 words, a glance at Messages, and the note is gone
/// with no trace. This is the shape of what gets held onto in the meantime.
///
/// Pure data, so it lives here rather than in the crypto module: the *storage* of a draft
/// needs the keychain (`DraftStore`), but the draft itself is a struct of strings and
/// dates and Core stays dependency-free.
///
/// A draft is identified by the client it belongs to and the note it corrects, if any —
/// writing a new note for SM2 and writing a correction to one of SM2's notes are two
/// different pieces of work and must not overwrite each other.
public struct NoteDraft: Codable, Equatable, Sendable {
    public let client: ClientCode
    /// The note this draft would supersede, or nil for a new note.
    public let correcting: NoteID?
    public var body: String
    public var sessionDate: Date
    /// The template's identifier rather than the value itself, which is what a draft
    /// written on a device carrying a template this one has never seen still decodes as.
    public var templateRawValue: String
    public var fieldValues: [String: String]
    public var savedAt: Date

    public var template: NoteTemplate {
        NoteTemplate(rawValue: templateRawValue)
    }

    public init(
        client: ClientCode,
        correcting: NoteID? = nil,
        body: String,
        sessionDate: Date,
        template: NoteTemplate,
        fieldValues: [String: String],
        savedAt: Date = Date()
    ) {
        self.client = client
        self.correcting = correcting
        self.body = body
        self.sessionDate = sessionDate
        self.templateRawValue = template.rawValue
        self.fieldValues = fieldValues
        self.savedAt = savedAt
    }

    /// Everything except when it was saved.
    ///
    /// The editor uses this to avoid rewriting a draft it has just restored: the content is
    /// what matters, and a fresh `savedAt` alone is not a change worth encrypting.
    public func hasSameContent(as other: NoteDraft) -> Bool {
        client == other.client
            && correcting == other.correcting
            && body == other.body
            && sessionDate == other.sessionDate
            && templateRawValue == other.templateRawValue
            && fieldValues == other.fieldValues
    }
}
