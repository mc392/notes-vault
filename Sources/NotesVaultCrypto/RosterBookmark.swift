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

    /// Remembers the file the picker returned.
    ///
    /// **The security scope has to be held while the bookmark is made.** A URL from the
    /// document picker is unusable outside a balanced
    /// `startAccessingSecurityScopedResource()` pair, and `bookmarkData` is a use like any
    /// other: called outside one it fails with "the file couldn't be opened because it
    /// doesn't exist", which is the sandbox refusing rather than the file being missing.
    /// The vault folder gets this for free — `FileSystemVaultStore` is already holding its
    /// folder open when `VaultBookmark.store` runs — and a file picked for a single read
    /// has nothing holding it, which is why this is the path that broke.
    ///
    /// `downloadTimeout` is how long to wait for iCloud to hand over a file that is still a
    /// placeholder; a placeholder cannot be bookmarked either. Pass `0` to ask for it and
    /// carry on — anything running on the main thread should, because this blocks.
    public static func store(_ url: URL, downloadTimeout: TimeInterval = 0) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif

        // Best effort: a file that is not in iCloud at all, or is already here, costs
        // nothing. A failure to fetch is reported by the bookmark attempt below, in terms
        // of the file rather than of the download.
        try? materialise(url, timeout: downloadTimeout)

        let data: Data
        do {
            data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            if !isDownloaded(url) {
                throw VaultError.scheduleFileUnavailable(
                    "\(url.lastPathComponent) is in iCloud but has not been downloaded to this device yet. Open it once in the Files app, then choose it again here."
                )
            }
            throw VaultError.scheduleFileUnavailable("that file could not be remembered: \(error.localizedDescription)")
        }

        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(url.lastPathComponent, forKey: displayNameKey)
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
            // A stale bookmark still resolves; re-saving it is what stops it going stale
            // for good. It is `try?` because a failure here loses nothing — the URL in
            // hand is still good for this sync — and this runs on the main thread, hence
            // no download wait.
            if isStale { try? store(url) }
            return url
        } catch {
            throw VaultError.scheduleFileUnavailable("that file could not be reopened — choose it again (\(error.localizedDescription))")
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
    /// a device that has not opened that folder in a while — so it is asked for and waited
    /// on, exactly as the importer does, rather than reported as missing. That is why the
    /// download comes first and the "is it there?" check second: a placeholder is not at
    /// the path the user picked, it is beside it as `.name.icloud`, and testing the path
    /// first would call every undownloaded file gone.
    public static func read(_ url: URL, downloadTimeout: TimeInterval = 20) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        try materialise(url, timeout: downloadTimeout)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.scheduleFileUnavailable("that file is no longer there. Export it again from GroundWork, or choose it again here.")
        }
        return try Data(contentsOf: url)
    }

    /// Where iCloud parks a file it has not downloaded: `.name.icloud`, beside the real one.
    private static func placeholderURL(for target: URL) -> URL? {
        let placeholder = target
            .deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path) ? placeholder : nil
    }

    /// Whether the bytes are actually on this device — an ordinary local file, or a
    /// ubiquitous one iCloud has finished fetching.
    private static func isDownloaded(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true {
            return values?.ubiquitousItemDownloadingStatus == .current
        }
        return FileManager.default.fileExists(atPath: url.path) && placeholderURL(for: url) == nil
    }

    /// Asks iCloud for a file that is only a placeholder, and — when given a timeout —
    /// waits for it. Call inside the security scope: the request is a use of the file too.
    private static func materialise(_ url: URL, timeout: TimeInterval) throws {
        guard !isDownloaded(url) else { return }

        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            // Not a ubiquitous item at all — a plain local file, or one that genuinely is
            // not there. Nothing to wait for either way; the caller reports what it finds.
            return
        }

        guard timeout > 0 else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isDownloaded(url) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw VaultError.scheduleFileUnavailable("that file is still downloading from iCloud. Wait for it to finish and sync again.")
    }
}
