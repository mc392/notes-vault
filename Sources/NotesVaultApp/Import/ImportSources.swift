import Foundation
import PDFKit
import NotesVaultCore

/// Text out of a PDF.
///
/// The one format the core module cannot read on its own, because it needs PDFKit. It sits
/// here rather than in `NotesVaultCore` so that everything else about the importer stays
/// testable with `swift test`, and so this module keeps its "no platform frameworks" rule.
enum PDFTextExtractor {
    static func text(from data: Data) throws -> String {
        guard let document = PDFDocument(data: data) else {
            throw ImportError.notReadableAsText("This PDF")
        }
        guard !document.isLocked else {
            throw ImportError.unsupportedFormat(
                name: "This PDF",
                detail: "it is password-protected. Open it, save an unprotected copy, and import that."
            )
        }

        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pages.append(trimmed) }
        }
        let joined = pages.joined(separator: "\n\n")
        guard !joined.isEmpty else {
            // Worth saying plainly: a lot of counsellors' older records are scans of
            // handwriting, and this app deliberately has no OCR (and no camera permission
            // to acquire one later without somebody deciding to).
            throw ImportError.unsupportedFormat(
                name: "This PDF",
                detail: "it has no text in it — it is probably a scan or a photograph. This app does not read handwriting, so those have to be typed up."
            )
        }
        return joined
    }
}

/// Turning what the file picker returned into bytes the importer can read.
///
/// Everything here is deliberately read-only. The importer never copies, moves, renames or
/// deletes anything the counsellor points at: the originals are theirs, they are the only
/// copy until the import has been checked, and an importer that tidied up after itself
/// would be the most dangerous code in the app.
enum ImportFileCollector {
    /// Names that are never anybody's notes.
    private static let ignoredNames: Set<String> = [".DS_Store", ".localized", "Icon\r"]
    /// How long to wait for iCloud to fetch a file that is still a placeholder.
    private static let downloadTimeout: TimeInterval = 20

    struct Collection {
        var files: [ImportFile] = []
        var issues: [VaultIssue] = []
        /// Files skipped for being enormous or unreadable, kept so the count adds up on
        /// screen — "412 files, 3 skipped" rather than a silent 409.
        var skipped: Int = 0
    }

    static func collect(from urls: [URL], maximumFileBytes: Int, fileLimit: Int = 5000) -> Collection {
        var collection = Collection()

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                collection.issues.append(VaultIssue(
                    location: url.lastPathComponent,
                    message: "This item could not be opened. If it is in iCloud Drive, wait for it to finish downloading and try again."
                ))
                continue
            }

            if isDirectory.boolValue {
                gather(folder: url, into: &collection, maximumFileBytes: maximumFileBytes, fileLimit: fileLimit)
            } else {
                append(url, base: url.deletingLastPathComponent(), into: &collection, maximumFileBytes: maximumFileBytes)
            }
        }
        return collection
    }

    private static func gather(folder: URL, into collection: inout Collection, maximumFileBytes: Int, fileLimit: Int) {
        let base = folder.deletingLastPathComponent()
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            collection.issues.append(VaultIssue(location: folder.lastPathComponent, message: "This folder could not be read."))
            return
        }

        // `.rtfd` and `.textbundle` are folders that hold one note. The enumerator is told
        // to skip package contents, so they arrive as a single item and are unpacked here
        // rather than as a scattering of `TXT.rtf` files with no client attached.
        for case let url as URL in enumerator {
            guard collection.files.count < fileLimit else {
                collection.issues.append(VaultIssue(
                    location: folder.lastPathComponent,
                    message: "This folder holds more than \(fileLimit) files. Import it in parts."
                ))
                return
            }
            let name = url.lastPathComponent
            guard !ignoredNames.contains(name) else { continue }

            if url.pathExtension.lowercased() == "rtfd" {
                let inner = url.appendingPathComponent("TXT.rtf")
                if FileManager.default.fileExists(atPath: inner.path) {
                    append(inner, base: base, relativeTo: url, into: &collection, maximumFileBytes: maximumFileBytes)
                }
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            append(url, base: base, into: &collection, maximumFileBytes: maximumFileBytes)
        }
    }

    private static func append(
        _ url: URL,
        base: URL,
        relativeTo bundle: URL? = nil,
        into collection: inout Collection,
        maximumFileBytes: Int
    ) {
        let name = (bundle ?? url).lastPathComponent
        do {
            try materialise(url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else { return }
            guard size <= maximumFileBytes else {
                collection.skipped += 1
                collection.issues.append(VaultIssue(
                    location: name,
                    message: "\(name) is \(size / 1_048_576) MB, which is too large to read in one go. It was skipped."
                ))
                return
            }

            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            collection.files.append(ImportFile(
                name: name,
                relativePath: components(of: bundle ?? url, under: base),
                data: data,
                modified: attributes[.modificationDate] as? Date
            ))
        } catch {
            collection.skipped += 1
            collection.issues.append(VaultIssue(location: name, message: "\(name) could not be read: \(error.localizedDescription)"))
        }
    }

    /// A file in iCloud Drive may only be a placeholder. Asking for it and waiting is the
    /// difference between importing someone's records and telling them their files are
    /// missing.
    private static func materialise(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true,
              values?.ubiquitousItemDownloadingStatus != .current else { return }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(downloadTimeout)
        while Date() < deadline {
            let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
            if status == .current { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw ImportError.unsupportedFormat(
            name: url.lastPathComponent,
            detail: "it is still downloading from iCloud. Wait for it to finish and import again."
        )
    }

    private static func components(of url: URL, under base: URL) -> [String] {
        let target = url.standardizedFileURL.pathComponents
        let root = base.standardizedFileURL.pathComponents
        guard target.count > root.count, Array(target.prefix(root.count)) == root else {
            return [url.lastPathComponent]
        }
        return Array(target.dropFirst(root.count))
    }
}
