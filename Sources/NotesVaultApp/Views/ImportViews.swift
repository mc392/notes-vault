import SwiftUI
import UniformTypeIdentifiers
import NotesVaultCore

/// The import flow, start to finish.
///
/// The shape of this screen is an argument, not just a wizard. A counsellor moving five
/// years of clinical records into an app they installed last week is being asked for a
/// great deal of trust, and the honest way to earn it is to show the work: what was found,
/// what will be written, what actually landed on disk, and what is still lying around
/// unencrypted afterwards. Every claim this screen makes is one the app can demonstrate.
struct ImportView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var importer = ImportModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch importer.stage {
                case .choose:   ImportStartView(importer: importer)
                case .reading:  ImportBusyView(message: "Reading your files…")
                case .mapping:  ImportMappingView(importer: importer)
                case .review:   ImportReviewView(importer: importer)
                case .running:  ImportProgressView(importer: importer)
                case .finished: ImportSummaryView(importer: importer)
                }
            }
            .navigationTitle("Import notes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if importer.stage == .finished {
                        Button("Done") { dismiss() }
                    } else if importer.stage != .running {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .alert(
                "That didn't work",
                isPresented: Binding(
                    get: { importer.errorMessage != nil },
                    set: { if !$0 { importer.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { importer.errorMessage = nil }
            } message: {
                Text(importer.errorMessage ?? "")
            }
        }
        .vaultSheet(minWidth: 720, minHeight: 620)
        .environmentObject(model)
    }
}

// MARK: - Start

private struct ImportStartView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var importer: ImportModel

    @State private var pickingFiles = false
    @State private var pickingFolder = false

    var body: some View {
        List {
            Section {
                Button {
                    pickingFolder = true
                } label: {
                    Label("Choose a folder of notes", systemImage: "folder")
                }
                Button {
                    pickingFiles = true
                } label: {
                    Label("Choose files", systemImage: "doc")
                }
            } footer: {
                Text("A folder with one subfolder per client is the easiest shape to bring in — but a single spreadsheet, or a pile of documents, works too.")
            }

            Section("What happens to your files") {
                PromiseRow(
                    symbol: "lock.laptopcomputer",
                    title: "Everything is read on this device",
                    detail: "Your files are opened here, in this app, and never sent anywhere. This app has no permission to use the network at all — if a future version of it tried, macOS would refuse the connection."
                )
                PromiseRow(
                    symbol: "wifi.slash",
                    title: "You can do this with the internet off",
                    detail: "Nothing about importing needs a connection. If you would rather prove that than take it on trust, turn Wi‑Fi off first — the import will work exactly the same."
                )
                PromiseRow(
                    symbol: "lock.doc",
                    title: "Encrypted before it is stored, not after",
                    detail: "Each note is encrypted in memory and only then written into your vault folder. Your sync folder never holds a readable copy, so there is no window in which iCloud could pick one up."
                )
                PromiseRow(
                    symbol: "eye.slash",
                    title: "You will see what was written",
                    detail: "As each note goes in, this screen shows the scrambled filename it was stored under and confirms the file holds none of the note's own words. Nothing here asks to be believed."
                )
                PromiseRow(
                    symbol: "doc.on.doc",
                    title: "Your originals are left exactly where they are",
                    detail: "Nothing is moved, renamed or deleted. When the import is done and you have checked it, deleting the originals is your decision to make — and this screen will remind you that they are still unencrypted until you do."
                )
            }

            Section {
                DisclosureGroup("What can be read") {
                    FormatList()
                }
                DisclosureGroup("Getting notes out of Apple Notes") {
                    AppleNotesGuide()
                }
            }
        }
        .fileImporter(
            isPresented: $pickingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handle(result)
        }
        .fileImporter(
            isPresented: $pickingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            handle(result)
        }
    }

    private func handle(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            Task {
                await importer.load(
                    urls: urls,
                    existingClients: model.existingClientCodes,
                    existingNotes: model.index.notes
                )
            }
        case let .failure(error):
            importer.errorMessage = error.localizedDescription
        }
    }
}

