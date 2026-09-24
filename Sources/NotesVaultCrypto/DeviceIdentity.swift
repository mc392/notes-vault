import Foundation
import NotesVaultCore

#if canImport(UIKit)
import UIKit
#endif

/// Which device wrote a file. Part of every filename, so two devices writing the same
/// client in the same minute produce two files instead of one overwrite.
public enum DeviceIdentity {
    private static let suffixDefaultsKey = "device.suffix"
    private static let suffixLength = 3

    private static var base: String {
        #if os(iOS)
        let name = UIDevice.current.model.lowercased()
        return name.contains("ipad") ? "ipad" : "iphone"
        #elseif os(macOS)
        return "mac"
        #else
        return "device"
        #endif
    }

    /// A short random suffix, generated once per install and persisted in `UserDefaults` —
    /// this is a stable label, not a secret, so it doesn't belong in the keychain. Without
    /// it, two iPhones on the same iCloud account (old phone + new phone) both write
    /// `…-iphone.note` and collide; the suffix makes the device segment unique per install
    /// rather than per model.
    private static var suffix: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: suffixDefaultsKey), !existing.isEmpty {
            return existing
        }
        let alphabet = CrockfordBase32.alphabet
        let generated = String((0..<suffixLength).map { _ in alphabet.randomElement()! }).lowercased()
        defaults.set(generated, forKey: suffixDefaultsKey)
        return generated
    }

    /// e.g. `iphone-k3m`, `mac-7f2`. Existing files written before this suffix existed
    /// (`…-iphone.note`) are untouched and remain valid — names are just names in an
    /// append-only store, and nothing parses structure back out of them.
    public static var current: String {
        "\(base)-\(suffix)"
    }
}
