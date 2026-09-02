import XCTest
@testable import NotesVaultCrypto

/// `KeychainStore.passphrase` can't run in plain `swift test` — it needs a device to prompt
/// Face ID on — so what is testable is pulled out as a pure function from `OSStatus` to
/// `PassphraseResult`, and that mapping is what these assert.
final class KeychainStoreTests: XCTestCase {
    func testUserCancelMapsToCancelled() {
        XCTAssertEqual(KeychainStore.passphraseResult(for: errSecUserCanceled), .cancelled)
    }

    /// Separated from a cancel on purpose: a decline leaves the unlock screen as it was, a
    /// failed check makes the passphrase the only way back in.
    func testAuthFailedMapsToFailed() {
        XCTAssertEqual(KeychainStore.passphraseResult(for: errSecAuthFailed), .failed)
    }

    func testItemNotFoundMapsToUnavailable() {
        XCTAssertEqual(KeychainStore.passphraseResult(for: errSecItemNotFound), .unavailable)
    }

    func testOtherStatusMapsToUnavailable() {
        XCTAssertEqual(KeychainStore.passphraseResult(for: errSecParam), .unavailable)
    }
}
