import Foundation
import NotesVaultCore

/// Remembers which file GroundWork's schedules are written to, across launches.
///
/// The same mechanism as `VaultBookmark`, pointed at a file rather than a folder, and for
/// the same reason: the app is sandboxed and only has permission to it because the user
/// chose it in the picker. Keeping that permission is the whole of the "sync button" —
/// GroundWork writes over the file, this app re-reads it, and neither needs the other to
/// be running or even on the same machine.
///
/// It names a file. It does not hold its contents, and the file it names holds no clinical
/// content, so `UserDefaults` is the right place for it.
public enum RosterBookmark {
    private static let key = "roster.bookmark"
    private static let displayNameKey = "roster.displayName"
    private static let lastSyncKey = "roster.lastSync"

    public static var storedDisplayName: String? {
        UserDefaults.standard.string(forKey: displayNameKey)
    }

    public static var exists: Bool {
        UserDefaults.standard.data(forKey: key) != nil
    }

    /// When the last sync ran on this device. Shown on the settings screen, because "did I
    /// already do this?" is the first question anybody asks of a sync button.
    public static var lastSync: Date? {
        get {
            let stamp = UserDefaults.standard.double(forKey: lastSyncKey)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: lastSyncKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastSyncKey)
            }
        }
    }

    public static func store(_ url: URL) throws {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif

        do {
            let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
            UserDefaults.standard.set(url.lastPathComponent, forKey: displayNameKey)
        } catch {
            throw VaultError.folderUnavailable("that file could not be remembered: \(error.localizedDescription)")
        }
    }

    /// Resolves the bookmark, refreshing it if it has gone stale. Returns nil when no file
    /// has been chosen yet.
    public static func resolve() throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }

        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif

        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                try? store(url)
            }
            return url
        } catch {
            throw VaultError.folderUnavailable("the schedule file could not be reopened — choose it again (\(error.localizedDescription))")
        }
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: displayNameKey)
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
    }

    /// Reads the file the bookmark names.
    ///
    /// The file usually lives in iCloud Drive, where it may be nothing but a placeholder on
    /// a Mac that has not opened that folder in a while — so it is asked for and waited on,
    /// exactly as the importer does, rather than reported as missing.
    public static func read(_ url: URL, downloadTimeout: TimeInterval = 20) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.folderUnavailable("the schedule file is no longer there. Export it again from GroundWork, or choose it again here.")
        }
        try materialise(url, timeout: downloadTimeout)
        return try Data(contentsOf: url)
    }

    private static func materialise(_ url: URL, timeout: TimeInterval) throws {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true,
              values?.ubiquitousItemDownloadingStatus != .current else { return }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
            if status == .current { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw VaultError.folderUnavailable("the schedule file is still downloading from iCloud. Wait for it to finish and sync again.")
    }
}
