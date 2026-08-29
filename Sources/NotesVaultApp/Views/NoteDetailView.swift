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
                    Text(note.body)
                        .font(.body)
                        .textSelection(.enabled)
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
