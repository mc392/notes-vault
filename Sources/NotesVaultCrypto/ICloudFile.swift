import Foundation

/// Getting a file out of iCloud Drive and onto this device.
///
/// A file in iCloud Drive may be nothing but a placeholder on a device that has not opened
/// its folder in a while — on disk as `.name.icloud`, beside where the real file will be.
/// Reading it means asking for it and waiting. The vault, the schedule file and the
/// importer all need that, and each used to have its own copy of the asking and the
/// waiting, with slightly different rules about when to stop; this is the one copy.
///
/// Nothing here knows what iCloud is beyond that. There is no iCloud API in this app and
/// no network call: `startDownloadingUbiquitousItem` asks the operating system's own sync
/// client for bytes it already knows about.
public enum ICloudFile {
    /// The placeholder beside `target`, if there is one.
    public static func placeholderURL(for target: URL) -> URL? {
        let placeholder = target
            .deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path) ? placeholder : nil
    }

    /// The name a directory entry will have once downloaded, if it is a placeholder:
    /// `.SM2.c9r.icloud` → `SM2.c9r`. Nil for anything else.
    public static func materialisedName(for entry: String) -> String? {
        guard entry.hasPrefix("."), entry.hasSuffix(".icloud"), entry.count > ".icloud".count + 1 else { return nil }
        return String(entry.dropFirst().dropLast(".icloud".count))
    }

    /// Whether the bytes are on this device.
    ///
    /// `acceptingLocalCopy` is the one real difference between the callers. The vault never
    /// changes a file once written, so any local copy of one is the right copy. The
    /// schedule file is rewritten by GroundWork, so only the *latest* version will do.
    public static func isDownloaded(_ url: URL, acceptingLocalCopy: Bool) -> Bool {
        let presentLocally = FileManager.default.fileExists(atPath: url.path) && placeholderURL(for: url) == nil
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true else { return presentLocally }
        if values?.ubiquitousItemDownloadingStatus == .current { return true }
        return acceptingLocalCopy && presentLocally
    }

    /// Asks for a download and returns at once. False when the file is not in iCloud at
    /// all — a plain local file, or one that genuinely is not there.
    @discardableResult
    public static func requestDownload(_ url: URL) -> Bool {
        (try? FileManager.default.startDownloadingUbiquitousItem(at: url)) != nil
    }

    public enum Outcome: Equatable, Sendable {
        /// The file is on this device and can be read.
        case ready
        /// Not an iCloud item. Nothing to wait for; whether it exists is the caller's to find out.
        case notInICloud
        /// Asked for, and not here by the deadline.
        case timedOut
    }

    /// Asks for the file and waits up to `timeout` for it. A timeout of zero asks and
    /// returns — anything on the main thread should, because this blocks.
    ///
    /// Call inside the file's security scope: the request is a use of the file too.
    public static func materialise(
        _ url: URL,
        timeout: TimeInterval,
        acceptingLocalCopy: Bool,
        pollInterval: TimeInterval = 0.2
    ) -> Outcome {
        if isDownloaded(url, acceptingLocalCopy: acceptingLocalCopy) { return .ready }
        guard requestDownload(url) else { return .notInICloud }
        guard timeout > 0 else { return .timedOut }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isDownloaded(url, acceptingLocalCopy: acceptingLocalCopy) { return .ready }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return isDownloaded(url, acceptingLocalCopy: acceptingLocalCopy) ? .ready : .timedOut
    }
}
