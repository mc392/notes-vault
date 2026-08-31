import Foundation

/// Codes this group of notes might belong to.
///
/// Both halves matter. `existing` is the more important one — a counsellor importing five
/// years of records almost certainly has some of those clients in the vault already, and
/// silently creating `SM3` alongside their real `SM2` would split one person's record in
/// two, which is exactly the failure the retention rules cannot survive.
public struct ClientCodeSuggestion: Hashable, Sendable {
    /// Codes already in this vault that could plausibly be the same person.
    public let existing: [ClientCode]
    /// A free code derived from what the source called them, offered only as a starting
    /// point. Never applied on its own.
    public let proposed: ClientCode?

    public init(existing: [ClientCode], proposed: ClientCode?) {
        self.existing = existing
        self.proposed = proposed
    }

    public static func suggest(for key: String, existing codes: [ClientCode]) -> ClientCodeSuggestion {
        // If the source was already using codes — a spreadsheet column of "SM2", "JD1" —
        // then it is the counsellor's own scheme and the best possible suggestion.
        if let asCode = try? ClientCode(key) {
            let matches = codes.filter { $0 == asCode }
            return ClientCodeSuggestion(existing: matches, proposed: matches.isEmpty ? asCode : nil)
        }

        let words = key
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.first?.isLetter == true }
        var initials = String(words.prefix(3).compactMap { $0.first }).uppercased()
        if initials.count < ClientCode.minLength, let first = words.first {
            initials = String(first.prefix(ClientCode.minLength)).uppercased()
        }
        guard initials.count >= ClientCode.minLength else {
            return ClientCodeSuggestion(existing: [], proposed: nil)
        }

        // Anyone whose code starts with the same initials is worth offering. Deciding
        // whether it is the same person is the counsellor's job, not the app's.
        let related = codes.filter { $0.rawValue.hasPrefix(initials) }.sorted()

        var proposed: ClientCode?
        for number in 1...99 {
            guard let candidate = try? ClientCode("\(initials)\(number)") else { break }
            if !codes.contains(candidate) {
                proposed = candidate
                break
            }
        }
        return ClientCodeSuggestion(existing: related, proposed: proposed)
    }
}

/// Everything found for one person, waiting for a code.
public struct ImportGroup: Identifiable, Hashable, Sendable {
    public var id: String { key }
    /// What the source called them — a folder name, a spreadsheet cell. Very often a real
    /// name, which is why it never reaches the vault.
    public let key: String
    public var items: [ImportedItem]
    public let suggestion: ClientCodeSuggestion
    /// Nil until the counsellor chooses. Nothing in this group is written while it is nil,
    /// and there is no default — a client code assigned by an app is a client code nobody
    /// checked.
    public var assignedCode: ClientCode?
    /// Replace the source's own words for this person with the code, throughout the notes.
    public var replaceNamesInBodies: Bool = true
    /// Deliberately left out of this import — a duplicate export, a client whose records
    /// are already in, a folder that turned out to be something else.
    ///
    /// Kept separate from "no code chosen yet" on purpose. Without the distinction, a
    /// counsellor importing forty clients cannot tell the ones they have decided about
    /// from the ones they have not, and the safe reading — refuse to import until every
    /// group is decided — becomes an unusable one.
    public var isSkipped: Bool = false

    public init(key: String, items: [ImportedItem], suggestion: ClientCodeSuggestion, assignedCode: ClientCode? = nil) {
        self.key = key
        self.items = items
        self.suggestion = suggestion
        self.assignedCode = assignedCode
    }

    public var earliestSession: Date? { items.compactMap { $0.date.date }.min() }
    public var latestSession: Date? { items.compactMap { $0.date.date }.max() }
    public var undatedCount: Int { items.filter { $0.date.date == nil }.count }
    public var uncertainDateCount: Int { items.filter { !$0.date.isCertain }.count }

    /// Ready when a code is chosen and every note has a date to file it under.
    public var isReady: Bool { !isSkipped && assignedCode != nil && undatedCount == 0 }
    /// Decided, either way. A skipped group needs no code and blocks nothing.
    public var isDecided: Bool { isSkipped || assignedCode != nil }

    /// The words to look for, and to replace, in this group's notes.
    public var nameCandidates: [String] {
        var names = [key]
        names.append(contentsOf: items.compactMap(\.sourceTitle))
        return names
    }
}

/// The whole proposed import, as one reviewable object.
///
/// This is the thing the counsellor confirms. It exists as a value type — no store, no
/// engine, nothing that can write — so that "what will happen" is computed and shown well
/// before anything can happen.
public struct ImportPlan: Sendable {
    public var groups: [ImportGroup]
    public var issues: [VaultIssue]
    public var options: ImportOptions
    /// Notes that were the same note twice — the same folder dragged in alongside a zip of
    /// itself, which is a very easy mistake to make and an unpleasant one to unpick after.
    public let duplicatesCollapsed: Int

    public init(groups: [ImportGroup], issues: [VaultIssue], options: ImportOptions, duplicatesCollapsed: Int = 0) {
        self.groups = groups
        self.issues = issues
        self.options = options
        self.duplicatesCollapsed = duplicatesCollapsed
    }

