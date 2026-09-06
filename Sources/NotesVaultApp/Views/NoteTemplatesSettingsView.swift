import SwiftUI
import NotesVaultCore

/// The headings a new note starts from.
///
/// Decision 07 said templates are configurable, and until now that meant a choice of three
/// somebody else picked. A template here is a name and some headings, it only ever prefills
/// the editor, and nothing enforces it afterwards — which is the point. A counsellor who
/// starts one and then writes freely is not fighting the app.
struct NoteTemplatesSettingsView: View {
    @EnvironmentObject private var model: AppModel

    /// Which template the sheet is editing, or `.new` when it is making one.
    @State private var editing: TemplateEdit?

    var body: some View {
        List {
            Section {
                ForEach(model.noteTemplates.offered) { definition in
                    Button {
                        editing = TemplateEdit(definition)
                    } label: {
                        row(definition)
                    }
                    .buttonStyle(.plain)
                    // Freeform does not offer the swipe at all, rather than offering it and
                    // then quietly doing nothing.
                    .deleteDisabled(!definition.isRemovable)
                    // The swipe is the iPhone gesture and there is no such thing on a Mac,
                    // where this is the only way to reach it. Freeform's is shown greyed
                    // rather than left out, so the rule is visible rather than mysterious.
                    .contextMenu {
                        Button("Remove", role: .destructive) { remove(definition) }
                            .disabled(!definition.isRemovable)
                    }
                }
                .onDelete(perform: deleteTemplates)
            } header: {
                Text("Templates")
            } footer: {
                Text("Choosing a template on a new note fills in its headings and then gets out of the way. Swipe one to remove it, or right-click it on a Mac — that only stops it being offered on new notes, and notes already written keep every word of what they say.")
            }

            if !model.noteTemplates.removed.isEmpty {
                Section {
                    ForEach(model.noteTemplates.removed) { definition in
                        HStack {
                            Text(definition.name)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Put back") {
                                model.noteTemplates.restoreTemplate(id: definition.id)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("Removed")
                } footer: {
                    Text("The ones that ship with the app are kept rather than deleted, so they come back with the headings they always had. A template you wrote yourself is gone when you remove it.")
                }
            }

            Section {
                Button {
                    editing = TemplateEdit()
                } label: {
                    Label("Add a template", systemImage: "plus")
                }
            } footer: {
                Text("The ones that ship with the app cannot be changed, but a new template can start from any of them — which is how you get SOAP with one more heading.")
            }

            Section {
                Label {
                    Text("Headings only. A template is prefilled into every note that uses it, so anything you put here about a particular person would end up in somebody else's record.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent("This device only", value: model.deviceDisplayName)
            } footer: {
                Text("Templates are set up per device, like the note fields. A note written from one of yours carries its name inside the note, so it still reads back properly on a device that has never been given the template itself.")
            }
        }
        .navigationTitle("Note templates")
        .sheet(item: $editing) { edit in
            TemplateEditorView(edit: edit)
        }
    }

    private func row(_ definition: NoteTemplateDefinition) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(definition.name)
                Spacer()
                if definition.isBuiltIn {
                    Text("built in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(summary(of: definition))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// The headings on one line, so the list says what each template actually does rather
    /// than making you open all of them to find out. Read through the same Markdown parser
    /// the note screen uses, so a heading reads as "Subjective" rather than "## Subjective".
    private func summary(of definition: NoteTemplateDefinition) -> String {
        let headings = NoteMarkdown.blocks(in: definition.body)
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return headings.isEmpty ? "Starts empty" : headings.joined(separator: " · ")
    }

    private func deleteTemplates(at offsets: IndexSet) {
        for definition in offsets.map({ model.noteTemplates.offered[$0] }) {
            remove(definition)
        }
    }

    /// Errors go to the model's banner rather than being swallowed: the one thing that can
    /// fail here is removing Freeform, and saying why is better than a row that will not go.
    private func remove(_ definition: NoteTemplateDefinition) {
        do {
            try model.noteTemplates.removeTemplate(id: definition.id)
        } catch {
            model.errorMessage = (error as? VaultError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// What the editor sheet was opened on: an existing template of the counsellor's, or a new
/// one. Built-ins open here too, read-only — being able to see what SOAP actually fills in
/// is worth more than hiding it.
struct TemplateEdit: Identifiable {
    let id: String
    let existing: NoteTemplateDefinition?

    init() {
        self.id = ""
        self.existing = nil
    }

    init(_ definition: NoteTemplateDefinition) {
        self.id = definition.id
        self.existing = definition
    }

    var isNew: Bool { existing == nil }
    var isReadOnly: Bool { existing?.isBuiltIn ?? false }
}

private struct TemplateEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let edit: TemplateEdit

    @State private var name: String
    @State private var body_: String
    /// Which template a new one is being copied from. Only ever read when adding.
    @State private var startingFrom = NoteTemplate.freeform

    init(edit: TemplateEdit) {
        self.edit = edit
        _name = State(initialValue: edit.existing?.name ?? "")
        _body_ = State(initialValue: edit.existing?.body ?? "")
    }

    private var canSave: Bool {
        !edit.isReadOnly && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Trauma review", text: $name)
                        .disabled(edit.isReadOnly)
                    if edit.isNew {
                        Picker("Start from", selection: $startingFrom) {
                            Text("Empty").tag(NoteTemplate.freeform)
                            ForEach(model.noteTemplates.offered.filter { $0.id != NoteTemplate.freeform.rawValue }) { definition in
                                Text(definition.name).tag(definition.template)
                            }
                        }
                        .onChange(of: startingFrom) { _, newValue in
                            // Only ever fills an empty box, on the same principle as the
                            // note editor: nothing typed is ever overwritten.
                            if body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                body_ = model.noteTemplates.starterBody(for: newValue)
                            }
                        }
                    }
                } footer: {
                    Text(edit.isReadOnly
                         ? "This is one of the templates the app ships with, so it cannot be changed. Add a template to make your own version of it — or remove this one from the list, which you can undo later."
                         : "The name is what you pick on a new note, and what is written into the note itself.")
                }

                Section {
                    if edit.isReadOnly {
                        // Shown rather than put in a disabled editor: the text view under
                        // that editor does not honour `.disabled`, and a box that lets you
                        // type into a template you cannot save would be a small lie. Drawn
                        // the way the note screen draws it, so what is promised here is what
                        // a note started from it actually looks like.
                        if body_.isEmpty {
                            Text("Starts empty.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            NoteBodyText(body: body_)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        NoteBodyEditor(text: $body_)
                            .frame(minHeight: 240)
                    }
                } header: {
                    Text("Headings")
                } footer: {
                    Text(edit.isReadOnly
                         ? "This is exactly what a new note using this template starts with, drawn the way it will read."
                         : "Exactly what a new note using this template starts with. Leave blank lines under each heading so there is somewhere to write.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(edit.isReadOnly ? "Done" : "Cancel") { dismiss() }
                }
                if !edit.isReadOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
        }
        .vaultSheet(minWidth: 600, minHeight: 560)
    }

    private var title: String {
        if edit.isNew { return "New template" }
        return edit.existing?.name ?? "Template"
    }

    private func save() {
        do {
            if let existing = edit.existing {
                try model.noteTemplates.updateCustomTemplate(id: existing.id, name: name, body: body_)
            } else {
                try model.noteTemplates.addCustomTemplate(name: name, body: body_)
            }
            dismiss()
        } catch {
            // Left open, so what was typed is still there to correct rather than typed again.
            model.errorMessage = (error as? VaultError)?.errorDescription ?? error.localizedDescription
        }
    }
}
