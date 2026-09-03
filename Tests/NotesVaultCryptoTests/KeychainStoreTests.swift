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

    // MARK: - "Is there one?", which must never itself ask

    func testAStoredPassphraseIsFound() {
        XCTAssertTrue(KeychainStore.hasPassphrase(for: errSecSuccess))
    }

    /// The one that matters. Asking for the item while forbidding any prompt is refused
    /// with `errSecInteractionNotAllowed` — and that refusal *is* the answer: something is
    /// there, and handing it over would need a check. Read as "no", the unlock screen stops
    /// offering Face ID to someone who has it set up. Read as "ask", a screen sets off a
    /// Face ID prompt by being drawn, and drawing happens again every time anything on the
    /// screen changes.
    func testAnItemThatWouldNeedACheckStillCountsAsStored() {
        XCTAssertTrue(KeychainStore.hasPassphrase(for: errSecInteractionNotAllowed))
    }

    func testNoItemIsNotStored() {
        XCTAssertFalse(KeychainStore.hasPassphrase(for: errSecItemNotFound))
    }

    func testAnUnreadableKeychainIsNotStored() {
        XCTAssertFalse(KeychainStore.hasPassphrase(for: errSecParam))
    }
}
