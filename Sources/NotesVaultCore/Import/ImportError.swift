import Foundation

/// What can go wrong while reading somebody else's files, said the way the counsellor
/// would say it — and, wherever there is one, with the next thing to try.
///
/// These are kept apart from `VaultError` on purpose. A vault error means something is
/// wrong with the record; an import error means a file we were handed is not what we
/// hoped, which is ordinary and never puts anything already stored at risk.
public enum ImportError: Error, Equatable, LocalizedError {
    case unreadableArchive(String)
    case unsupportedFormat(name: String, detail: String)
    case noTextFound(String)
    case fileTooLarge(name: String, megabytes: Int)
    case notReadableAsText(String)
    case nothingSelected

    public var errorDescription: String? {
        switch self {
        case let .unreadableArchive(detail):
            return detail
        case let .unsupportedFormat(name, detail):
            return "\(name) can't be read directly — \(detail)"
        case let .noTextFound(name):
            return "\(name) opened, but there was no text in it to import."
        case let .fileTooLarge(name, megabytes):
            return "\(name) is \(megabytes) MB, which is larger than this app will read in one go. Split it up, or export it as several files."
        case let .notReadableAsText(name):
            return "\(name) isn't text this app can read. If it opens in another app, export it as plain text, Word or CSV and import that."
        case .nothingSelected:
            return "Nothing was chosen to import."
        }
    }
}
