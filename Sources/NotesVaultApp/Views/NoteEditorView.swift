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
    @State private var fieldValues: [String: String] = [:]
    @State private var confirmingDiscard = false
    @State private var prefilled = false

    init(client: ClientCode, correcting: NoteRecord?) {
        self.client = client
        self.correcting = correcting
        _sessionDate = State(initialValue: correcting?.session ?? Date())
        _template = State(initialValue: correcting?.template ?? .freeform)
        _body_ = State(initialValue: correcting?.body ?? NoteTemplate.freeform.starterBody)
        _fieldValues = State(initialValue: correcting?.extraHeaders ?? [:])
    }

    private var hasContent: Bool {
        !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isUnchangedCorrection: Bool {
        guard let correcting else { return false }
        return correcting.body == body_
            && correcting.session == sessionDate
            && correcting.template == template
            && correcting.extraHeaders == model.noteFields.headers(from: fieldValues)
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
                        #if os(macOS)
                        .datePickerStyle(.compact)
                        #endif
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

                    ForEach(model.noteFields.enabled) { field in
                        NoteFieldRow(field: field, value: binding(for: field))
                    }
                }

                Section {
                    NoteBodyEditor(text: $body_)
                        .frame(minHeight: 280)
                } header: {
                    Text("Note")
                } footer: {
                    Text("\(body_.wordCount) words. Encrypted on this device before it is written to the folder.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(correcting == nil ? "New note — \(client.rawValue)" : "Correction — \(client.rawValue)")
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
                                fieldValues: fieldValues,
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
        .vaultSheet(minWidth: 640, minHeight: 660)
        .onAppear(perform: prefillSessionNumber)
    }

    private func binding(for field: NoteFieldDefinition) -> Binding<String> {
        Binding(
            get: { fieldValues[field.key] ?? "" },
            set: { fieldValues[field.key] = $0 }
        )
    }

    /// Suggests the next session number rather than making the counsellor count. It is only
    /// ever a suggestion — the field stays editable, because a missed week or a note written
    /// out of order makes any automatic count wrong sooner or later.
    private func prefillSessionNumber() {
        guard !prefilled else { return }
        prefilled = true
        guard correcting == nil else { return }
        guard model.noteFields.enabled.contains(where: { $0.key == "session-number" }) else { return }
        guard (fieldValues["session-number"] ?? "").isEmpty else { return }

        let existing = model.index.clients.first { $0.code == client }?.noteCount ?? 0
        fieldValues["session-number"] = String(existing + 1)
    }
}

/// One extra field on the note screen.
///
/// `LabeledContent` rather than a bare `TextField`, because a text field's label is only its
/// placeholder — so a filled-in field showed its value with nothing to say what it was. A
/// prefilled session number read as a lone "1" floating between Template and Location.
private struct NoteFieldRow: View {
    let field: NoteFieldDefinition
    @Binding var value: String

    var body: some View {
        LabeledContent(field.label) {
            TextField("", text: $value)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(field.kind == .number ? .numbersAndPunctuation : .default)
                #endif
        }
    }
}
