import Foundation

/// What the counsellor just pointed the app at.
///
/// The document picker lets you walk into any folder, including the ones inside a vault.
/// Those look empty and inviting — `d`, then two letters, then thirty — and picking one
/// used to be accepted silently, because the only question asked was "is there a vault
/// here?" and the answer was no. The app would then offer to create one, burying a second
/// vault inside the encrypted innards of the first. Nothing is lost, but the notes go
/// somewhere the counsellor will never look, and the outer vault gains files it did not
/// write.
///
/// This is the check that stops that. It runs on the chosen folder's own contents, which
/// the picker has granted access to — walking *up* to look for a parent vault is not
/// possible, because security-scoped access is granted to the chosen folder and nothing
/// above it.
public enum VaultFolderVerdict: Equatable, Sendable {
    /// A vault already lives here. Unlock it.
    case existingVault
    /// Empty, or holding unrelated files. A new vault can go here.
    case usable
    /// Inside the encrypted innards of another vault. Refuse, and say why.
    case insideAnotherVault(reason: String)
}

public enum VaultFolderCheck {

    /// Assesses a folder from its name, its path, and a listing of what is directly inside
    /// it. Takes plain values rather than a URL so the rules can be tested without a
    /// filesystem, in keeping with the rest of this module.
    public static func assess(
        folderName: String,
        pathComponents: [String] = [],
        contents: [String]
    ) -> VaultFolderVerdict {
        if contents.contains(VaultLayout.masterkeyFilename),
           contents.contains(VaultLayout.vaultConfigFilename) {
            return .existingVault
        }

        // The clearest signal, and the one that does not depend on guessing from names:
        // ciphertext entries only ever exist inside a vault.
        if contents.contains(where: { $0.hasSuffix(".c9r") || $0.hasSuffix(".c9s") }) {
            return .insideAnotherVault(
                reason: "it already holds encrypted files belonging to a vault further up"
            )
        }

        // A client folder's insides: the directory marker, and the id file Cryptomator
        // writes beside it.
        if contents.contains(VaultLayout.directoryMarker) || contents.contains("dirid.c9r") {
            return .insideAnotherVault(
                reason: "it is one of the folders a vault keeps its encrypted notes in"
            )
        }

        // The vault's data root: a folder called `d` whose contents are all two-character
        // shard names. An empty folder that happens to be called `d` is left alone.
        if folderName == VaultLayout.dataDirectory,
           !contents.isEmpty,
           contents.allSatisfy({ $0.count == 2 }) {
            return .insideAnotherVault(
                reason: "it is the folder a vault stores its encrypted data in"
            )
        }

        // A shard directory, reached by walking into `d`. Its own contents may be empty, so
        // the path is the only evidence there is.
        if let dataIndex = pathComponents.lastIndex(of: VaultLayout.dataDirectory),
           dataIndex < pathComponents.count - 1,
           pathComponents[dataIndex + 1].count == 2 {
            return .insideAnotherVault(
                reason: "it is inside the folder a vault stores its encrypted data in"
            )
        }

        return .usable
    }
}
