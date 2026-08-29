import SwiftUI
import NotesVaultCore

/// Writing a note, or writing a correction to one.
///
/// There is no "edit" here and there never will be. Choosing a template prefills the body
/// and then gets out of the way — nothing enforces the headings, because a clinical record
/// that fights its author gets written somewhere else instead.
struct NoteEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let client: ClientCode
    /// When set, the new note replaces this one in the timeline. The original stays in the
    /// vault and stays readable.
    let correcting: NoteRecord?

    @State private var sessionDate: Date
    @State private var template: NoteTemplate
    @State private var body_ = ""
    @State private var confirmingDiscard = false

    init(client: ClientCode, correcting: NoteRecord?) {
        self.client = client
        self.correcting = correcting
        _sessionDate = State(initialValue: correcting?.session ?? Date())
        _template = State(initialValue: correcting?.template ?? .freeform)
        _body_ = State(initialValue: correcting?.body ?? NoteTemplate.freeform.starterBody)
    }

    private var hasContent: Bool {
        !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isUnchangedCorrection: Bool {
        guard let correcting else { return false }
        return correcting.body == body_ && correcting.session == sessionDate && correcting.template == template
    }

    var body: some View {
        NavigationStack {
            Form {
                if correcting != nil {
                    Section {
                        Label(
                            "This is filed as a correction. The earlier note stays in the record and is still readable.",
                            systemImage: "arrow.triangle.branch"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Session") {
                    DatePicker("Date and time", selection: $sessionDate)
                    Picker("Template", selection: $template) {
                        ForEach(NoteTemplate.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .onChange(of: template) { _, newValue in
                        // Only ever fills an empty note. Silently rewriting something
                        // already written would be unforgivable in this app.
                        if !hasContent { body_ = newValue.starterBody }
                    }
                }

                Section {
                    TextEditor(text: $body_)
                        .frame(minHeight: 260)
                        .font(.body)
                } header: {
                    Text("Note")
                } footer: {
                    Text("\(body_.wordCount) words. Encrypted on this device before it is written to the folder.")
                }
            }
            .navigationTitle(correcting == nil ? "New note — \(client)" : "Correction — \(client)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasContent { confirmingDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model.addNote(
                                client: client,
                                sessionDate: sessionDate,
                                template: template,
                                body: body_,
                                supersedes: correcting?.id
                            )
                            dismiss()
                        }
                    }
                    .disabled(!hasContent || isUnchangedCorrection)
                }
            }
            .confirmationDialog(
                "Discard this note?",
                isPresented: $confirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep writing", role: .cancel) { }
            } message: {
                Text("It has not been saved to the vault yet.")
            }
        }
    }
}
