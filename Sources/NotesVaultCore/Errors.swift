import Foundation

/// Every failure the vault can produce, in the counsellor's language rather than the
/// filesystem's. These strings reach the UI directly — an app holding the only copy of
/// someone's clinical record must never answer a failed save with "Error -43".
public enum VaultError: Error, Equatable, LocalizedError {
    case invalidClientCode(String, reason: String)
    case invalidNoteField(String, reason: String)
    case malformedNote(String)
    case unsupportedNoteFormat(Int)
    case noteNotFound(NoteID)
    case clientNotFound(ClientCode)
    case nameTooLongForVault(String)
    case vaultNotOpen
    case wrongPassphrase
    case notAVault(URL)
    case unsupportedVaultFormat(Int)
    case vaultAlreadyExists(URL)
    case folderUnavailable(String)
    case recoveryKeyMalformed(String)
    case indexUnreadable(String)
    case cryptoFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidClientCode(code, reason):
            return "\"\(code)\" isn't a usable client code — \(reason)."
        case let .invalidNoteField(label, reason):
            return "\"\(label)\" can't be used as a note field — \(reason)."
        case let .malformedNote(detail):
            return "That note file couldn't be read: \(detail)"
        case let .unsupportedNoteFormat(version):
            return "This note was written by a newer version of the app (format \(version)). Update before opening it, so nothing is lost."
        case let .noteNotFound(id):
            return "Note \(id.rawValue) is no longer in the vault."
        case let .clientNotFound(code):
            return "There are no records for \(code) in this vault."
        case let .nameTooLongForVault(name):
            return "The filename \"\(name)\" is too long to store in the vault."
        case .vaultNotOpen:
            return "The vault is locked. Unlock it before reading or writing notes."
        case .wrongPassphrase:
            return "That passphrase didn't unlock the vault."
        case let .notAVault(url):
            return "There's no vault in \(url.lastPathComponent). Choose the folder containing masterkey.cryptomator, or create a new vault here."
        case let .unsupportedVaultFormat(version):
            return "This vault uses format \(version), which this version of the app can't open."
        case let .vaultAlreadyExists(url):
            return "There is already a vault in \(url.lastPathComponent). Open it instead of creating a new one."
        case let .folderUnavailable(detail):
            return "The vault folder can't be reached: \(detail)"
        case let .recoveryKeyMalformed(detail):
            return "That recovery key isn't valid: \(detail)"
        case let .indexUnreadable(detail):
            return "The local index couldn't be read (\(detail)). It will be rebuilt from the vault — no notes are affected."
        case let .cryptoFailure(detail):
            return "Encryption failed: \(detail)"
        }
    }
}
