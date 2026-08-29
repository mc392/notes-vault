import SwiftUI
import NotesVaultCore

struct ClientDetailView: View {
    @EnvironmentObject private var model: AppModel
    let code: ClientCode

    @State private var composing = false
    @State private var editingClient = false
    @State private var showingSuperseded = false

    private var client: ClientSummary? { model.index.client(code) }

    private var entries: [NoteIndexEntry] {
        showingSuperseded ? model.index.notes(for: code) : model.index.currentNotes(for: code)
    }

    private var supersededIDs: Set<NoteID> { model.index.supersededIDs }

    private var assessment: RetentionAssessment? {
        guard let client else { return nil }
        return RetentionEngine.assess(
            client: client.code,
            status: client.status,
            basis: client.retentionBasis,
            lastContact: client.lastContact,
            policy: model.retentionPolicy
        )
    }

    var body: some View {
        List {
            if let client, let assessment {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            StatusChip(status: client.status)
                            RetentionChip(state: assessment.state)
                            Spacer()
                            Button("Edit") { editingClient = true }
                                .font(.footnote)
                        }
                        Text(assessment.explanation)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let due = assessment.dueOn, client.status.startsRetentionClock {
                            Text("Review due \(Formatted.date(due))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                if entries.isEmpty {
                    EmptyStateView(
                        symbol: "square.and.pencil",
                        title: "No notes yet",
                        detail: "Write up the first session for \(code)."
                    )
                } else {
                    ForEach(entries) { entry in
                        NavigationLink {
                            NoteDetailView(entry: entry)
                        } label: {
                            NoteRow(entry: entry, isSuperseded: supersededIDs.contains(entry.id))
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    if (client?.supersededCount ?? 0) > 0 {
                        Toggle("Show corrected", isOn: $showingSuperseded)
                            .toggleStyle(.button)
                            .font(.caption)
                    }
                }
            } footer: {
                if (client?.supersededCount ?? 0) > 0 && !showingSuperseded {
                    Text("\(client?.supersededCount ?? 0) earlier version\((client?.supersededCount ?? 0) == 1 ? " is" : "s are") hidden. Nothing has been deleted — a correction is a new entry, and the original stays in the record.")
                }
            }
        }
        .navigationTitle(code.rawValue)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    composing = true
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $composing) {
            NoteEditorView(client: code, correcting: nil)
        }
        .sheet(isPresented: $editingClient) {
            if let client {
                ClientSettingsView(client: client)
            }
        }
    }
}

struct NoteRow: View {
    let entry: NoteIndexEntry
    let isSuperseded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Formatted.dateTime(entry.session, timeZone: entry.sessionTimeZone))
                    .font(.subheadline.weight(.medium))
                Spacer()
                if entry.supersedes != nil {
                    Label("Correction", systemImage: "arrow.triangle.branch")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
            HStack(spacing: 10) {
                Text("\(entry.wordCount) words")
                Text(entry.template.displayName)
                Text(entry.device)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .opacity(isSuperseded ? 0.5 : 1)
        .padding(.vertical, 2)
    }
}

/// Status and retention basis for one client — the two things that decide when their notes
/// fall out of retention.
struct ClientSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let client: ClientSummary

    @State private var status: ClientStatus
    @State private var seenAsMinor: Bool
    @State private var dateOfBirth: Date
    @State private var overrideLastContact: Bool
    @State private var lastContact: Date
    @State private var destroying = false

    init(client: ClientSummary) {
        self.client = client
        _status = State(initialValue: client.status)
        if case let .minor(reaches25On) = client.retentionBasis {
            _seenAsMinor = State(initialValue: true)
            // Shown back as the date of birth it was derived from, so the field reads the
            // way it was entered. Only the 25th birthday is ever stored.
            _dateOfBirth = State(initialValue: Calendar.gregorianUTC.date(byAdding: .year, value: -25, to: reaches25On) ?? Date())
        } else {
            _seenAsMinor = State(initialValue: false)
            _dateOfBirth = State(initialValue: Calendar.gregorianUTC.date(byAdding: .year, value: -30, to: Date()) ?? Date())
        }
        _overrideLastContact = State(initialValue: false)
        _lastContact = State(initialValue: client.lastContact ?? Date())
    }

    private var basis: RetentionBasis {
        seenAsMinor ? .minor(dateOfBirth: dateOfBirth) : .adult
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Picker("Status", selection: $status) {
                        ForEach(ClientStatus.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(status.startsRetentionClock
                         ? "The retention clock runs from the last session."
                         : "No retention clock while the work is ongoing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Seen as a client under 18", isOn: $seenAsMinor)
                    if seenAsMinor {
                        DatePicker("Date of birth", selection: $dateOfBirth, displayedComponents: .date)
                    }
                } header: {
                    Text("Retention basis")
                } footer: {
                    Text(seenAsMinor
                         ? "Only the date they turn \(model.retentionPolicy.minorAgeCeiling) is stored — the date of birth itself is never written to the vault."
                         : "Notes are kept for \(model.retentionPolicy.adultYears) years after the last session.")
                }

                Section {
                    Toggle("Last contact was after the final note", isOn: $overrideLastContact)
                    if overrideLastContact {
                        DatePicker("Last contact", selection: $lastContact, displayedComponents: .date)
                    }
                } footer: {
                    Text("Use this when the work ended with a call or a letter that produced no written note.")
                }

                Section {
                    Button("Destroy all notes for \(client.code)", role: .destructive) {
                        destroying = true
                    }
                } footer: {
                    Text("Removes every note and every correction for this client from the vault. There is no undo and no backup we can restore from.")
                }
            }
            .navigationTitle(client.code.rawValue)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model.updateClient(
                                client.code,
                                status: status,
                                retentionBasis: basis,
                                lastContactOverride: overrideLastContact ? lastContact : nil
                            )
                            dismiss()
                        }
                    }
                }
            }
            .sheet(isPresented: $destroying) {
                DestroyClientView(client: client) { dismiss() }
            }
        }
    }
}
