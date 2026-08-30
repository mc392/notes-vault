import SwiftUI
import NotesVaultCore

/// Choosing what the note screen asks for, beyond the session date.
///
/// Everything here is off until switched on. A field that appeared uninvited would be a
/// change to what goes in a clinical record that nobody chose.
struct NoteFieldsSettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var addingField = false
    @State private var newLabel = ""
    @State private var newKind = NoteFieldKind.text

    var body: some View {
        List {
            Section {
                ForEach($model.noteFields.fields) { $field in
                    Toggle(isOn: $field.isEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.label)
                            Text(field.kind.displayName + (field.isBuiltIn ? "" : " · added by you"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: deleteCustomFields)
            } header: {
                Text("Fields")
            } footer: {
                Text("Switched-on fields appear on every new note. They are stored inside the note itself, encrypted with everything else, and a note keeps the values it was written with even if you change your mind later.")
            }

            Section {
                Button {
                    newLabel = ""
                    newKind = .text
                    addingField = true
                } label: {
                    Label("Add a field", systemImage: "plus")
                }
            } footer: {
                Text("Swipe a field you added to remove it. Removing one only stops it being offered on new notes — notes already written keep what they recorded.")
            }

            Section {
                Label {
                    Text("Never a name, an address or a phone number. The app deliberately has nowhere to put those, and a field you invent is not an exception — keep the code‑to‑person list where you already keep confidential information.")
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
                Text("Fields are set up per device, like the retention settings. Setting them up here does not change them on your other devices, and does not write anything to the vault.")
            }
        }
        .navigationTitle("Note fields")
        .sheet(isPresented: $addingField) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Name, e.g. Location", text: $newLabel)
                        Picker("Kind", selection: $newKind) {
                            ForEach(NoteFieldKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                    } footer: {
                        Text("The name is what appears on the note screen, and what is written into the note. \"Number\" only changes the keyboard you get — nothing is calculated from it.")
                    }
                }
                .navigationTitle("New field")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { addingField = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            addField()
                        }
                        .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .vaultSheet(minHeight: 340)
        }
    }

    private func addField() {
        do {
            try model.noteFields.addCustomField(label: newLabel, kind: newKind)
            addingField = false
        } catch {
            // Left open so the name is still there to correct, rather than typed again.
            model.errorMessage = (error as? VaultError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func deleteCustomFields(at offsets: IndexSet) {
        let keys = offsets
            .map { model.noteFields.fields[$0] }
            .filter { !$0.isBuiltIn }
            .map(\.key)
        for key in keys {
            model.noteFields.removeCustomField(key: key)
        }
    }
}
