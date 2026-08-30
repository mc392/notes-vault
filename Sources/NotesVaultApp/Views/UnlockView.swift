import SwiftUI
import NotesVaultCore

struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var passphrase = ""
    @State private var rememberWithBiometrics = false
    @State private var showingRecovery = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unlock")
                        .font(.largeTitle.bold())
                    if let folderName = model.folderName {
                        Label(folderName, systemImage: "folder")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onSubmit { unlock() }

                if model.biometricsAvailable && !model.biometricsEnrolled {
                    Toggle("Unlock with Face ID or Touch ID next time", isOn: $rememberWithBiometrics)
                        .font(.subheadline)
                }

                Button("Unlock") { unlock() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(passphrase.isEmpty)

                if model.biometricsEnrolled {
                    Button {
                        Task { await model.unlockWithBiometrics() }
                    } label: {
                        Label("Unlock with Face ID or Touch ID", systemImage: "faceid")
                    }
                }

                Divider().padding(.vertical, 4)

                Button("I have forgotten my passphrase") { showingRecovery = true }
                    .font(.footnote)
                Button("Use a different folder") { model.forgetFolder() }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingRecovery) {
            RecoverAccessView()
        }
    }

    private func unlock() {
        guard !passphrase.isEmpty else { return }
        let entered = passphrase
        let remember = rememberWithBiometrics
        passphrase = ""
        Task { await model.unlock(passphrase: entered, rememberWithBiometrics: remember) }
    }
}

/// Getting back in with the recovery key, and choosing a new passphrase in the same step.
///
/// Deliberately not a "reveal my old passphrase" flow — there is nothing to reveal. The key
/// unwraps the vault key and the vault is re-wrapped under a new passphrase, which is the
/// only honest shape this operation can have.
struct RecoverAccessView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var typedKey = ""
    @State private var newPassphrase = ""
    @State private var confirmation = ""

    private var parsedKey: RecoveryKey? {
        try? RecoveryKey(typed: typedKey)
    }

    private var keyProblem: String? {
        guard !typedKey.isEmpty else { return nil }
        do {
            _ = try RecoveryKey(typed: typedKey)
            return nil
        } catch let error as VaultError {
            return error.errorDescription
        } catch {
            return error.localizedDescription
        }
    }

    private var canSubmit: Bool {
        parsedKey != nil && newPassphrase.count >= 12 && newPassphrase == confirmation
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("XXXX-XXXX-XXXX-…", text: $typedKey, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .keyEntryStyle()
                    if let keyProblem {
                        Text(keyProblem)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Recovery key")
                } footer: {
                    Text("The key you wrote down when the vault was created. Capitals, spaces and hyphens do not matter.")
                }

                Section {
                    SecureField("New passphrase", text: $newPassphrase)
                    SecureField("New passphrase again", text: $confirmation)
                } header: {
                    Text("New passphrase")
                } footer: {
                    Text("At least 12 characters. Your recovery key stays the same — this does not issue a new one.")
                }

                Section {
                    Button("Restore access") {
                        guard let key = parsedKey else { return }
                        Task {
                            if await model.resetPassphrase(recoveryKey: key, newPassphrase: newPassphrase) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("Recover access")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .vaultSheet()
    }
}
