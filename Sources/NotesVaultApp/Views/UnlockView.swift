import SwiftUI
import NotesVaultCore

/// The one door into the vault, and — since the app now asks for a check on every reopen —
/// the screen a counsellor sees most often after the client list.
///
/// It says why it is being shown. "Unlock" after a quiet timeout and "that check did not
/// pass" are different events, and the second one is the app reporting that somebody
/// failed a Face ID or passcode prompt against these records. Rolling both into one
/// friendly heading would hide the only evidence of it there is.
struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var passphrase = ""
    @State private var rememberWithBiometrics = false
    @State private var showingRecovery = false

    /// Whether the biometric unlock may be offered at all: after a failed check the
    /// passphrase is the only way back in, and after an unavailable one there is nothing
    /// to offer.
    private var offersBiometrics: Bool {
        model.biometricsEnrolled && model.lockReason.allowsBiometricUnlock
    }

    private var title: String {
        switch model.lockReason {
        case .manual, .away: return "Unlock"
        case .checkFailed: return "That check didn't pass"
        case .checkUnavailable: return "This device can't check it's you"
        }
    }

    private var explanation: String? {
        switch model.lockReason {
        case .manual:
            return nil
        case .away:
            return "The app was away long enough to lock itself."
        case .checkFailed:
            return "\(model.deviceCheckMethod.displayName) was asked for and did not pass, so your notes were locked. Your passphrase is the only way back in — \(model.deviceCheckMethod.displayName) works again once you have used it."
        case .checkUnavailable:
            return "Face ID, Touch ID or a passcode has to be set up in this device's own settings before the app can check it is you. Until then, your passphrase is what opens the vault."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.largeTitle.bold())
                    if let folderName = model.folderName {
                        Label(folderName, systemImage: "folder")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let explanation {
                    Label(explanation, systemImage: model.lockReason == .checkFailed ? "exclamationmark.shield" : "info.circle")
                        .font(.footnote)
                        .foregroundStyle(model.lockReason == .checkFailed ? Color.orange : Color.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

                if offersBiometrics {
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
        // Asks as soon as the screen appears rather than waiting to be asked. Reopening the
        // app should cost one glance; the button below is for a second attempt, or for
        // somebody who declined the first.
        .task { await model.unlockIfBiometricsOffered() }
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
