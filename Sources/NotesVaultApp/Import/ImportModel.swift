import Foundation
import SwiftUI
import NotesVaultCore

/// One table waiting for its columns to be matched up.
struct PendingTable: Identifiable {
    let id = UUID()
    let file: String
    let modified: Date?
    let table: DelimitedTable
    var mapping: ColumnMapping
}

/// What one file turned into, for the "here is what I found" list.
struct FileSummary: Identifiable {
    let id = UUID()
    let name: String
    let format: ImportFormat
    let itemCount: Int
    let problem: String?
}

/// The import flow.
///
/// Holds the counsellor's files **in memory only**, from the moment they are picked to the
/// moment the sheet closes. Nothing is written anywhere until the plan is confirmed, and
/// then the only thing written is ciphertext, through the same `VaultStore` the note editor
/// uses. There is no staging folder, no temporary copy and no cache — which is what makes
/// "cancel" mean cancel.
@MainActor
final class ImportModel: ObservableObject {
    enum Stage: Equatable {
        case choose
        case reading
        /// At least one spreadsheet needs its columns matched up.
        case mapping
        case review
        case running
        case finished
    }

    @Published var stage: Stage = .choose
    @Published var options = ImportOptions()
    @Published var summaries: [FileSummary] = []
    @Published var tables: [PendingTable] = []
    @Published var plan = ImportPlan(groups: [], issues: [], options: .default)
    @Published var report: ImportReport?
    @Published var completed = 0
    @Published var total = 0
    @Published var errorMessage: String?
    /// Identifying details found in the notes about to be imported, by group.
    @Published var sensitive: [String: [SensitiveMatch]] = [:]
    @Published var clashes: [ImportPlan.Clash] = []

    /// The picked files, kept only while this sheet is open.
    private var files: [ImportFile] = []
    private var existingClients: [ClientCode] = []
    private var existingNotes: [NoteIndexEntry] = []
    /// The fields this device has, so metadata found in the notes can be matched against
    /// them. Kept in step with `AppModel.noteFields` as the counsellor adds fields here.
    private var noteFields = NoteFieldSettings.default

    var hasFiles: Bool { !files.isEmpty }

    // MARK: - Reading

    func load(
        urls: [URL],
        existingClients: [ClientCode],
        existingNotes: [NoteIndexEntry],
        noteFields: NoteFieldSettings
    ) async {
        self.existingClients = existingClients
        self.existingNotes = existingNotes
        self.noteFields = noteFields
        stage = .reading

        let maximum = options.maximumFileBytes
        let collection = await Task.detached(priority: .userInitiated) {
            ImportFileCollector.collect(from: urls, maximumFileBytes: maximum)
        }.value

        files = collection.files
        guard !files.isEmpty else {
            stage = .choose
            errorMessage = collection.issues.first?.message
                ?? "Nothing readable was found in what you chose."
            return
        }
        await reread(extraIssues: collection.issues)
    }

    /// Re-reads everything from the files already in memory. Called when the counsellor
    /// changes how dates are read or how the files are grouped — both of which change every
    /// proposed note, so re-reading is the only honest way to show the result.
    func reread(extraIssues: [VaultIssue] = []) async {
        let files = self.files
        let options = self.options
        // Whether the counsellor has already been through the mapping screen. Re-reading
        // must not send them back through it, and must not throw away the mapping they
        // made — changing how dates are read has nothing to do with which column is which.
        let alreadyMapped = stage == .review
        let existingMappings = Dictionary(tables.map { ($0.file, $0.mapping) }, uniquingKeysWith: { first, _ in first })

        let outcome = await Task.detached(priority: .userInitiated) { () -> (results: [ImportFileResult], tables: [PendingTable]) in
            // `existingMappings` is a plain dictionary of value types, captured by copy.
            var results: [ImportFileResult] = []
            var tables: [PendingTable] = []
            for file in files {
                let result = ImportReader.read(file, options: options) { file in
                    try PDFTextExtractor.text(from: file.data)
                }
                if let table = result.table {
                    tables.append(PendingTable(
                        file: file.name,
                        modified: file.modified,
                        table: table,
                        mapping: existingMappings[file.name] ?? ColumnMapping.suggest(for: table)
                    ))
                }
                results.append(result)
            }
            return (results, tables)
        }.value

        summaries = outcome.results.map { result in
            FileSummary(
                name: result.file,
                format: result.format,
                itemCount: result.needsMapping ? 0 : result.items.count,
                problem: result.issues.first?.message
            )
        }
        tables = outcome.tables

        if tables.isEmpty {
            buildPlan(from: outcome.results, extraIssues: extraIssues)
            stage = .review
        } else if alreadyMapped {
            await applyMappings()
        } else {
            // Hold the plan back until the columns are settled: a table mapped wrongly puts
            // one client's session in another client's record.
            plan = ImportPlan(groups: [], issues: extraIssues, options: options)
            stage = .mapping
        }
    }

