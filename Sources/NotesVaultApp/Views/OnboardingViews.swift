import SwiftUI
import UniformTypeIdentifiers
import NotesVaultCore

/// First screen. Explains the arrangement before asking for anything, because "point this
/// app at a folder in your iCloud Drive" only makes sense once you know why it is not
/// asking you to sign in.
struct ChooseFolderView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("GroundWork Notes")
                        .font(.largeTitle.bold())
                    Text("Clinical notes that stay yours.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    PointRow(
                        symbol: "icloud",
                        title: "Your cloud, not ours",
                        detail: "Choose a folder — in iCloud Drive if you want it on more than one device. We never see it. There is no account to create and no server to sign in to."
                    )
                    PointRow(
                        symbol: "lock.shield",
                        title: "Encrypted before it leaves the device",
                        detail: "Notes, filenames and folder names are all encrypted here, on this device. What syncs is meaningless without your passphrase."
                    )
                    PointRow(
                        symbol: "number",
                        title: "Client codes only",
                        detail: "The app never asks for a client's name or contact details. Keep the code‑to‑person list wherever you already keep confidential information."
                    )
                }

                Button {
                    showingPicker = true
                } label: {
                    Label("Choose a folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Starting out? Pick an empty folder — inside iCloud Drive if you want your notes on more than one device.")
                    Text("Already have a vault? Choose the same folder you picked the first time.")
                    // The picker will let you walk into a vault's own folders, which look
                    // empty and inviting from the inside and are not somewhere to put
                    // anything. Saying so here is cheaper than the error that follows.
                    Text("Either way, choose the folder itself rather than anything inside it. Once a vault exists, the folders within it hold nothing but encrypted files.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url):
                model.chooseFolder(url)
            case let .failure(error):
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

struct PointRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// Setting the passphrase on a brand-new vault.
struct CreateVaultView: View {
    @EnvironmentObject private var model: AppModel
    @State private var passphrase = ""
    @State private var confirmation = ""

    /// Long rather than complicated. A memorable four-word phrase beats `Tr0ub4dor&3`, and
    /// the guidance says so rather than demanding a capital and a symbol.
    private var problem: String? {
        if passphrase.count < 12 { return "Use at least 12 characters — a short phrase of a few unrelated words is ideal." }
        if confirmation != passphrase { return "The two entries do not match yet." }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Set your passphrase")
                    .font(.largeTitle.bold())
                Text("This is the only thing that opens \(model.folderName ?? "this vault"). Choose something you will still know in a year.")
                    .foregroundStyle(.secondary)

                SecureField("Passphrase", text: $passphrase)
                    .textContentType(.newPassword)
                SecureField("Passphrase again", text: $confirmation)
                    .textContentType(.newPassword)

                if let problem, !passphrase.isEmpty {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                WarningBox(
                    symbol: "exclamationmark.triangle",
                    title: "There is no password reset",
                    detail: "We hold no copy of your key and cannot recover your notes. The next screen gives you a recovery key — that is the only other way in, and it exists precisely because we cannot help you."
                )

                Button("Create the vault") {
                    Task { await model.createVault(passphrase: passphrase) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(problem != nil)

                Button("Choose a different folder") { model.forgetFolder() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            .textFieldStyle(.roundedBorder)
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The single highest-consequence screen in the app.
///
/// The key is shown once. To leave, the counsellor has to type it back — not tick a box
/// saying they wrote it down. Everyone ticks the box; not everyone can type back something
/// they never copied, and finding that out now costs a minute, whereas finding it out in
/// three years costs every note they have.
struct RecoveryKeyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var typedBack = ""
    @State private var showingKey = true
    @State private var matches = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Your recovery key")
                    .font(.largeTitle.bold())
                Text("Write this on paper and keep it where you keep other confidential records. It is the only way back in if you forget your passphrase.")
                    .foregroundStyle(.secondary)

                if let key = model.pendingRecoveryKey {
                    RecoveryKeyConfirmation(
                        key: key,
                        typedBack: $typedBack,
                        showingKey: $showingKey,
                        matches: $matches
                    )
                }

                WarningBox(
                    symbol: "eye.slash",
                    title: "You will not see this again",
                    detail: "It is not stored anywhere we can read it, and it is not in a backup of this app. A photo of it on your phone is a copy of your clinical records — treat it that way."
                )

                Button("I have written it down") {
                    model.acknowledgeRecoveryKey()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!matches)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct WarningBox: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
