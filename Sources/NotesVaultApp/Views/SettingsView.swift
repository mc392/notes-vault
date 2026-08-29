import SwiftUI
import UniformTypeIdentifiers
import NotesVaultCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var exporting = false
    @State private var exportedCount: Int?
    @State private var changingPassphrase = false
    @State private var reissuingRecoveryKey = false

    var body: some View {
        List {
            Section {
                LabeledContent("Folder", value: model.folderName ?? "—")
                LabeledContent("Clients", value: "\(model.index.clients.count)")
                LabeledContent("Notes", value: "\(model.index.notes.count)")
                LabeledContent("Last read", value: Formatted.dateTime(model.index.builtAt))
                Button("Re-read the folder") {
                    Task { await model.refreshIndex(force: true) }
                }
            } header: {
                Text("Vault")
            } footer: {
                Text("Notes are read from the folder every time this app opens, so a note written on another device appears here once its sync has finished.")
            }

            Section {
                Button {
                    exporting = true
                } label: {
                    Label("Export everything", systemImage: "square.and.arrow.up")
                }
                if let exportedCount {
                    Text("\(exportedCount) files written.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Export")
            } footer: {
                Text("Writes every note out as a plain text file you can open in anything, on any computer, with or without this app. Keep the export somewhere as protected as the vault itself — it is not encrypted.")
            }

            Section {
                Stepper(
                    "Keep adult notes for \(model.retentionPolicy.adultYears) years",
                    value: $model.retentionPolicy.adultYears,
                    in: 1...50
                )
                Stepper(
                    "Flag \(model.retentionPolicy.reviewLeadDays) days ahead",
                    value: $model.retentionPolicy.reviewLeadDays,
                    in: 0...730,
                    step: 30
                )
            } header: {
                Text("Retention")
            } footer: {
                Text("BACP good practice is around seven years after last contact for adults, and until age \(model.retentionPolicy.minorAgeCeiling) for work with under-18s. Your insurer or supervisor may ask for longer.")
            }

            Section {
                Button("Change passphrase") { changingPassphrase = true }
                Button("Issue a new recovery key") { reissuingRecoveryKey = true }
                if model.biometricsEnrolled {
                    Text("Face ID or Touch ID is set up on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Lock now") { model.lock() }
            } header: {
                Text("Access")
            } footer: {
                Text("Changing your passphrase does not change your recovery key — the key you wrote down still works.")
            }

            Section {
                Button("Use a different folder", role: .destructive) { model.forgetFolder() }
            } footer: {
                Text("Forgets where the vault is on this device. Nothing in the folder is touched, and the notes stay exactly where they are.")
            }

            Section("About") {
                NavigationLink("How your notes are protected") { PrivacyExplainerView() }
                LabeledContent("Vault format", value: "Cryptomator 8")
            }
        }
        .navigationTitle("Settings")
        .fileImporter(isPresented: $exporting, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                Task { exportedCount = await model.export(to: url) }
            }
        }
        .sheet(isPresented: $changingPassphrase) { ChangePassphraseView() }
        .sheet(isPresented: $reissuingRecoveryKey) { ReissueRecoveryKeyView() }
    }
}

struct ChangePassphraseView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var updated = ""
    @State private var confirmation = ""

    private var canSubmit: Bool {
        !current.isEmpty && updated.count >= 12 && updated == confirmation
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Current") {
                    SecureField("Current passphrase", text: $current)
                }
                Section {
                    SecureField("New passphrase", text: $updated)
                    SecureField("New passphrase again", text: $confirmation)
                } footer: {
                    Text("At least 12 characters.")
                }
            }
            .navigationTitle("Change passphrase")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Change") {
                        Task {
                            if await model.changePassphrase(current: current, new: updated) { dismiss() }
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }
}

/// Reissuing invalidates the written copy, so the new one has to be shown and confirmed the
/// same way the first one was.
struct ReissueRecoveryKeyView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase = ""

    var body: some View {
        NavigationStack {
            Form {
                if let key = model.pendingRecoveryKey {
                    Section {
                        Text(key.formatted)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    } header: {
                        Text("Your new recovery key")
                    } footer: {
                        Text("Write this down and destroy the old one — it no longer opens this vault. You will not see this again.")
                    }
                    Section {
                        Button("I have written it down") {
                            model.dismissRecoveryKey()
                            dismiss()
                        }
                    }
                } else {
                    Section {
                        SecureField("Your passphrase", text: $passphrase)
                    } footer: {
                        Text("Issuing a new key immediately stops the old one working. Do this if you think the written copy has been seen by someone else.")
                    }
                    Section {
                        Button("Issue a new key") {
                            Task { await model.regenerateRecoveryKey(passphrase: passphrase) }
                        }
                        .disabled(passphrase.isEmpty)
                    }
                }
            }
            .navigationTitle("Recovery key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.dismissRecoveryKey()
                        dismiss()
                    }
                }
            }
        }
    }
}

/// The trust story, in the app rather than only on a website — a counsellor has to be able
/// to answer "where are my client notes kept?" without going looking for marketing copy.
struct PrivacyExplainerView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ExplainerSection(
                    title: "We never hold your notes",
                    detail: "This app makes no network connection of its own. It writes encrypted files into a folder you chose; if that folder is in iCloud Drive, your own iCloud account syncs it. There is no server of ours in the path, so there is nothing of yours for us to lose, be compelled to hand over, or have taken from us."
                )
                ExplainerSection(
                    title: "Encrypted before it is written",
                    detail: "Note text, filenames and folder names are all encrypted on this device using the Cryptomator vault format. Someone with access to the raw folder sees meaningless names and meaningless contents — not a client code, not a date, not a word count."
                )
                ExplainerSection(
                    title: "Codes, not names",
                    detail: "The app has nowhere to put a client's name, address or phone number, because it never asks for one. Keep the code‑to‑person list separately — a password manager is a good place. That separation means a compromise of one is not a compromise of both."
                )
                ExplainerSection(
                    title: "Nothing is ever overwritten",
                    detail: "Each note is a separate file, written once. Corrections are new entries that point at what they replace, so the record shows what was written and when it was changed — which is what a factual clinical record is supposed to do."
                )
                ExplainerSection(
                    title: "If you lose your passphrase",
                    detail: "Your recovery key is the only other way in. We hold no copy of either, so we genuinely cannot help — that is the trade-off for us being unable to read your notes, and it is not a policy we can make an exception to."
                )
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Your notes")
    }
}

struct ExplainerSection: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
