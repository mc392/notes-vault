import Foundation
import NotesVaultCore

/// A file or folder the counsellor picked, remembered across launches.
///
/// The app is sandboxed and only has permission to what was chosen in the picker. A
/// security-scoped bookmark is that permission, made durable. It is not a secret — it
/// names a place, not what is in it — so it lives in `UserDefaults`.
///
/// `VaultBookmark` and `RosterBookmark` are both this, pointed at different things and
/// describing failures differently; they used to be two copies of the same code.
struct SecurityScopedBookmark {
    /// Where the bookmark itself is kept.
    let key: String
    /// Where the picked item's name is kept, for showing without resolving anything.
    let displayNameKey: String
    /// How a failure is described. The vault and the schedule file need different words:
    /// "the vault folder can't be reached", said about the schedule file, tells a
    /// counsellor their notes are gone.
    let failure: (String) -> VaultError

    var storedDisplayName: String? {
        UserDefaults.standard.string(forKey: displayNameKey)
    }

    var exists: Bool {
        UserDefaults.standard.data(forKey: key) != nil
    }

    private static var creationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private static var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    /// Makes the bookmark data, holding the security scope while it does.
    ///
    /// **The scope has to be held while the bookmark is made.** A URL from the document
    /// picker is unusable outside a balanced `startAccessingSecurityScopedResource()`
    /// pair, and `bookmarkData` is a use like any other: called outside one it fails with
    /// "the file couldn't be opened because it doesn't exist", which is the sandbox
    /// refusing rather than the file being missing. `beforeBookmarking` runs inside the
    /// scope too, for anything else that counts as a use — asking iCloud for the file.
    func bookmarkData(for url: URL, beforeBookmarking: () -> Void = {}) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        beforeBookmarking()
        return try url.bookmarkData(options: Self.creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Saves bookmark data made by `bookmarkData(for:)`. Separate from making it so that a
    /// failed pick never replaces a good one.
    func remember(_ data: Data, name: String) {
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(name, forKey: displayNameKey)
    }

    /// Resolves the bookmark. Nil when nothing has been chosen yet.
    ///
    /// A *stale* bookmark still resolves, and is refreshed and re-saved rather than thrown
    /// away — the item moving, or iCloud rebuilding its local copy, must not present as
    /// "your notes are gone". The refresh is best effort: the URL in hand is good for now
    /// whether or not it can be re-saved.
    func resolve(describingFailureAs describe: (String) -> String) throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: Self.resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale, let refreshed = try? bookmarkData(for: url) {
                remember(refreshed, name: url.lastPathComponent)
            }
            return url
        } catch {
            throw failure(describe(error.localizedDescription))
        }
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: displayNameKey)
    }
}
