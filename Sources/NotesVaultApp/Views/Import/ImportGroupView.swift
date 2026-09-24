import SwiftUI
import UniformTypeIdentifiers
import NotesVaultCore

// MARK: - One group

struct ImportGroupView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var importer: ImportModel
    let groupKey: String

    @State private var typingCode = false
    @State private var typedCode = ""
    @State private var datingItem: ImportedItem?

    private var group: ImportGroup? { importer.plan.groups.first { $0.key == groupKey } }

    var body: some View {
        Group {
            if let group {
                List {
                    Section {
                        codeMenu(for: group)
                        if group.assignedCode == nil, !group.suggestion.existing.isEmpty {
                            Text("You already have \(group.suggestion.existing.map(\.rawValue).joined(separator: ", ")) in this vault. If this is the same person, choose their existing code so the record stays in one place.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Client code")
                    } footer: {
                        Text("“\(group.key)” is what your files call them. It is never written to the vault.")
                    }

                    if let code = group.assignedCode {
                        Section {
                            Toggle("Replace their name with \(code.rawValue) in the notes", isOn: Binding(
                                get: { group.replaceNamesInBodies },
                                set: { importer.setReplaceNames($0, for: group) }
                            ))
                            let words = importer.replacedWords(for: group)
                            if !words.isEmpty {
                                Text("Words that will be replaced: \(words.joined(separator: ", "))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Names")
                        } footer: {
                            Text("Your old notes were written somewhere with no rule against names. Everything imported is encrypted either way — this just keeps the vault to codes, the way the rest of the app works.")
                        }
                    }

                    if let matches = importer.sensitive[group.key], !matches.isEmpty {
                        Section {
                            ForEach(matches.prefix(30)) { match in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(match.kind.displayName).font(.caption).foregroundStyle(.secondary)
                                    Text(match.context).font(.footnote)
                                }
                            }
                            if matches.count > 30 {
                                Text("…and \(matches.count - 30) more.").font(.footnote).foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Identifying details found")
                        } footer: {
                            Text("Flagged, not removed. These are your clinical notes and it is not this app's place to edit them — but they are worth knowing about before they go in, because a note that names its subject is a note that names its subject even when it is encrypted.")
                        }
                    }

                    Section("Notes") {
                        ForEach(group.items) { item in
                            ImportItemRow(
                                item: item,
                                isClash: importer.clashes.contains { $0.itemID == item.id }
                            )
                            .swipeActions {
                                Button("Leave out", role: .destructive) { importer.remove(item) }
                                Button("Set date") { datingItem = item }
                            }
                            .contextMenu {
                                Button("Set the session date…") { datingItem = item }
                                Button("Leave this one out", role: .destructive) { importer.remove(item) }
                            }
                        }
                    }
                }
                .navigationTitle(group.key)
            } else {
                EmptyStateView(symbol: "tray", title: "Nothing left", detail: "Every note in this group was left out.")
            }
        }
        .alert("Client code", isPresented: $typingCode) {
            TextField("e.g. SM2", text: $typedCode).keyEntryStyle()
            Button("Cancel", role: .cancel) { }
            Button("Use it") { applyTypedCode() }
        } message: {
            Text("Letters and numbers only, and never a name.")
        }
        .sheet(item: $datingItem) { item in
            SetSessionDateView(item: item) { date in
                importer.setDate(date, for: item)
                datingItem = nil
            }
        }
    }

    @ViewBuilder
    private func codeMenu(for group: ImportGroup) -> some View {
        Menu {
            ForEach(group.suggestion.existing, id: \.self) { code in
                Button("\(code.rawValue) — already in your vault") { importer.assign(code, to: group) }
            }
            if let proposed = group.suggestion.proposed {
                Button("\(proposed.rawValue) — a new client") { importer.assign(proposed, to: group) }
            }
            Divider()
            Menu("Another existing client") {
                ForEach(model.existingClientCodes, id: \.self) { code in
                    Button(code.rawValue) { importer.assign(code, to: group) }
                }
            }
            Button("Type a code…") {
                typedCode = group.assignedCode?.rawValue ?? ""
                typingCode = true
            }
            Divider()
            if group.isSkipped {
                Button("Bring this group back in") { importer.setSkipped(false, for: group) }
            } else {
                Button("Leave this group out of the import") { importer.setSkipped(true, for: group) }
            }
            if group.assignedCode != nil {
                Button("Clear", role: .destructive) { importer.assign(nil, to: group) }
            }
        } label: {
            LabeledContent("Import as", value: group.isSkipped ? "Left out" : (group.assignedCode?.rawValue ?? "Choose…"))
        }
    }

    private func applyTypedCode() {
        guard let group else { return }
        do {
            importer.assign(try ClientCode(typedCode), to: group)
        } catch {
            importer.errorMessage = error.localizedDescription
        }
    }
}

struct ImportItemRow: View {
    let item: ImportedItem
    let isClash: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let date = item.date.date {
                    Text(Formatted.dateTime(date))
                        .font(.subheadline.weight(item.date.isCertain ? .regular : .semibold))
                        .foregroundStyle(item.date.isCertain ? Color.primary : Color.orange)
                } else {
                    Text("No date").font(.subheadline).foregroundStyle(.orange)
                }
                Spacer()
                Text("\(item.wordCount) words").font(.caption).foregroundStyle(.secondary)
            }
            Text(item.preview()).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 8) {
                Text(item.origin.description).font(.caption2).foregroundStyle(.tertiary)
                if !item.date.isCertain {
                    Text(item.date.explanation).font(.caption2).foregroundStyle(.orange)
                }
                if isClash {
                    Text("a note with this date is already in the vault").font(.caption2).foregroundStyle(.purple)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct SetSessionDateView: View {
    let item: ImportedItem
    let onSet: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Session", selection: $date)
                } header: {
                    Text("When was this session?")
                } footer: {
                    Text(item.preview(limit: 160))
                }
            }
            .navigationTitle("Session date")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { onSet(date) }
                }
            }
        }
        .vaultSheet(minWidth: 420, minHeight: 320)
        .onAppear { date = item.date.date ?? Date() }
    }
}
