import SwiftUI
import UniformTypeIdentifiers
import NotesVaultCore
import NotesVaultCrypto

/// Bringing GroundWork's appointment schedules across.
///
/// The counsellor picks the file once; after that this screen re-reads whatever is at that
/// path. Nothing clinical comes in — client codes and cadence — and nothing goes back the
/// other way: GroundWork is never told a note was written. See `docs/schedule-sync.md`.
struct ScheduleSyncView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var picking = false
    @State private var plan: RosterSyncPlan?
    @State private var appliedCount: Int?
    @State private var checked = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let name = model.rosterFileName {
                        LabeledContent("File", value: name)
                        if let last = model.rosterLastSync {
                            LabeledContent("Last synced", value: Formatted.dateTime(last))
                        }
                        Button("Check for changes") { Task { await check() } }
                        Button("Use a different file") { picking = true }
                    } else {
                        Button {
                            picking = true
                        } label: {
                            Label("Choose GroundWork's schedule file", systemImage: "doc.badge.gearshape")
                        }
                    }
                } header: {
                    Text("Schedule file")
                } footer: {
                    Text(model.rosterFileName == nil
                         ? "In GroundWork, go to Settings › GroundWork Notes and tap Sync schedules. Save the file somewhere both apps can reach — iCloud Drive is the usual answer — then choose it here. You only do this once."
                         : "GroundWork writes over this file each time you sync there. Checking here re-reads it, so the two stay in step without picking a file again.")
                }

                if let applied = appliedCount {
                    Section {
                        Label(
                            applied == 0
                                ? "Nothing needed changing."
                                : "\(applied) client\(applied == 1 ? "" : "s") updated.",
                            systemImage: "checkmark.circle"
                        )
                        .foregroundStyle(.green)
                    }
                }

                if let plan, appliedCount == nil {
                    planSections(plan)
                } else if checked && plan == nil && model.rosterFileName != nil {
                    Section {
                        Text("That file could not be read. The error is above.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Sync schedules")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let plan, !plan.isEmpty, appliedCount == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            Task {
                                appliedCount = await model.applyScheduleSync(plan)
                            }
                        }
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.json]) { result in
                guard case let .success(url) = result else { return }
                Task {
                    appliedCount = nil
                    checked = true
                    plan = await model.chooseRosterFile(url)
                }
            }
            .task {
                // Opening the screen is itself a request to know whether anything changed.
                if model.rosterFileName != nil && !checked { await check() }
            }
        }
        .vaultSheet(minWidth: 560, minHeight: 520)
    }

    @ViewBuilder
    private func planSections(_ plan: RosterSyncPlan) -> some View {
        if plan.isEmpty {
            Section {
                Label("Everything already matches GroundWork.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("\(plan.unchanged) client\(plan.unchanged == 1 ? "" : "s") checked.")
            }
        } else {
            Section {
                ForEach(plan.changes) { change in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(change.event.client.rawValue)
                                .font(.system(.subheadline, design: .monospaced))
                            Spacer()
                            if change.kind == .created {
                                Text("new")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                        }
                        Text(change.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            } header: {
                Text("\(plan.changes.count) to update")
            } footer: {
                Text("Nothing is written until you tap Apply. \(plan.unchanged) other client\(plan.unchanged == 1 ? " is" : "s are") already up to date.")
            }

            // A status coming across as Ended starts a retention clock, which is a
            // consequence worth seeing before it happens rather than reading about later.
            if plan.changes.contains(where: { $0.event.status == .ended }) {
                Section {
                    Label(
                        "Some of these are marked as ended in GroundWork. Applying that starts their retention clock here — it flags them for review, and never destroys anything on its own.",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            if !plan.untouched.isEmpty {
                Section {
                    Text(plan.untouched.map(\.rawValue).joined(separator: ", "))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Not in the file")
                } footer: {
                    Text("These clients are in the vault but not in GroundWork's schedules. They are left exactly as they are.")
                }
            }
        }

        if !plan.issues.isEmpty {
            Section {
                ForEach(plan.issues) { issue in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(issue.location)
                            .font(.system(.footnote, design: .monospaced))
                        Text(issue.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Skipped")
            }
        }
    }

    private func check() async {
        checked = true
        appliedCount = nil
        plan = await model.planScheduleSync()
    }
}
