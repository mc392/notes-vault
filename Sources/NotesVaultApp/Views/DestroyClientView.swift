import SwiftUI
import UniformTypeIdentifiers
import NotesVaultCore

/// The full gauntlet before anything is destroyed.
///
/// A summary of exactly what goes, an export-first button, an acknowledgement, the client's
/// own code typed out, and a three-second arming delay on the final button. This is the
/// same shape GroundWork uses for its own removal routes, and it exists because the
/// compliance requirement is *deliberate* destruction — a single tap that empties a
/// clinical record is not deliberate no matter how red it is.
struct DestroyClientView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let client: ClientSummary
    /// Called after a successful destruction so the parent can dismiss too — the client
    /// being shown behind this sheet no longer exists.
    let onDestroyed: () -> Void

    @State private var acknowledged = false
    @State private var typed = ""
    @State private var armed = false
    @State private var exporting = false
    @State private var exportedCount: Int?

    private var confirmationMatches: Bool {
        typed.trimmingCharacters(in: .whitespaces).uppercased() == client.code.rawValue
    }

    private var ready: Bool { acknowledged && confirmationMatches && armed }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This removes, permanently:")
                            .font(.subheadline.weight(.semibold))
                        Text("· \(client.noteCount) note\(client.noteCount == 1 ? "" : "s")")
                        if client.supersededCount > 0 {
                            Text("· \(client.supersededCount) earlier version\(client.supersededCount == 1 ? "" : "s")")
                        }
                        Text("· the folder for \(client.code.rawValue) and its status history")
                        if let first = client.firstContact, let last = client.lastContact {
                            Text("· covering \(Formatted.date(first)) to \(Formatted.date(last))")
                        }
                    }
                    .font(.subheadline)
                }

                Section {
                    Button {
                        exporting = true
                    } label: {
                        Label("Export everything first", systemImage: "square.and.arrow.up")
                    }
                    if let exportedCount {
                        Label("\(exportedCount) files written.", systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                } footer: {
                    Text("Exports the whole vault as plain files. Strongly recommended — there is no undo and no copy held anywhere else.")
                }

                Section {
                    Toggle(isOn: $acknowledged) {
                        Text("I understand these notes cannot be recovered, by me or by anyone else.")
                            .font(.subheadline)
                    }
                    TypedConfirmation(
                        phrase: client.code.rawValue,
                        prompt: "Type the client code to confirm:",
                        typed: $typed
                    )
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            await model.destroy(client: client.code)
                            onDestroyed()
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Text("Destroy these records")
                            Spacer()
                            if acknowledged && confirmationMatches && !armed {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(!ready)
                } footer: {
                    if acknowledged && confirmationMatches && !armed {
                        Text("Pausing for a moment before this becomes available.")
                    }
                }
            }
            .navigationTitle("Destroy records")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: acknowledged) { _, _ in rearm() }
            .onChange(of: typed) { _, _ in rearm() }
            .fileImporter(isPresented: $exporting, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result {
                    Task { exportedCount = await model.export(to: url) }
                }
            }
        }
        .vaultSheet(minHeight: 600)
    }

    /// Three seconds between "everything is filled in" and "the button works", restarted
    /// whenever the inputs change. Long enough to interrupt a reflex, short enough not to
    /// feel like a punishment.
    private func rearm() {
        armed = false
        guard acknowledged && confirmationMatches else { return }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if acknowledged && confirmationMatches { armed = true }
        }
    }
}
