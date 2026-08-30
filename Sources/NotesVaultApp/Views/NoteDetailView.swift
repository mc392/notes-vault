import SwiftUI
import NotesVaultCore

/// Reading one note. Read-only, always — the only way to change what a note says is to
/// write a correction, which is a new entry beside it rather than a replacement of it.
struct NoteDetailView: View {
    @EnvironmentObject private var model: AppModel
    let entry: NoteIndexEntry

    @State private var note: NoteRecord?
    @State private var loadFailure: String?
    @State private var correcting = false

    private var supersededBy: [NoteIndexEntry] { model.index.corrections(of: entry.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Formatted.dateTime(entry.session, timeZone: entry.sessionTimeZone))
                        .font(.title3.weight(.semibold))
                    Text("Written \(Formatted.dateTime(entry.written)) on \(entry.device) · \(entry.template.displayName) · \(entry.wordCount) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    correcting = true
                } label: {
                    Label("Write a correction", systemImage: "square.and.pencil")
                }
                .disabled(note == nil)
            }
        }
        .task {
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