private struct PromiseRow: View {
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
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct FormatList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Word documents, Excel workbooks, CSV files, plain text, Markdown, rich text (including notes dragged out of Notes or TextEdit), web pages and HTML exports, Evernote exports, and PDFs that hold real text.")
                .font(.footnote)
            Text("Not readable: older .doc files, Pages and Numbers documents, and PDFs that are scans or photographs of handwriting. This app has no camera permission and does not read handwriting — open those in the app that made them and save a copy as Word, text or CSV.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct AppleNotesGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Notes has no bulk export, so there are two routes — both on a Mac:")
                .font(.footnote)
            Label("Select the notes for one client in Notes, drag them onto a folder in Finder, then choose that folder here. Each note arrives as its own file.", systemImage: "1.circle")
                .font(.footnote)
            Label("Or open a note, select all, copy, and paste into a new TextEdit document — one document per client, with a date at the start of each session.", systemImage: "2.circle")
                .font(.footnote)
            Text("Afterwards, remember Notes keeps deleted notes in Recently Deleted for 30 days. Empty it once you are satisfied the import is right.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct ImportBusyView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Mapping a spreadsheet

private struct ImportMappingView: View {
    @ObservedObject var importer: ImportModel

    var body: some View {
        List {
            Section {
                Text("A spreadsheet can hold anything, so nothing is assumed. Check that each column below is what this app thinks it is — a column matched wrongly would file one client's session in another client's record.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach($importer.tables) { $pending in
                Section(pending.file) {
                    ColumnPicker(title: "Client", columns: pending.table.columns, selection: $pending.mapping.client)
                    ColumnPicker(title: "Session date", columns: pending.table.columns, selection: $pending.mapping.date)
                    ColumnPicker(title: "Time (optional)", columns: pending.table.columns, selection: $pending.mapping.time)
                    ColumnPicker(title: "Title (optional)", columns: pending.table.columns, selection: $pending.mapping.title)

                    ForEach(pending.table.columns.indices, id: \.self) { index in
                        Toggle(isOn: Binding(
                            get: { pending.mapping.body.contains(index) },
                            set: { include in
                                if include {
                                    pending.mapping.body = (pending.mapping.body + [index]).sorted()
                                } else {
                                    pending.mapping.body.removeAll { $0 == index }
                                }
                            }
                        )) {
                            Text("Use “\(pending.table.columns[index])” as the note")
                        }
                    }

                    if let first = pending.table.rows.first {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("First row reads as").font(.caption).foregroundStyle(.secondary)
                            Text(preview(pending, row: first))
                                .font(.system(.footnote, design: .monospaced))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            BottomBar {
                Button("Continue") {
                    Task { await importer.applyMappings() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(importer.tables.contains { !$0.mapping.isUsable })
            }
        }
    }

    private func preview(_ pending: PendingTable, row: [String]) -> String {
        let client = pending.mapping.client.map { pending.table.cell(row, at: $0) } ?? "—"
        let date = pending.mapping.date.map { pending.table.cell(row, at: $0) } ?? "—"
        let body = pending.mapping.body
            .map { pending.table.cell(row, at: $0) }
            .joined(separator: " / ")
        return "\(client) · \(date)\n\(body.prefix(120))"
    }
}

private struct ColumnPicker: View {
    let title: String
    let columns: [String]
    @Binding var selection: Int?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("None").tag(Int?.none)
            ForEach(columns.indices, id: \.self) { index in
                Text(columns[index]).tag(Int?.some(index))
            }
        }
    }
}

// MARK: - Review

private struct ImportReviewView: View {
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

private struct ImportGroupRow: View {
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

private struct WarningChip: View {
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

// MARK: - One group

private struct ImportGroupView: View {
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
            importer.errorMessage = (error as? VaultError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct ImportItemRow: View {
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

private struct SetSessionDateView: View {
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

// MARK: - Running

private struct ImportProgressView: View {
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

private struct ImportSummaryView: View {
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
private struct ImportLedgerView: View {
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

// MARK: - Shared

private struct BottomBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