    public static func make(
        results: [ImportFileResult],
        existingClients: [ClientCode],
        options: ImportOptions = .default
    ) -> ImportPlan {
        var issues = results.flatMap(\.issues)
        var byKey: [String: [ImportedItem]] = [:]
        var order: [String] = []
        var seenFingerprints = Set<String>()
        var duplicates = 0

        for result in results {
            for item in result.items {
                guard seenFingerprints.insert(item.contentFingerprint).inserted else {
                    duplicates += 1
                    continue
                }
                if byKey[item.groupKey] == nil { order.append(item.groupKey) }
                byKey[item.groupKey, default: []].append(item)
            }
            if result.needsMapping {
                issues.append(VaultIssue(
                    location: result.file,
                    message: "This file is a table and needs its columns matched up before it can be imported."
                ))
            }
        }

        let groups = order.map { key -> ImportGroup in
            let items = (byKey[key] ?? []).sorted { lhs, rhs in
                switch (lhs.date.date, rhs.date.date) {
                case let (left?, right?): return left < right
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.origin.description < rhs.origin.description
                }
            }
            return ImportGroup(
                key: key,
                items: items,
                suggestion: ClientCodeSuggestion.suggest(for: key, existing: existingClients)
            )
        }

        return ImportPlan(groups: groups, issues: issues, options: options, duplicatesCollapsed: duplicates)
    }

    // MARK: - Readiness

    public var totalItemCount: Int { groups.reduce(0) { $0 + $1.items.count } }
    public var readyItemCount: Int { groups.filter(\.isReady).reduce(0) { $0 + $1.items.count } }
    public var undecidedGroups: [ImportGroup] { groups.filter { !$0.isDecided } }
    public var skippedGroups: [ImportGroup] { groups.filter(\.isSkipped) }
    public var skippedItemCount: Int { skippedGroups.reduce(0) { $0 + $1.items.count } }
    public var undatedItemCount: Int { groups.filter { !$0.isSkipped }.reduce(0) { $0 + $1.undatedCount } }

    /// Two groups pointed at the same client is legitimate — "Sarah M" and "S Mitchell"
    /// are one person filed twice — so this reports rather than forbids.
    public var mergedCodes: [ClientCode] {
        let assigned = groups.filter { !$0.isSkipped }.compactMap(\.assignedCode)
        return Set(assigned.filter { code in assigned.filter { $0 == code }.count > 1 }).sorted()
    }

    /// What still stands between here and importing, in the order worth fixing it.
    public var blockers: [String] {
        var blockers: [String] = []
        let undecided = undecidedGroups.count
        if undecided > 0 {
            blockers.append("\(undecided) \(undecided == 1 ? "group has" : "groups have") no client code yet. Give each one a code, or leave it out.")
        }
        if undatedItemCount > 0 {
            blockers.append("\(undatedItemCount) \(undatedItemCount == 1 ? "note has" : "notes have") no session date.")
        }
        if totalItemCount == 0 {
            blockers.append("Nothing readable was found in the files you chose.")
        }
        if readyItemCount == 0 && totalItemCount > 0 && undecided == 0 && undatedItemCount == 0 {
            blockers.append("Every group has been left out, so there is nothing to import.")
        }
        return blockers
    }

    public var canImport: Bool { blockers.isEmpty }

    // MARK: - Clashes with what is already stored

    public struct Clash: Hashable, Sendable, Identifiable {
        public let itemID: UUID
        public let client: ClientCode
        public let session: Date
        public var id: UUID { itemID }
    }

    /// Notes whose client and session minute already exist in the vault. Almost always a
    /// second run of the same import. Not an error — the vault is append-only and would
    /// happily hold both — but worth saying before it doubles someone's record.
    public func clashes(with existing: [NoteIndexEntry]) -> [Clash] {
        let taken = Set(existing.map { "\($0.client.rawValue)|\(VaultDate.filenameStamp($0.session, timeZone: $0.sessionTimeZone))" })
        var clashes: [Clash] = []
        for group in groups where !group.isSkipped {
            guard let code = group.assignedCode else { continue }
            for item in group.items {
                guard let date = item.date.date else { continue }
                let key = "\(code.rawValue)|\(VaultDate.filenameStamp(date, timeZone: options.timeZone))"
                if taken.contains(key) {
                    clashes.append(Clash(itemID: item.id, client: code, session: date))
                }
            }
        }
        return clashes
    }

    // MARK: - Editing

    public mutating func assign(_ code: ClientCode?, toGroup key: String) {
        guard let index = groups.firstIndex(where: { $0.key == key }) else { return }
        groups[index].assignedCode = code
        if code != nil { groups[index].isSkipped = false }
    }

    public mutating func setSkipped(_ skipped: Bool, forGroup key: String) {
        guard let index = groups.firstIndex(where: { $0.key == key }) else { return }
        groups[index].isSkipped = skipped
        if skipped { groups[index].assignedCode = nil }
    }

    public mutating func setDate(_ date: Date, forItem id: UUID) {
        for groupIndex in groups.indices {
            guard let itemIndex = groups[groupIndex].items.firstIndex(where: { $0.id == id }) else { continue }
            let item = groups[groupIndex].items[itemIndex]
            groups[groupIndex].items[itemIndex] = ImportedItem(
                id: item.id,
                origin: item.origin,
                sourceTitle: item.sourceTitle,
                groupKey: item.groupKey,
                date: .found(date, raw: "set by hand"),
                body: item.body
            )
            return
        }
    }

    public mutating func removeItem(_ id: UUID) {
        for index in groups.indices {
            groups[index].items.removeAll { $0.id == id }
        }
        groups.removeAll { $0.items.isEmpty }
    }
}