    /// The counsellor has matched up every table's columns.
    func applyMappings() async {
        let files = self.files
        let tables = self.tables
        let options = self.options

        let results = await Task.detached(priority: .userInitiated) { () -> [ImportFileResult] in
            var results: [ImportFileResult] = []
            for file in files {
                let read = ImportReader.read(file, options: options) { file in
                    try PDFTextExtractor.text(from: file.data)
                }
                guard let table = read.table else {
                    results.append(read)
                    continue
                }
                let pending = tables.first { $0.file == file.name }
                let mapped = TabularImport.items(
                    from: table,
                    mapping: pending?.mapping ?? ColumnMapping.suggest(for: table),
                    container: file.name,
                    options: options,
                    modified: file.modified
                )
                results.append(ImportFileResult(
                    file: file.name,
                    format: read.format,
                    items: mapped.items,
                    table: nil,
                    issues: read.issues + mapped.issues
                ))
            }
            return results
        }.value

        summaries = results.map {
            FileSummary(name: $0.file, format: $0.format, itemCount: $0.items.count, problem: $0.issues.first?.message)
        }
        buildPlan(from: results, extraIssues: plan.issues)
        stage = .review
    }

    private func buildPlan(from results: [ImportFileResult], extraIssues: [VaultIssue]) {
        // Re-reading — because the date setting or the grouping changed — must not throw
        // away decisions the counsellor has already made. Forty groups is a long way to
        // get through twice.
        let decided = Dictionary(plan.groups.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let fieldDecisions = plan.fieldDecisions
        var built = ImportPlan.make(
            results: results,
            existingClients: existingClients,
            noteFields: noteFields,
            options: options
        )
        for index in built.groups.indices {
            guard let previous = decided[built.groups[index].key] else { continue }
            built.groups[index].assignedCode = previous.assignedCode
            built.groups[index].isSkipped = previous.isSkipped
            built.groups[index].replaceNamesInBodies = previous.replaceNamesInBodies
        }
        for (key, decision) in fieldDecisions where built.fieldCandidates.contains(where: { $0.key == key }) {
            built.fieldDecisions[key] = decision
        }
        built.issues.append(contentsOf: extraIssues)
        plan = built
        refreshClashes()
        Task { await scanForIdentifyingDetails() }
    }

    /// Looks for identifying details in every note about to be imported.
    ///
    /// Off the main actor and run once per plan, not once per tap: it is a handful of
    /// regular expressions over what might be four hundred notes, and doing it every time
    /// a client code is chosen would make the review screen stutter exactly when the
    /// counsellor is reading it carefully.
    private func scanForIdentifyingDetails() async {
        let groups = plan.groups
        let found = await Task.detached(priority: .utility) { () -> [String: [SensitiveMatch]] in
            var found: [String: [SensitiveMatch]] = [:]
            for group in groups {
                var matches: [SensitiveMatch] = []
                var seen = Set<String>()
                for item in group.items.prefix(200) {
                    for match in SensitiveTextScan.scan(item.body, names: group.nameCandidates)
                    where seen.insert(match.id).inserted {
                        matches.append(match)
                    }
                }
                if !matches.isEmpty { found[group.key] = matches }
            }
            return found
        }.value
        // The plan may have moved on while this ran — a re-read replaces every group — so
        // only keep what still applies.
        let live = Set(plan.groups.map(\.key))
        sensitive = found.filter { live.contains($0.key) }
    }

    /// Notes the vault may already hold at the same client and minute. Cheap, and it
    /// depends on the codes just chosen, so it runs on every change.
    private func refreshClashes() {
        clashes = plan.clashes(with: existingNotes)
    }

    // MARK: - Editing the plan

    func assign(_ code: ClientCode?, to group: ImportGroup) {
        plan.assign(code, toGroup: group.key)
        refreshClashes()
    }

    func setSkipped(_ skipped: Bool, for group: ImportGroup) {
        plan.setSkipped(skipped, forGroup: group.key)
        refreshClashes()
    }

    func setReplaceNames(_ replace: Bool, for group: ImportGroup) {
        guard let index = plan.groups.firstIndex(where: { $0.key == group.key }) else { return }
        plan.groups[index].replaceNamesInBodies = replace
    }

    func setDate(_ date: Date, for item: ImportedItem) {
        plan.setDate(date, forItem: item.id)
        refreshClashes()
    }

    func remove(_ item: ImportedItem) {
        plan.removeItem(item.id)
        refreshClashes()
    }

    // MARK: - Metadata found in the notes

    func setFieldDecision(_ decision: ImportFieldDecision, for candidate: ImportFieldCandidate) {
        plan.setFieldDecision(decision, forKey: candidate.key)
    }

    /// Adds a field this device has never had, and stores the metadata in it.
    ///
    /// The field is a device setting like any other, so this is the same change the
    /// counsellor could make in Settings — made here because here is where they found out
    /// they wanted it.
    func addField(for candidate: ImportFieldCandidate, kind: NoteFieldKind, using model: AppModel) {
        do {
            let field = try model.noteFields.addCustomField(label: candidate.label, kind: kind)
            noteFields = model.noteFields
            setFieldDecision(.store(fieldKey: field.key), for: candidate)
        } catch {
            errorMessage = (error as? VaultError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Switches on a field that already exists but has never been turned on.
    func enableField(for candidate: ImportFieldCandidate, using model: AppModel) {
        guard let key = candidate.matchingFieldKey else { return }
        model.noteFields.setEnabled(true, forKey: key)
        noteFields = model.noteFields
        setFieldDecision(.store(fieldKey: key), for: candidate)
    }

    /// How the decision for one candidate reads on screen.
    func decisionSummary(for candidate: ImportFieldCandidate) -> String {
        guard case let .store(fieldKey)? = plan.fieldDecisions[candidate.key] else {
            return "Left in the note"
        }
        let label = noteFields.fields.first { $0.key == fieldKey }?.label ?? fieldKey
        return "Stored as “\(label)”"
    }

    /// Everything the counsellor's own files call this person — shown so they can see
    /// exactly which words the app will take out of the notes.
    func replacedWords(for group: ImportGroup) -> [String] {
        SensitiveTextScan.nameWords(from: group.nameCandidates)
    }

    // MARK: - Running

    func run(using model: AppModel) async {
        guard plan.canImport else { return }
        stage = .running
        completed = 0
        total = plan.readyItemCount

        let report = await model.runImport(plan: plan) { [weak self] done, count in
            Task { @MainActor in
                self?.completed = done
                self?.total = count
            }
        }
        self.report = report
        stage = .finished
        // The files are the counsellor's, and they are still theirs. All this drops is our
        // copy of them out of memory.
        files = []
    }

    func reset() {
        files = []
        summaries = []
        tables = []
        plan = ImportPlan(groups: [], issues: [], options: options)
        report = nil
        sensitive = [:]
        clashes = []
        completed = 0
        total = 0
        stage = .choose
    }
}
