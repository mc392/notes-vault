import Foundation
import NotesVaultCore

/// Remembers which folder the vault is in, across launches.
///
/// A plain path would not survive: the app is sandboxed and only has permission to the
/// folder because the user chose it in the document picker. A security-scoped bookmark is
/// that permission, made durable. It is not a secret — it names a folder, not its contents
/// — so it lives in `UserDefaults` rather than taking up space in the keychain.
public enum VaultBookmark {
    private static let key = "vault.bookmark"
    private static let displayNameKey = "vault.displayName"

    public static var storedDisplayName: String? {
        UserDefaults.standard.string(forKey: displayNameKey)
    }

    public static var exists: Bool {
        UserDefaults.standard.data(forKey: key) != nil
    }

    /// The security scope is held while the bookmark is made: a picked URL is unusable
    /// outside a balanced access pair, and `bookmarkData` is a use like any other. The
    /// folder path happens to work without it today only because `FileSystemVaultStore` is
    /// holding the folder open by the time this runs — which is not true of the refresh
    /// inside `resolve()`, and was not true at all of the schedule file. See
    /// `RosterBookmark.store`.
    public static func store(_ url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

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
            throw VaultError.folderUnavailable("that folder could not be remembered: \(error.localizedDescription)")
        }
    }

    /// Resolves the bookmark. Returns nil when no folder has been chosen yet.
    ///
    /// A *stale* bookmark is refreshed and re-saved rather than thrown away — the folder
    /// moving, or iCloud rebuilding its local copy, must not present to the counsellor as
    /// "your notes are gone".
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
            throw VaultError.folderUnavailable("the vault folder could not be reopened — choose it again (\(error.localizedDescription))")
        }
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: displayNameKey)
    }
}
