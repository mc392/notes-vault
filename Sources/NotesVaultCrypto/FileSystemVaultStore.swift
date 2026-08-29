import Foundation
import NotesVaultCore

#if canImport(UIKit)
import UIKit
#endif

/// Which device wrote a file. Part of every filename, so two devices writing the same
/// client in the same minute produce two files instead of one overwrite.
public enum DeviceIdentity {
    public static var current: String {
        #if os(iOS)
        let name = UIDevice.current.model.lowercased()
        return name.contains("ipad") ? "ipad" : "iphone"
        #elseif os(macOS)
        return "mac"
        #else
        return "device"
        #endif
    }
}

/// `VaultFileStore` over the real filesystem, inside a folder the user picked.
///
/// Storage layer, per the architecture: **no OAuth, no cloud provider API, no network call
/// made by this app at all.** The user points at a folder through the system document
/// picker; that folder happens to live in iCloud Drive; the OS's own sync client moves the
/// bytes. Nothing here knows what iCloud is beyond having to wait for a file that has not
/// been downloaded yet.
///
/// Two platform details this has to get right, both of which are silent data loss if
/// skipped:
/// - **Security scope.** The URL comes from a bookmark and is unusable outside a balanced
///   `startAccessingSecurityScopedResource()` pair.
/// - **File coordination.** The sync daemon is writing to the same folder. Reading without
///   `NSFileCoordinator` can see a half-downloaded file; writing without it can lose a
///   race with the daemon.
public final class FileSystemVaultStore: VaultFileStore {
    public let root: URL

    private let coordinator = NSFileCoordinator(filePresenter: nil)
    private let isSecurityScoped: Bool
    private var accessing = false

    /// How long to wait for iCloud to materialise a file that is currently a placeholder.
    /// A counsellor opening a vault on a phone that has been offline should get a spinner
    /// and then their notes — not an error that reads like the notes are gone.
    public var downloadTimeout: TimeInterval = 30

    public init(root: URL, securityScoped: Bool = true) throws {
        self.root = root
        self.isSecurityScoped = securityScoped
        if securityScoped {
            guard root.startAccessingSecurityScopedResource() else {
                throw VaultError.folderUnavailable("permission to use \(root.lastPathComponent) has expired — choose the folder again")
            }
            accessing = true
        }
    }

    deinit {
        if accessing { root.stopAccessingSecurityScopedResource() }
    }

    /// Releases the security-scoped access early. Called when the vault is locked.
    public func relinquish() {
        if accessing {
            root.stopAccessingSecurityScopedResource()
            accessing = false
        }
    }

    private func url(for path: [String]) -> URL {
        path.reduce(root) { $0.appendingPathComponent($1) }
    }

    // MARK: - VaultFileStore

    public func directoryExists(at path: [String]) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url(for: path).path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    public func fileExists(at path: [String]) -> Bool {
        let target = url(for: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            return !isDirectory.boolValue
        }
        // Not there as a real file — but iCloud may be holding it as a placeholder, which
        // is a file that exists as far as the user is concerned.
        return placeholderURL(for: target) != nil
    }

    public func contentsOfDirectory(at path: [String]) throws -> [String] {
        let target = url(for: path)
        var result: [String] = []
        var thrown: Error?

        var coordinationError: NSError?
        coordinator.coordinate(readingItemAt: target, options: [.withoutChanges], error: &coordinationError) { url in
            do {
                let entries = try FileManager.default.contentsOfDirectory(atPath: url.path)
                // Undownloaded items appear as `.SM2.c9r.icloud`; present them under the
                // name they will have once they arrive, or every listing would be wrong on
                // a device that has been offline.
                result = entries.compactMap { entry in
                    guard entry != ".DS_Store" else { return nil }
                    return Self.materialisedName(for: entry)
                }
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw VaultError.folderUnavailable(coordinationError.localizedDescription) }
        if let thrown { throw VaultError.folderUnavailable(thrown.localizedDescription) }
        return result
    }

    public func createDirectory(at path: [String]) throws {
        do {
            try FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: true)
        } catch {
            throw VaultError.folderUnavailable(error.localizedDescription)
        }
    }

    public func read(at path: [String]) throws -> Data {
        let target = url(for: path)
        try ensureDownloaded(target)

        var result: Data?
        var thrown: Error?
        var coordinationError: NSError?
        coordinator.coordinate(readingItemAt: target, options: [], error: &coordinationError) { url in
            do { result = try Data(contentsOf: url) } catch { thrown = error }
        }
        if let coordinationError { throw VaultError.folderUnavailable(coordinationError.localizedDescription) }
        if let thrown { throw VaultError.folderUnavailable(thrown.localizedDescription) }
        guard let result else { throw VaultError.folderUnavailable("could not read \(target.lastPathComponent)") }
        return result
    }

    public func write(_ data: Data, at path: [String], overwrite: Bool) throws {
        let target = url(for: path)
        if !overwrite && fileExists(at: path) {
            throw VaultError.folderUnavailable("\(target.lastPathComponent) already exists and this vault never overwrites")
        }

        let parent = target.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        var thrown: Error?
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: target, options: overwrite ? [.forReplacing] : [], error: &coordinationError) { url in
            do {
                // Deliberately the default protection class, not a stricter one. What is
                // being written here is already ciphertext, and raising the class would stop
                // the sync daemon reading the file to upload it while the device is locked —
                // trading no real protection for notes that silently never leave the phone.
                try data.write(to: url, options: [.atomic])
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw VaultError.folderUnavailable(coordinationError.localizedDescription) }
        if let thrown { throw VaultError.folderUnavailable(thrown.localizedDescription) }
    }

    public func remove(at path: [String]) throws {
        let target = url(for: path)
        var thrown: Error?
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: target, options: [.forDeleting], error: &coordinationError) { url in
            do { try FileManager.default.removeItem(at: url) } catch { thrown = error }
        }
        if let coordinationError { throw VaultError.folderUnavailable(coordinationError.localizedDescription) }
        if let thrown { throw VaultError.folderUnavailable(thrown.localizedDescription) }
    }

    // MARK: - iCloud placeholders

    /// `SM2.c9r` stored but not yet downloaded is on disk as `.SM2.c9r.icloud`.
    private static func materialisedName(for entry: String) -> String {
        guard entry.hasPrefix("."), entry.hasSuffix(".icloud") else { return entry }
        return String(entry.dropFirst().dropLast(".icloud".count))
    }

    private func placeholderURL(for target: URL) -> URL? {
        let placeholder = target
            .deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path) ? placeholder : nil
    }

    /// Asks iCloud for a file that is only a placeholder, and waits for it.
    private func ensureDownloaded(_ target: URL) throws {
        guard placeholderURL(for: target) != nil || !FileManager.default.fileExists(atPath: target.path) else { return }

        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: target)
        } catch {
            // Not a ubiquitous item at all — a plain local folder. Nothing to wait for; if
            // the file genuinely is not there the read below reports it.
            return
        }

        let deadline = Date().addingTimeInterval(downloadTimeout)
        while Date() < deadline {
            let values = try? target.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if values?.ubiquitousItemDownloadingStatus == .current { return }
            if FileManager.default.fileExists(atPath: target.path) && placeholderURL(for: target) == nil { return }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw VaultError.folderUnavailable("\(target.lastPathComponent) has not finished downloading from iCloud yet")
    }
}
