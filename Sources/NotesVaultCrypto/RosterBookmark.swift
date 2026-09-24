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
    private static let bookmark = SecurityScopedBookmark(
        key: "roster.bookmark",
        displayNameKey: "roster.displayName",
        failure: VaultError.scheduleFileUnavailable
    )
    private static let lastSyncKey = "roster.lastSync"

    public static var storedDisplayName: String? { bookmark.storedDisplayName }

    public static var exists: Bool { bookmark.exists }

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

    /// Remembers the file the picker returned.
    ///
    /// A file picked for a single read has nothing else holding its security scope, which
    /// is why `SecurityScopedBookmark` holds it while the bookmark is made — this is the
    /// path that broke before it did.
    ///
    /// `downloadTimeout` is how long to wait for iCloud to hand over a file that is still a
    /// placeholder; a placeholder cannot be bookmarked either. Pass `0` to ask for it and
    /// carry on — anything running on the main thread should, because this blocks.
    public static func store(_ url: URL, downloadTimeout: TimeInterval = 0) throws {
        let data: Data
        do {
            // Best effort: a file that is not in iCloud at all, or is already here, costs
            // nothing. A failure to fetch is reported by the bookmark attempt, in terms of
            // the file rather than of the download.
            data = try bookmark.bookmarkData(for: url) {
                _ = ICloudFile.materialise(url, timeout: downloadTimeout, acceptingLocalCopy: false)
            }
        } catch {
            if !ICloudFile.isDownloaded(url, acceptingLocalCopy: false) {
                throw VaultError.scheduleFileUnavailable(
                    "\(url.lastPathComponent) is in iCloud but has not been downloaded to this device yet. Open it once in the Files app, then choose it again here."
                )
            }
            throw VaultError.scheduleFileUnavailable("that file could not be remembered: \(error.localizedDescription)")
        }
        bookmark.remember(data, name: url.lastPathComponent)
    }

    /// Resolves the bookmark, refreshing it if it has gone stale. Returns nil when no file
    /// has been chosen yet.
    public static func resolve() throws -> URL? {
        try bookmark.resolve { "that file could not be reopened — choose it again (\($0))" }
    }

    public static func clear() {
        bookmark.clear()
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
    }

    /// Reads the file the bookmark names.
    ///
    /// The file usually lives in iCloud Drive, where it may be nothing but a placeholder on
    /// a device that has not opened that folder in a while — so it is asked for and waited
    /// on, exactly as the importer does, rather than reported as missing. That is why the
    /// download comes first and the "is it there?" check second: a placeholder is not at
    /// the path the user picked, it is beside it as `.name.icloud`, and testing the path
    /// first would call every undownloaded file gone.
    ///
    /// Only the latest version will do: GroundWork rewrites this file, and a stale local
    /// copy would sync last week's schedules.
    public static func read(_ url: URL, downloadTimeout: TimeInterval = 20) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let outcome = ICloudFile.materialise(url, timeout: downloadTimeout, acceptingLocalCopy: false, pollInterval: 0.25)
        if outcome == .timedOut && downloadTimeout > 0 {
            throw VaultError.scheduleFileUnavailable("that file is still downloading from iCloud. Wait for it to finish and sync again.")
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.scheduleFileUnavailable("that file is no longer there. Export it again from GroundWork, or choose it again here.")
        }
        return try Data(contentsOf: url)
    }
}
