import Foundation
import NotesVaultCore
import NotesVaultCrypto

/// Notes coming in from elsewhere, and going out in plain text.
extension AppModel {
    // MARK: - Import

    /// Codes already in this vault, so the import screen can offer an existing client
    /// rather than inventing a second code for somebody who is already here.
    public var existingClientCodes: [ClientCode] { index.clients.map(\.code) }

    /// Writes an approved import plan into the vault.
    ///
    /// Goes through the same serial queue as every other write, so an import cannot race
    /// a note being saved on the other tab — and through `ImportRunner`, which uses the
    /// ordinary `VaultStore` write path rather than one of its own.
    ///
    /// Locking the vault stops it between notes: an import that carried on after a lock
    /// would be holding the key the lock was meant to drop. Every note is either written
    /// and verified or not written at all.
    public func runImport(
        plan: ImportPlan,
        progress: @escaping (Int, Int) -> Void
    ) async -> ImportReport? {
        guard let store else { return nil }
        let existing = Set(index.clients.map(\.code))
        let token = sessionToken
        var report: ImportReport?

        // No busy message: the import screen shows its own progress, note by note, and a
        // modal spinner over the top of it would hide the one thing worth watching.
        await run(nil) { () -> ImportReport in
            ImportRunner.run(
                plan: plan,
                store: store,
                existingClients: existing,
                onProgress: { step in progress(step.completed, step.total) },
                shouldContinue: { !token.isRevoked }
            )
        } then: { result in
            report = result
        }

        if report != nil {
            await refreshIndex(force: true)
        }
        return report
    }

    // MARK: - Export

    /// Writes the whole vault out as plain files into a folder the user picked.
    ///
    /// Stops if the vault is locked part-way through. What was already written stays —
    /// it is in the counsellor's own folder — but nothing more is decrypted.
    public func export(to destination: URL) async -> Int {
        guard let store else { return 0 }
        let token = sessionToken
        var written = 0

        await run("Exporting…") { () -> (Int, [VaultIssue]) in
            let accessed = destination.startAccessingSecurityScopedResource()
            defer { if accessed { destination.stopAccessingSecurityScopedResource() } }

            let root = destination.appendingPathComponent("GroundWork Notes Export \(VaultDate.filenameStamp(Date()))", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            var count = 0
            let issues = try store.exportPlaintext(shouldContinue: { !token.isRevoked }) { components, data in
                var url = root
                for component in components.dropLast() {
                    url = url.appendingPathComponent(component, isDirectory: true)
                }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try data.write(to: url.appendingPathComponent(components[components.count - 1]), options: .atomic)
                count += 1
            }
            return (count, issues)
        } then: { [weak self] result in
            written = result.0
            self?.issues = result.1
        }
        return written
    }
}
