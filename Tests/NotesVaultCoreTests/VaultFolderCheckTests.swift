import XCTest
@testable import NotesVaultCore

final class VaultFolderCheckTests: XCTestCase {

    private func assess(_ name: String, path: [String] = [], contents: [String]) -> VaultFolderVerdict {
        VaultFolderCheck.assess(folderName: name, pathComponents: path, contents: contents)
    }

    // MARK: - The two ordinary answers

    func testAnEmptyFolderCanHoldANewVault() {
        XCTAssertEqual(assess("Clinical Notes", contents: []), .usable)
    }

    func testAFolderOfUnrelatedFilesCanStillHoldAVault() {
        // Not ideal, but not dangerous — the vault's own files do not collide with these.
        XCTAssertEqual(
            assess("Documents", contents: ["Tax return.pdf", "photo.jpg"]),
            .usable
        )
    }

    func testAVaultIsRecognisedSoItIsOpenedRatherThanCreated() {
        XCTAssertEqual(
            assess("Clinical Notes", contents: [
                "masterkey.cryptomator", "vault.cryptomator", "masterkey.recovery.cryptomator", "d"
            ]),
            .existingVault
        )
    }

    /// A folder holding only one of the two marker files is not a vault. Creating one there
    /// would be wrong, but so would trying to unlock it.
    func testAHalfWrittenVaultIsNotTreatedAsAVault() {
        XCTAssertNotEqual(assess("Half", contents: ["masterkey.cryptomator"]), .existingVault)
    }

    // MARK: - The failure this exists to prevent

    /// The real case: the picker invites you to walk into `d`, then into a two-letter
    /// folder, and the folder you land on looks empty and reasonable.
    func testTheShardFolderTheDocumentPickerInvitesYouIntoIsRefused() {
        let verdict = assess(
            "P6JOOVICDH7EYT3HEDPCPMZVJ7ACDI",
            path: ["/", "Clinical Notes", "d", "HK", "P6JOOVICDH7EYT3HEDPCPMZVJ7ACDI"],
            contents: []
        )
        guard case .insideAnotherVault = verdict else {
            return XCTFail("a shard folder must be refused, got \(verdict)")
        }
    }

    func testAFolderHoldingCiphertextIsRefused() {
        let verdict = assess("HK", contents: ["-Ifqzzdq2hVj8S96xg_eZKcDOw==.c9r"])
        guard case .insideAnotherVault = verdict else {
            return XCTFail("expected refusal, got \(verdict)")
        }
    }

    /// Shortened names, which a vault made by Cryptomator itself uses.
    func testAFolderHoldingShortenedNamesIsRefused() {
        let verdict = assess("HK", contents: ["4-23m1tfK8_eRHq7Y76-L1fAgIM=.c9s"])
        guard case .insideAnotherVault = verdict else {
            return XCTFail("expected refusal, got \(verdict)")
        }
    }

    func testAClientsOwnFolderIsRefused() {
        for marker in ["dir.c9r", "dirid.c9r"] {
            let verdict = assess("SM2", contents: [marker])
            guard case .insideAnotherVault = verdict else {
                return XCTFail("expected refusal for \(marker), got \(verdict)")
            }
        }
    }

    func testTheDataRootIsRefused() {
        let verdict = assess("d", contents: ["HK", "MG", "TM"])
        guard case .insideAnotherVault = verdict else {
            return XCTFail("expected refusal, got \(verdict)")
        }
    }

    // MARK: - Not over-reaching

    /// A counsellor is allowed to call their own folder `d`. Only the data root's shape —
    /// a `d` full of two-character names — is refused.
    func testAnEmptyFolderCalledDIsStillUsable() {
        XCTAssertEqual(assess("d", contents: []), .usable)
    }

    func testAFolderCalledDWithOrdinaryContentsIsUsable() {
        XCTAssertEqual(assess("d", contents: ["notes.txt", "January"]), .usable)
    }

    /// `d` appearing somewhere harmless in the path must not trip the shard rule — only a
    /// `d` followed by a two-character folder does.
    func testADInThePathThatIsNotAVaultIsUsable() {
        XCTAssertEqual(
            assess("Notes", path: ["/", "Users", "d", "Documents", "Notes"], contents: []),
            .usable
        )
    }

    /// The folder the counsellor is actually meant to pick, with a vault already in it,
    /// must never be mistaken for the innards of one.
    func testTheVaultRootIsNeverMistakenForItsOwnInsides() {
        let verdict = assess(
            "Clinical Notes",
            path: ["/", "iCloud Drive", "Clinical Notes"],
            contents: ["masterkey.cryptomator", "vault.cryptomator", "d"]
        )
        XCTAssertEqual(verdict, .existingVault)
    }
}
