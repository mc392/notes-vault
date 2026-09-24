import SwiftUI
import UniformTypeIdentifiers
import NotesVaultCore

// MARK: - Running

struct ImportProgressView: View {
    @ObservedObject var importer: ImportModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                ProgressView(value: Double(importer.completed), total: Double(max(importer.total, 1)))
                Text("\(importer.completed) of \(importer.total) encrypted and written")
                    .font(.callout)
                Text("Each note is encrypted in memory, written as a scrambled filename, then read back out of the vault to check it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            Spacer()
        }
    }
}

// MARK: - Finished

struct ImportSummaryView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var importer: ImportModel
    @State private var showingLedger = false

    private var report: ImportReport? { importer.report }

    var body: some View {
        List {
            if let report {
                Section {
                    Label(
                        "\(report.written) note\(report.written == 1 ? "" : "s") imported",
                        systemImage: "checkmark.seal"
                    )
                    .font(.headline)
                    .foregroundStyle(report.failed == 0 ? Color.green : Color.orange)

                    if report.fullyVerified {
                        Label("Every note was read back out of the vault and matched what went in.", systemImage: "arrow.uturn.backward")
                            .font(.footnote)
                    }
                    if report.everyFileHeldNoPlaintext {
                        Label("None of the files written holds any of your notes' own words.", systemImage: "lock.doc")
                            .font(.footnote)
                    }
                    if importer.plan.skippedItemCount > 0 {
                        Label("\(importer.plan.skippedItemCount) notes were left out on purpose, in \(importer.plan.skippedGroups.count) group\(importer.plan.skippedGroups.count == 1 ? "" : "s"). They are still in your original files.", systemImage: "tray")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !report.newClients.isEmpty {
                        Label("New clients: \(report.newClients.map(\.rawValue).joined(separator: ", "))", systemImage: "person.badge.plus")
                            .font(.footnote)
                    }
                    Button("Show what was written") { showingLedger = true }
                        .font(.footnote)
                }

                if report.failed > 0 {
                    Section("Not imported") {
                        ForEach(report.outcomes.filter { !$0.succeeded }) { outcome in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(outcome.origin.description).font(.system(.footnote, design: .monospaced))
                                Text(outcome.error ?? "Unknown problem").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Text("The files you imported from are still where they were, and still unencrypted. That is deliberate — nothing gets deleted on your behalf. Now that the notes are in the vault, they are the copy worth keeping.")
                    .font(.footnote)
                Label("Check a few of the imported notes read correctly.", systemImage: "1.circle")
                    .font(.footnote)
                Label("Delete the original files, and empty the Trash.", systemImage: "2.circle")
                    .font(.footnote)
                Label("If they came from Apple Notes, empty Recently Deleted there too — it keeps them for 30 days.", systemImage: "3.circle")
                    .font(.footnote)
                Label("If they were ever emailed or backed up somewhere, deal with those copies as well.", systemImage: "4.circle")
                    .font(.footnote)
            } header: {
                Text("One thing left")
            } footer: {
                Text("This app cannot see or reach those copies, so it cannot do this part for you.")
            }

            Section {
                Button("Import something else") { importer.reset() }
            }
        }
        .sheet(isPresented: $showingLedger) {
            ImportLedgerView(outcomes: report?.outcomes ?? [])
        }
    }
}

/// The receipt: every note, the name it was stored under, and what the file holds.
struct ImportLedgerView: View {
    let outcomes: [ImportOutcome]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(outcomes) { outcome in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(outcome.client.rawValue).font(.system(.subheadline, design: .monospaced))
                        Text(Formatted.date(outcome.session)).font(.subheadline)
                        Spacer()
                        Image(systemName: outcome.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(outcome.succeeded ? Color.green : Color.orange)
                    }
                    if let stored = outcome.storedName {
                        Text("stored as \(stored)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(outcome.plaintextBytes) bytes of note → \(outcome.storedBytes) bytes encrypted\(outcome.heldNoPlaintext ? ", none of its words in the file" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("from \(outcome.origin.description)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("What was written")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .vaultSheet(minWidth: 640, minHeight: 520)
    }
}
