import SwiftUI
import NotesVaultCore

/// Reading one note. Read-only, always — the only way to change what a note says is to
/// write a correction, which is a new entry beside it rather than a replacement of it.
struct NoteDetailView: View {
    @EnvironmentObject private var model: AppModel

    /// The notes this one was opened from, in the order they were listed — newest first,
    /// and already filtered the way the client screen was filtering them, so "the next
    /// note" means the next one the counsellor could see rather than the next one that
    /// exists.
    ///
    /// A snapshot on purpose. Writing a correction rebuilds the index underneath this
    /// screen, and a list that reordered itself while somebody was reading through it
    /// would move the ground under them.
    private let siblings: [NoteIndexEntry]

    @State private var position: Int
    @State private var note: NoteRecord?
    @State private var loadFailure: String?
    @State private var correcting = false

    init(entry: NoteIndexEntry, siblings: [NoteIndexEntry] = []) {
        let list = siblings.contains { $0.id == entry.id } ? siblings : [entry]
        self.siblings = list
        _position = State(initialValue: list.firstIndex { $0.id == entry.id } ?? 0)
    }

    private var entry: NoteIndexEntry { siblings[min(position, siblings.count - 1)] }
    /// The list runs newest first, so a later session is up and an earlier one is down.
    private var hasLater: Bool { position > 0 }
    private var hasEarlier: Bool { position + 1 < siblings.count }

    private var supersededBy: [NoteIndexEntry] { model.index.corrections(of: entry.id) }

    /// Counted oldest-first, because that is the order the sessions happened in — the
    /// list's own newest-first order is a convenience, not how anyone thinks about a
    /// course of work.
    private var positionLabel: String { "Note \(siblings.count - position) of \(siblings.count)" }

    /// Stepping to the next session is opening another note, so it asks the same way the
    /// list does. In practice it rarely prompts: a check taken a moment ago still stands,
    /// which is what makes reading through a course of work one act rather than twelve.
    private func move(by offset: Int) {
        let target = position + offset
        guard siblings.indices.contains(target) else { return }
        Task {
            guard await model.confirmIdentity(reason: "Confirm it's you before opening this note") else { return }
            note = nil
            loadFailure = nil
            position = target
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Formatted.dateTime(entry.session, timeZone: entry.sessionTimeZone))
                        .font(.title3.weight(.semibold))
                    Text("Written \(Formatted.dateTime(entry.written)) on \(entry.device) · \(model.noteTemplates.displayName(for: entry.template)) · \(entry.wordCount) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if siblings.count > 1 {
                        Text(positionLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !supersededBy.isEmpty {
                    Label(
                        "A later correction replaces this note. It is kept because the record is append-only.",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.footnote)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if let supersedes = entry.supersedes {
                    Label("This is a correction to note \(supersedes.rawValue.prefix(8))…", systemImage: "arrow.triangle.branch")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let note {
                    let extras = model.noteFields.describe(headers: note.extraHeaders)
                    if !extras.isEmpty {
                        NoteFieldSummary(entries: extras)
                    }

                    NoteBodyText(body: note.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let loadFailure {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("This note could not be opened", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(loadFailure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(entry.client.rawValue)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if siblings.count > 1 {
                    Button {
                        move(by: 1)
                    } label: {
                        Label("Earlier session", systemImage: "chevron.down")
                    }
                    .disabled(!hasEarlier)
                    .keyboardShortcut(.downArrow, modifiers: .command)

                    Button {
                        move(by: -1)
                    } label: {
                        Label("Later session", systemImage: "chevron.up")
                    }
                    .disabled(!hasLater)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                }

                Button {
                    correcting = true
                } label: {
                    Label("Write a correction", systemImage: "square.and.pencil")
                }
                .disabled(note == nil)
            }
        }
        // Keyed on the note, so stepping to the next one loads it rather than leaving the
        // previous note's text under a new date.
        .task(id: entry.id) {
            if let loaded = await model.readNote(entry) {
                note = loaded
            } else {
                loadFailure = model.errorMessage ?? "The file could not be read from the vault folder."
            }
        }
        .sheet(isPresented: $correcting) {
            if let note {
                NoteEditorView(client: entry.client, correcting: note)
            }
        }
    }
}

/// The extra fields a note was written with, above the note itself. Shown as a plain list
/// rather than folded into the body, because they are metadata about the session and the
/// body is the clinical account of it.
private struct NoteFieldSummary: View {
    let entries: [(label: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entries, id: \.label) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 110, alignment: .leading)
                    Text(entry.value)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Renders the note's Markdown.
///
/// Deliberately a small renderer rather than a library: this app supports subheadings,
/// bullets, bold and italic and nothing else, and every one of those is still readable as
/// plain text if this code disappears tomorrow. `AttributedString(markdown:)` handles the
/// inline markers; the block markers are handled here, because it does not do headings.
private struct NoteBodyText: View {
    let body_: String

    init(body: String) { self.body_ = body }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(NoteMarkdown.blocks(in: body_).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(text):
                    Text(inline(text))
                        .font(.headline)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case let .bullet(text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.body).foregroundStyle(.secondary)
                        Text(inline(text)).font(.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case let .paragraph(text):
                    Text(inline(text))
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .blank:
                    Spacer().frame(height: 2)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Falls back to the raw text if the markers do not parse, so a stray asterisk in a
    /// clinical note never costs the counsellor a line of their record.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
