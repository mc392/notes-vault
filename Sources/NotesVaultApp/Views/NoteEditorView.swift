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
    @Environment(\.scenePhase) private var scenePhase

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

    /// What the screen looked like before anything was typed. The autosave compares
    /// against these rather than against emptiness, so a template's starter headings or a
    /// correction's existing text is not mistaken for work in progress.
    private let initialBody: String
    private let initialSessionDate: Date
    private let initialTemplate: NoteTemplate
    /// The initial fields, plus the session number filled in on appear — that prefill is
    /// the app's own typing, not the counsellor's, and must not be enough to save a draft.
    @State private var baselineFieldValues: [String: String]

    /// When the restored draft was last written, and nil once the notice is dismissed.
    @State private var restoredDraftSavedAt: Date?
    /// The draft as last written to disk, so an unchanged screen is not re-encrypted every
    /// time SwiftUI sends a change through.
    @State private var savedDraft: NoteDraft?
    @State private var autosave: Task<Void, Never>?
    @State private var attemptedRestore = false

    /// Long enough that a fast typist is not encrypting on every keystroke, short enough
    /// that a phone killed in the background loses a sentence rather than a session.
    private static let autosaveDelay = Duration.seconds(1)

    init(client: ClientCode, correcting: NoteRecord?, sessionDate: Date? = nil) {
        self.client = client
        self.correcting = correcting
        let session = correcting?.session ?? sessionDate ?? Date()
        // A new note opens on Freeform, which prefills nothing by definition. The templates
        // themselves live in `model`, which an initialiser cannot reach.
        let body = correcting?.body ?? ""
        let fields = correcting?.extraHeaders ?? [:]
        _sessionDate = State(initialValue: session)
        _template = State(initialValue: correcting?.template ?? .freeform)
        _body_ = State(initialValue: body)
        _fieldValues = State(initialValue: fields)
        _baselineFieldValues = State(initialValue: fields)
        self.initialBody = body
        self.initialSessionDate = session
        self.initialTemplate = correcting?.template ?? .freeform
    }

    private var hasContent: Bool {
        !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The templates the picker offers: the ones this device offers, plus the one this note
    /// already carries if that is not among them. A correction to a note written from a
    /// template since removed — or made on another device — must not silently become a
    /// Freeform one the moment the picker cannot find it.
    private var offeredTemplates: [NoteTemplateDefinition] {
        var offered = model.noteTemplates.offered
        if !offered.contains(where: { $0.id == template.rawValue }) {
            offered.append(model.noteTemplates.definition(for: template) ?? NoteTemplateDefinition(
                id: template.rawValue,
                name: template.displayName,
                body: "",
                isBuiltIn: false
            ))
        }
        return offered
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
                if let restoredAt = restoredDraftSavedAt {
                    Section { restoredDraftNotice(savedAt: restoredAt) }
                }

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

                    if !suggestions.isEmpty {
                        SuggestedSessionDates(dates: suggestions, selection: $sessionDate)
                    }
                    Picker("Template", selection: $template) {
                        ForEach(offeredTemplates) { definition in
                            Text(definition.name).tag(definition.template)
                        }
                    }
                    .onChange(of: template) { _, newValue in
                        // Only ever fills an empty note. Silently rewriting something
                        // already written would be unforgivable in this app.
                        if !hasContent { body_ = model.noteTemplates.starterBody(for: newValue) }
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
                        autosave?.cancel()
                        Task {
                            await model.addNote(
                                client: client,
                                sessionDate: sessionDate,
                                template: template,
                                body: body_,
                                fieldValues: fieldValues,
                                supersedes: correcting?.id
                            )
                            // Only once the note is genuinely in the vault. If the write
                            // failed, the draft is the only copy left of what was typed.
                            if model.errorMessage == nil { clearDraft() }
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
                Button("Discard", role: .destructive) {
                    autosave?.cancel()
                    clearDraft()
                    dismiss()
                }
                // Keeping the draft is the whole point of this path: the note is still
                // there when the screen is opened again.
                Button("Keep writing", role: .cancel) { }
            } message: {
                Text("It has not been saved to the vault yet.")
            }
        }
        .vaultSheet(minWidth: 640, minHeight: 660)
        .onAppear(perform: prefillSessionNumber)
        .task { await restoreDraft() }
        .onChange(of: body_) { _, _ in scheduleDraftSave() }
        .onChange(of: fieldValues) { _, _ in scheduleDraftSave() }
        .onChange(of: sessionDate) { _, _ in scheduleDraftSave() }
        .onChange(of: template) { _, _ in scheduleDraftSave() }
        .onChange(of: scenePhase) { _, phase in
            // Leaving `.active` is the last moment anything is guaranteed to run: iOS may
            // kill the app from the background without another word. The debounce is
            // abandoned and the draft written now.
            guard phase != .active else { return }
            autosave?.cancel()
            saveDraftNow()
        }
    }

    // MARK: - Draft autosave

    /// One line, dismissible, at the top of the form.
    ///
    /// The draft is restored automatically rather than offered — a prompt's failure mode is
    /// tapping past it, which loses the note it was trying to save. So this says what has
    /// already happened, and the way out of it is a button rather than a decision.
    private func restoredDraftNotice(savedAt: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label("Restored an unsaved draft from \(Self.noticeTime(savedAt)).", systemImage: "clock.arrow.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button("Discard draft", role: .destructive) { discardDraft() }
                .font(.footnote)
                .buttonStyle(.borderless)

            Button {
                restoredDraftSavedAt = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
    }

    /// A draft from earlier today is a time; one from before that needs its date, because
    /// "from 14:02" on a note left open since Tuesday would be actively misleading.
    private static func noticeTime(_ date: Date) -> String {
        guard Calendar.current.isDateInToday(date) else { return Formatted.dateTime(date) }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// True when there is something a counsellor typed that the vault does not have.
    ///
    /// Deliberately body-and-fields only: a nudged date or a switched template on an
    /// otherwise untouched screen is not a note in progress, and storing one would mean a
    /// restore notice appearing over an empty form.
    private var hasUnsavedChanges: Bool {
        body_ != initialBody || fieldValues != baselineFieldValues
    }

    private func currentDraft() -> NoteDraft {
        NoteDraft(
            client: client,
            correcting: correcting?.id,
            body: body_,
            sessionDate: sessionDate,
            template: template,
            fieldValues: fieldValues
        )
    }

    private func scheduleDraftSave() {
        guard hasUnsavedChanges else { return }
        autosave?.cancel()
        autosave = Task { @MainActor in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            saveDraftNow()
        }
    }

    private func saveDraftNow() {
        guard hasUnsavedChanges else { return }
        let draft = currentDraft()
        if let savedDraft, draft.hasSameContent(as: savedDraft) { return }
        savedDraft = draft
        model.saveDraft(draft)
    }

    private func clearDraft() {
        savedDraft = nil
        restoredDraftSavedAt = nil
        model.clearDraft(client: client, correcting: correcting?.id)
    }

    /// Puts the screen back the way it opened and forgets the draft. The only way a
    /// restored draft is thrown away, and it takes a deliberate tap.
    private func discardDraft() {
        autosave?.cancel()
        body_ = initialBody
        sessionDate = initialSessionDate
        template = initialTemplate
        fieldValues = baselineFieldValues
        clearDraft()
    }

    private func restoreDraft() async {
        guard !attemptedRestore else { return }
        attemptedRestore = true
        guard let draft = await model.loadDraft(client: client, correcting: correcting?.id) else { return }

        // Body before template: setting the template fills the starter headings into an
        // empty note, and the restored body is what decides whether it is empty.
        body_ = draft.body
        sessionDate = draft.sessionDate
        template = draft.template
        fieldValues = draft.fieldValues
        savedDraft = draft
        restoredDraftSavedAt = draft.savedAt
    }

    /// Sessions this client should have had and has not been written up for.
    ///
    /// Only offered on a new note. A correction is *about* a session that already exists,
    /// so suggesting a different date for it would be nonsense.
    private var suggestions: [PredictedSession] {
        guard correcting == nil else { return [] }
        return model.predictedSessions(for: client)
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
        baselineFieldValues = fieldValues
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

/// The dates a client's cadence says are outstanding, as one-tap choices above the picker.
///
/// Suggestions, not a worklist. A cancelled session leaves no trace in the vault, so one of
/// these can be a date that never happened — which is fine when picking the right one is a
/// tap away, and would not be if this were presented as a list of work to do.
private struct SuggestedSessionDates: View {
    let dates: [PredictedSession]
    @Binding var selection: Date

    private func isChosen(_ session: PredictedSession) -> Bool {
        Calendar.current.isDate(session.date, equalTo: selection, toGranularity: .minute)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not yet written up")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dates) { session in
                        Button {
                            selection = session.date
                        } label: {
                            Text(Formatted.session(session))
                                .font(.footnote)
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .tint(isChosen(session) ? .accentColor : .secondary)
                    }
                }
                // The scroll view is edge-to-edge inside a Form row, so the first and last
                // chips need their own inset or they sit under the row's rounded corner.
                .padding(.horizontal, 1)
            }
        }
        .padding(.vertical, 2)
    }
}
