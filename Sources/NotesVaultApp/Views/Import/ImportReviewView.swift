import SwiftUI
import UniformTypeIdentifiers
import NotesVaultCore

// MARK: - Review

struct ImportReviewView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var importer: ImportModel

    var body: some View {
        List {
            Section {
                LabeledContent("Found", value: "\(importer.plan.totalItemCount) note\(importer.plan.totalItemCount == 1 ? "" : "s") in \(importer.summaries.count) file\(importer.summaries.count == 1 ? "" : "s")")
                if importer.plan.duplicatesCollapsed > 0 {
                    Text("\(importer.plan.duplicatesCollapsed) were the same note twice and have been collapsed into one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Toggle("Read 06/07/2026 as 6 July", isOn: Binding(
                    get: { importer.options.dayFirst },
                    set: { value in
                        importer.options.dayFirst = value
                        Task { await importer.reread() }
                    }
                ))
                Picker("Group notes by", selection: Binding(
                    get: { importer.options.grouping },
                    set: { value in
                        importer.options.grouping = value
                        Task { await importer.reread() }
                    }
                )) {
                    Text("The folder each file is in").tag(ImportGrouping.folder)
                    Text("Each file's own name").tag(ImportGrouping.filename)
                    Text("All of it is one client").tag(ImportGrouping.wholeSelection("Everything you chose"))
                }
                Toggle("Split long documents at each dated entry", isOn: Binding(
                    get: { importer.options.splitLongDocuments },
                    set: { value in
                        importer.options.splitLongDocuments = value
                        Task { await importer.reread() }
                    }
                ))
            } header: {
                Text("What was found")
            } footer: {
                Text("Nothing has been written yet. Give each group a client code below, then check the notes before importing.")
            }

            if !importer.plan.issues.isEmpty {
                Section("Left out") {
                    ForEach(importer.plan.issues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.location).font(.system(.footnote, design: .monospaced))
                            Text(issue.message).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !importer.plan.fieldCandidates.isEmpty {
                Section {
                    ForEach(importer.plan.fieldCandidates) { candidate in
                        ImportFieldRow(importer: importer, candidate: candidate)
                    }
                } header: {
                    Text("Details written above the notes")
                } footer: {
                    Text("Your notes start with lines like “Session number: 4”. Stored as a field, that value gets its own place on the note screen and can be read back on any device. Left alone, it stays in the note exactly as you wrote it — which is the default for anything this app has no field for.")
                }
            }

            Section {
                ForEach(importer.plan.groups) { group in
                    NavigationLink {
                        ImportGroupView(importer: importer, groupKey: group.key)
                    } label: {
                        ImportGroupRow(
                            group: group,
                            sensitiveCount: importer.sensitive[group.key]?.count ?? 0,
                            clashCount: importer.clashes.filter { clash in group.items.contains { $0.id == clash.itemID } }.count
                        )
                    }
                }
            } header: {
                Text("Clients")
            } footer: {
                Text("The names on the left are what your files call these people. They are never stored — only the code you choose is.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            BottomBar {
                VStack(alignment: .leading, spacing: 8) {
                    if importer.plan.canImport {
                        Text("\(importer.plan.readyItemCount) notes will be encrypted on this device and written to \(model.folderName ?? "your vault folder"). Your original files are not touched.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(importer.plan.blockers, id: \.self) { blocker in
                            Label(blocker, systemImage: "exclamationmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                    Button {
                        Task { await importer.run(using: model) }
                    } label: {
                        Text("Encrypt and import \(importer.plan.readyItemCount) notes")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!importer.plan.canImport)
                }
            }
        }
    }
}

/// One kind of metadata found across the import, and what to do with it.
struct ImportFieldRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var importer: ImportModel
    let candidate: ImportFieldCandidate

    private var isStored: Bool {
        if case .store? = importer.plan.fieldDecisions[candidate.key] { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.label).font(.subheadline.weight(.semibold))
                Spacer()
                Text(importer.decisionSummary(for: candidate))
                    .font(.caption)
                    .foregroundStyle(isStored ? Color.accentColor : Color.secondary)
            }
            Text("In \(candidate.occurrences) note\(candidate.occurrences == 1 ? "" : "s") · \(candidate.examples.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Menu("Change") {
                if let key = candidate.matchingFieldKey, let label = candidate.matchingFieldLabel {
                    if candidate.matchingFieldIsEnabled {
                        Button("Store as “\(label)”") {
                            importer.setFieldDecision(.store(fieldKey: key), for: candidate)
                        }
                    } else {
                        Button("Turn on “\(label)” and store it there") {
                            importer.enableField(for: candidate, using: model)
                        }
                    }
                } else {
                    Button("Add a field called “\(candidate.label)” (\(candidate.suggestedKind.displayName))") {
                        importer.addField(for: candidate, kind: candidate.suggestedKind, using: model)
                    }
                    Button("Add it as \(candidate.suggestedKind == .number ? "Text" : "a Number") instead") {
                        importer.addField(for: candidate, kind: candidate.suggestedKind == .number ? .text : .number, using: model)
                    }
                }
                Divider()
                Button("Leave it in the note") {
                    importer.setFieldDecision(.leaveInNote, for: candidate)
                }
            }
            .font(.footnote)
        }
        .padding(.vertical, 2)
    }
}

struct ImportGroupRow: View {
    let group: ImportGroup
    let sensitiveCount: Int
    let clashCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(group.key).font(.headline)
                Spacer()
                if group.isSkipped {
                    Text("Left out")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let code = group.assignedCode {
                    Text(code.rawValue)
                        .font(.system(.subheadline, design: .monospaced))
                        .padding(.vertical, 3).padding(.horizontal, 8)
                        .background(.tint.opacity(0.15), in: Capsule())
                } else {
                    Text("No code yet")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 10) {
                Text("\(group.items.count) note\(group.items.count == 1 ? "" : "s")")
                if let first = group.earliestSession, let last = group.latestSession {
                    Text("\(Formatted.date(first)) – \(Formatted.date(last))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if group.undatedCount > 0 {
                    WarningChip(text: "\(group.undatedCount) undated", colour: .orange)
                }
                if group.uncertainDateCount > group.undatedCount {
                    WarningChip(text: "\(group.uncertainDateCount - group.undatedCount) date guessed", colour: .yellow)
                }
                if sensitiveCount > 0 {
                    WarningChip(text: "\(sensitiveCount) identifying detail\(sensitiveCount == 1 ? "" : "s")", colour: .blue)
                }
                if clashCount > 0 {
                    WarningChip(text: "\(clashCount) already in vault", colour: .purple)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct WarningChip: View {
    let text: String
    let colour: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.vertical, 3).padding(.horizontal, 8)
            .background(colour.opacity(0.15), in: Capsule())
            .foregroundStyle(colour)
    }
}
