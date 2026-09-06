import SwiftUI
import UniformTypeIdentifiers
import NotesVaultCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var exporting = false
    @State private var importing = false
    @State private var exportedCount: Int?
    @State private var changingPassphrase = false
    @State private var reissuingRecoveryKey = false
    @State private var syncingSchedules = false

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
                    syncingSchedules = true
                } label: {
                    Label("Sync schedules", systemImage: "arrow.triangle.2.circlepath")
                }
                if let last = model.rosterLastSync {
                    Text("Last synced \(Formatted.dateTime(last)).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("GroundWork")
            } footer: {
                Text("Brings across how often each client is seen, so this app can suggest which sessions still need writing up. Client codes and appointment times only — no names, and nothing about a session ever goes back to GroundWork.")
            }

            Section {
                Button {
                    importing = true
                } label: {
                    Label("Import existing notes", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Import")
            } footer: {
                Text("Bring in notes you already keep somewhere else — Word, Excel, CSV, text, Apple Notes and more. Everything is read on this device and encrypted before it is written; your original files are left exactly where they are.")
            }

            Section {
                Button {
                    // An export writes every note out in plain text. That is the single
                    // biggest thing anyone holding this phone could do with it, so it is
                    // one of the actions that asks.
                    gated("Confirm it's you before exporting every note") { exporting = true }
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
                NavigationLink {
                    NoteFieldsSettingsView()
                } label: {
                    LabeledContent("Note fields", value: "\(model.noteFields.enabled.count) on")
                }
                NavigationLink {
                    NoteTemplatesSettingsView()
                } label: {
                    LabeledContent("Note templates", value: "\(model.noteTemplates.offered.count)")
                }
            } header: {
                Text("Notes")
            } footer: {
                Text("Record more than the date against each session — a session number, a location, or fields you define yourself — and start a note from your own headings rather than only the three the app ships with.")
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
                Picker(
                    "Ask again",
                    selection: Binding(
                        get: { model.lockPolicy.reopenGrace },
                        set: { seconds in Task { await model.setReopenGrace(seconds) } }
                    )
                ) {
                    ForEach(LockPolicy.graceChoices, id: \.self) { seconds in
                        Text(LockPolicy.graceLabel(seconds)).tag(seconds)
                    }
                }
                if model.biometricsEnrolled {
                    Text("\(model.deviceCheckMethod.displayName) is set up on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !model.deviceCheckAvailable {
                    Label(
                        "This device has no Face ID, Touch ID or passcode set up, so it cannot check who is holding it. Add one in the device's own settings — until then, coming back to the app means typing your passphrase.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
                Button("Lock now") { model.lock() }
            } header: {
                Text("When the app asks")
            } footer: {
                Text("How long GroundWork Notes may be off screen before it asks again. Straight away is the safest and is what it does unless you change it. Once you are in, it asks in only two more places: opening a note, and changing anything in this section.")
            }

            Section {
                Button("Change passphrase") {
                    gated("Confirm it's you before changing your passphrase") { changingPassphrase = true }
                }
                Button("Issue a new recovery key") {
                    gated("Confirm it's you before issuing a new recovery key") { reissuingRecoveryKey = true }
                }
            } header: {
                Text("Access")
            } footer: {
                Text("Changing your passphrase does not change your recovery key — the key you wrote down still works.")
            }

            Section {
                Button("Use a different folder", role: .destructive) {
                    gated("Confirm it's you before forgetting this vault") { model.forgetFolder() }
                }
            } footer: {
                Text("Forgets where the vault is on this device. Nothing in the folder is touched, and the notes stay exactly where they are. Face ID unlock for this vault is switched off on this device too.")
            }

            Section("About") {
                NavigationLink("How your notes are protected") { PrivacyExplainerView() }
                LabeledContent("Vault format", value: "Cryptomator 8")
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $importing) {
            ImportView()
        }
        .sheet(isPresented: $syncingSchedules) {
            ScheduleSyncView()
        }
        .fileImporter(isPresented: $exporting, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                Task { exportedCount = await model.export(to: url) }
            }
        }
        .sheet(isPresented: $changingPassphrase) { ChangePassphraseView() }
        .sheet(isPresented: $reissuingRecoveryKey) { ReissueRecoveryKeyView() }
    }

    /// Runs `action` only if the counsellor confirms it is them.
    ///
    /// A refused check does nothing at all — no sheet, no alert, no "are you sure?". If it
    /// *failed* rather than being declined, the vault is already locked behind this screen
    /// and the unlock screen says why, so there is nothing left here to report.
    private func gated(_ reason: String, _ action: @escaping () -> Void) {
        Task {
            if await model.confirmIdentity(reason: reason) { action() }
        }
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
        .vaultSheet(minHeight: 420)
    }
}

/// Reissuing invalidates the written copy, so the new one has to be shown and confirmed the
/// same way the first one was.
struct ReissueRecoveryKeyView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase = ""
    @State private var typedBack = ""
    @State private var showingKey = true
    @State private var matches = false
    @State private var confirmingClose = false

    var body: some View {
        NavigationStack {
            Form {
                if let key = model.pendingRecoveryKey {
                    Section {
                        RecoveryKeyConfirmation(
                            key: key,
                            typedBack: $typedBack,
                            showingKey: $showingKey,
                            matches: $matches
                        )
                    } header: {
                        Text("Your new recovery key")
                    } footer: {
                        Text("Your old key stopped working the moment this one was issued. Write this one down and destroy the old paper copy.")
                    }
                    Section {
                        Button("I have written it down") {
                            model.dismissRecoveryKey()
                            dismiss()
                        }
                        .disabled(!matches)
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
                        if model.pendingRecoveryKey != nil && !matches {
                            confirmingClose = true
                        } else {
                            model.dismissRecoveryKey()
                            dismiss()
                        }
                    }
                }
            }
            .confirmationDialog(
                "Close without confirming your new key?",
                isPresented: $confirmingClose,
                titleVisibility: .visible
            ) {
                Button("Close anyway", role: .destructive) {
                    model.dismissRecoveryKey()
                    dismiss()
                }
                Button("Go back", role: .cancel) { }
            } message: {
                Text("The old key no longer works. If you have not written this one down, you will have no recovery key.")
            }
        }
        .vaultSheet(minHeight: 440)
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
