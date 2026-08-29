import Foundation
import CryptoKit
import LocalAuthentication
import NotesVaultCore

/// The device keychain, holding the two secrets that are allowed to persist locally.
///
/// The architecture says the per-device key is "held only in the platform keychain" — this
/// is that. Two items, both scoped `ThisDeviceOnly` so they are never carried to a new
/// device by a backup, which would quietly turn a stolen iCloud backup into a way into the
/// vault:
///
/// 1. **the local index key** — encrypts the on-device cache, and nothing else;
/// 2. **the vault passphrase**, optional, behind Face ID / Touch ID, so daily use does not
///    mean typing a long passphrase before every note.
///
/// Neither is ever written into the vault folder, so neither is ever synced anywhere.
public enum KeychainStore {
    private static let service = "com.charlottebloor.notesvault"

    public enum Purpose: String {
        case indexKey = "index-key"
        case passphrase = "passphrase"
    }

    private static func baseQuery(_ purpose: Purpose, vaultID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(purpose.rawValue):\(vaultID)",
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    // MARK: - Index key

    /// Fetches the index key, creating one the first time. Losing it is harmless — the
    /// index is a cache and is rebuilt from the vault — so a failure here never blocks
    /// opening a vault.
    public static func indexKey(vaultID: String) -> SymmetricKey? {
        if let existing = read(.indexKey, vaultID: vaultID) {
            return SymmetricKey(data: existing)
        }
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        guard write(data, purpose: .indexKey, vaultID: vaultID, requiresBiometrics: false) else { return nil }
        return fresh
    }

    // MARK: - Passphrase (optional, biometric)

    public static var biometricsAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    @discardableResult
    public static func storePassphrase(_ passphrase: String, vaultID: String) -> Bool {
        write(Data(passphrase.utf8), purpose: .passphrase, vaultID: vaultID, requiresBiometrics: true)
    }

    /// Prompts for Face ID / Touch ID and returns the stored passphrase.
    ///
    /// Returns nil rather than throwing when the user cancels — declining to use biometrics
    /// is a normal choice, not an error, and the passphrase field is still right there.
    public static func passphrase(vaultID: String, reason: String) -> String? {
        let context = LAContext()
        context.localizedReason = reason

        var query = baseQuery(.passphrase, vaultID: vaultID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func hasStoredPassphrase(vaultID: String) -> Bool {
        var query = baseQuery(.passphrase, vaultID: vaultID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Attributes only, never the data. Asking for attributes does not trigger the
        // biometric prompt, so the Unlock screen can find out whether to offer Face ID
        // without setting it off just by being drawn.
        query[kSecReturnAttributes as String] = true

        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Primitives

    @discardableResult
    public static func remove(_ purpose: Purpose, vaultID: String) -> Bool {
        let status = SecItemDelete(baseQuery(purpose, vaultID: vaultID) as CFDictionary)
        // "It was not there" is the outcome the caller wanted, so it counts as success.
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Forgets everything this device holds about a vault. Called when the vault is removed
    /// from the app, so nothing is left behind pointing at notes that are no longer there.
    public static func forget(vaultID: String) {
        remove(.indexKey, vaultID: vaultID)
        remove(.passphrase, vaultID: vaultID)
    }

    private static func read(_ purpose: Purpose, vaultID: String) -> Data? {
        var query = baseQuery(purpose, vaultID: vaultID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func write(_ data: Data, purpose: Purpose, vaultID: String, requiresBiometrics: Bool) -> Bool {
        // Replace rather than update: an access-control change (turning biometrics on) does
        // not take effect on an existing item.
        _ = SecItemDelete(baseQuery(purpose, vaultID: vaultID) as CFDictionary)

        var query = baseQuery(purpose, vaultID: vaultID)
        query[kSecValueData as String] = data

        if requiresBiometrics {
            // `.userPresence` rather than `.biometryAny`: it falls back to the device
            // passcode, so a counsellor whose Face ID fails in poor light is not locked out
            // of their own records.
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                .userPresence,
                nil
            ) else { return false }
            query[kSecAttrAccessControl as String] = access
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
