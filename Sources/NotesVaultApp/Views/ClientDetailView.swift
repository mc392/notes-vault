import SwiftUI
import NotesVaultCore

struct ClientDetailView: View {
    @EnvironmentObject private var model: AppModel
    let code: ClientCode

    @State private var composing = false
    @State private var editingClient = false
    @State private var showingSuperseded = false
    /// The date a tapped suggestion put into the editor. Cleared when the sheet closes so
    /// the next plain "New note" opens on today rather than on a stale suggestion.
    @State private var composingDate: Date?

    private var awaiting: [Date] { model.predictedSessions(for: code) }

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
                        if let schedule = client.schedule {
                            Label(schedule.summary, systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if !awaiting.isEmpty {
                Section {
                    ForEach(awaiting, id: \.self) { date in
                        Button {
                            composingDate = date
                            composing = true
                        } label: {
                            HStack {
                                Text(Formatted.dateTime(date))
                                Spacer()
                                Image(systemName: "square.and.pencil")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Not yet written up")
                } footer: {
                    Text("Worked out from this client's usual pattern and the notes already here — so a session that was cancelled will still be listed. Nothing is recorded until you write one.")
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
                            // The list as it stands, so the note screen can step through
                            // it without coming back here.
                            NoteDetailView(entry: entry, siblings: entries)
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
                    composingDate = nil
                    composing = true
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $composing, onDismiss: { composingDate = nil }) {
            NoteEditorView(client: code, correcting: nil, sessionDate: composingDate)
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
    @State private var hasSchedule: Bool
    @State private var cadenceDays: Int
    @State private var usualDay: Weekday
    @State private var usualTime: Date

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

        let schedule = client.schedule
        _hasSchedule = State(initialValue: schedule != nil)
        _cadenceDays = State(initialValue: schedule?.cadenceDays ?? 7)
        // Defaults chosen so switching the toggle on gives something usable rather than
        // midnight on a Sunday: the day and time of the last session, if there was one.
        _usualDay = State(initialValue: schedule?.usualDay
            ?? Weekday(calendarWeekday: Calendar.current.component(.weekday, from: client.lastContact ?? Date()))
            ?? .mon)
        _usualTime = State(initialValue: Self.time(schedule?.usualTime, fallback: client.lastContact ?? Date()))
    }

    private static func time(_ value: TimeOfDay?, fallback: Date) -> Date {
        guard let value else { return fallback }
        return Calendar.current.date(bySettingHour: value.hour, minute: value.minute, second: 0, of: fallback) ?? fallback
    }

    private var basis: RetentionBasis {
        seenAsMinor ? .minor(dateOfBirth: dateOfBirth) : .adult
    }

    private var schedule: SessionSchedule? {
        guard hasSchedule else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: usualTime)
        return SessionSchedule(
            cadenceDays: cadenceDays,
            usualDay: usualDay,
            usualTime: TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        )
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
                    Toggle("Has a regular slot", isOn: $hasSchedule)
                    if hasSchedule {
                        Picker("How often", selection: $cadenceDays) {
                            ForEach(SessionSchedule.offered, id: \.days) { option in
                                Text(option.label).tag(option.days)
                            }
                        }
                        Picker("Usual day", selection: $usualDay) {
                            ForEach(Weekday.allCases, id: \.self) { day in
                                Text(day.displayName).tag(day)
                            }
                        }
                        DatePicker("Usual time", selection: $usualTime, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Sessions")
                } footer: {
                    Text(hasSchedule
                         ? "Used to suggest which sessions still need writing up. Syncing schedules from GroundWork sets this for you."
                         : "Without a regular slot this app cannot suggest which sessions are outstanding — you pick the date on each note instead.")
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
                    Button("Destroy all notes for \(client.code.rawValue)", role: .destructive) {
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
                                lastContactOverride: overrideLastContact ? lastContact : nil,
                                schedule: schedule,
                                seriesStart: client.seriesStart
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
        .vaultSheet(minHeight: 480)
    }
}
