import Foundation
import NotesVaultCore

/// Remembers which folder the vault is in, across launches. See `SecurityScopedBookmark`.
public enum VaultBookmark {
    private static let bookmark = SecurityScopedBookmark(
        key: "vault.bookmark",
        displayNameKey: "vault.displayName",
        failure: VaultError.folderUnavailable
    )

    public static var storedDisplayName: String? { bookmark.storedDisplayName }

    public static var exists: Bool { bookmark.exists }

    public static func store(_ url: URL) throws {
        do {
            bookmark.remember(try bookmark.bookmarkData(for: url), name: url.lastPathComponent)
        } catch {
            throw VaultError.folderUnavailable("that folder could not be remembered: \(error.localizedDescription)")
        }
    }

    /// Resolves the bookmark. Returns nil when no folder has been chosen yet.
    public static func resolve() throws -> URL? {
        try bookmark.resolve { "the vault folder could not be reopened — choose it again (\($0))" }
    }

    public static func clear() {
        bookmark.clear()
    }
}
