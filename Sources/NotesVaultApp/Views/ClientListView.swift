import SwiftUI
import NotesVaultCore

struct ClientListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var addingClient = false
    @State private var newCode = ""
    @State private var newCodeProblem: String?
    @State private var importing = false

    /// Which of the non-active groups the counsellor has opened. Paused and ended clients
    /// start collapsed, the way the tracker app shows them: they are the majority of a
    /// caseload after a few years and none of them are today's work.
    @State private var expanded: Set<ClientStatus> = []

    private var clients: [ClientSummary] {
        model.index.searchClients(search)
    }

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The groups with anybody in them, in status order. A status nobody has is not shown
    /// as an empty heading.
    private var groups: [(status: ClientStatus, clients: [ClientSummary])] {
        ClientStatus.allCases.compactMap { status in
            let matching = clients.filter { $0.status == status }
            return matching.isEmpty ? nil : (status, matching)
        }
    }

    /// Active is always open. The rest are open when the counsellor opened them — or while
    /// a search is running, because a search that silently hides its own matches behind a
    /// collapsed heading is worse than no grouping at all.
    private func isExpanded(_ status: ClientStatus) -> Bool {
        status == .active || isSearching || expanded.contains(status)
    }

    var body: some View {
        List {
            if !model.issues.isEmpty {
                Section {
                    NavigationLink {
                        IssueListView(issues: model.issues)
                    } label: {
                        Label("\(model.issues.count) file\(model.issues.count == 1 ? "" : "s") could not be read", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if clients.isEmpty {
                Section {
                    EmptyStateView(
                        symbol: search.isEmpty ? "person.badge.plus" : "magnifyingglass",
                        title: search.isEmpty ? "No clients yet" : "No match",
                        detail: search.isEmpty
                            ? "Add a client code to start. Use the same codes you already use — never a name."
                            : "No client code contains “\(search)”."
                    )
                    if search.isEmpty {
                        Button {
                            importing = true
                        } label: {
                            Label("Import notes you already have", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            } else {
                // Worked out once for the whole list. Asked per row, each answer re-reads
                // every note in the vault to find one client's, which on a full vault is the
                // list itself becoming slow to scroll.
                let outstanding = model.outstandingSessions()
                ForEach(groups, id: \.status) { group in
                    Section {
                        if isExpanded(group.status) {
                            ForEach(group.clients) { client in
                                NavigationLink {
                                    ClientDetailView(code: client.code)
                                } label: {
                                    ClientRow(
                                        client: client,
                                        policy: model.retentionPolicy,
                                        awaiting: outstanding[client.code]?.count ?? 0
                                    )
                                }
                            }
                        }
                    } header: {
                        groupHeader(group.status, count: group.clients.count)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Client code")
        .navigationTitle("Clients")
        .refreshable { await model.refreshIndex(force: true) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newCode = ""
                    newCodeProblem = nil
                    addingClient = true
                } label: {
                    Label("Add client", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $importing) {
            ImportView()
        }
        .alert("New client", isPresented: $addingClient) {
            TextField("Code, e.g. SM2", text: $newCode)
                .keyEntryStyle()
            Button("Cancel", role: .cancel) { }
            Button("Add") { addClient() }
        } message: {
            Text(newCodeProblem ?? "Letters and numbers only. Never a name — the code‑to‑person list belongs somewhere else.")
        }
    }

    /// A heading that is a button for everything except Active, which has nothing to
    /// collapse to — today's caseload is the reason the screen is open.
    @ViewBuilder
    private func groupHeader(_ status: ClientStatus, count: Int) -> some View {
        if status == .active || isSearching {
            HStack {
                Text(status.displayName)
                Spacer()
                Text("\(count)")
            }
        } else {
            Button {
                if expanded.contains(status) {
                    expanded.remove(status)
                } else {
                    expanded.insert(status)
                }
            } label: {
                HStack {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded.contains(status) ? 90 : 0))
                    Text(status.displayName)
                    Spacer()
                    Text("\(count)")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(status.displayName), \(count) client\(count == 1 ? "" : "s")")
            .accessibilityHint(expanded.contains(status) ? "Collapses this group" : "Expands this group")
        }
    }

    private func addClient() {
        do {
            let code = try ClientCode(newCode)
            newCodeProblem = nil
            Task { await model.createClient(code) }
        } catch {
            // Reported through the app's one error path rather than by re-presenting the
            // alert from inside its own dismissal, which does not reliably reappear.
            model.errorMessage = (error as? VaultError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct ClientRow: View {
    let client: ClientSummary
    let policy: RetentionPolicy
    /// Sessions their cadence says have happened with no note against them. Zero for a
    /// client with no schedule, which is every client until GroundWork's are synced in.
    var awaiting: Int = 0

    private var assessment: RetentionAssessment {
        RetentionEngine.assess(
            client: client.code,
            status: client.status,
            basis: client.retentionBasis,
            lastContact: client.lastContact,
            policy: policy
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(client.code.rawValue)
                    .font(.system(.headline, design: .monospaced))
                Spacer()
                StatusChip(status: client.status)
                if assessment.needsAttention {
                    RetentionChip(state: assessment.state)
                }
            }
            HStack(spacing: 10) {
                Text("\(client.noteCount) note\(client.noteCount == 1 ? "" : "s")")
                if let last = client.lastContact {
                    Text("Last \(Formatted.date(last))")
                }
                if client.supersededCount > 0 {
                    Text("\(client.supersededCount) corrected")
                }
                if awaiting > 0 {
                    Text("\(awaiting) to write up")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct IssueListView: View {
    let issues: [VaultIssue]

    var body: some View {
        List(issues) { issue in
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.location)
                    .font(.system(.subheadline, design: .monospaced))
                Text(issue.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Unreadable files")
    }
}
