import XCTest
@testable import NotesVaultCore

final class CrockfordBase32Tests: XCTestCase {
    func testRoundTripsEveryLength() throws {
        for length in 0...40 {
            let bytes = (0..<length).map { UInt8(($0 &* 37 &+ 11) & 0xFF) }
            let decoded = try CrockfordBase32.decode(CrockfordBase32.encode(bytes))
            XCTAssertEqual(decoded, bytes, "failed at length \(length)")
        }
    }

    func testAlphabetExcludesTheConfusableLetters() {
        for character in "ILOU" {
            XCTAssertFalse(CrockfordBase32.alphabet.contains(character), "\(character) should not be in the alphabet")
        }
        XCTAssertEqual(CrockfordBase32.alphabet.count, 32)
    }

    /// The whole reason for choosing this alphabet: someone reading their own handwriting
    /// off a card years later will write `O` for zero and `I` for one.
    func testFoldsTheLettersPeopleActuallyMistype() throws {
        let bytes: [UInt8] = [0x00, 0x11, 0x22]
        let encoded = CrockfordBase32.encode(bytes)
        let mistyped = encoded
            .replacingOccurrences(of: "0", with: "O")
            .replacingOccurrences(of: "1", with: "I")
        XCTAssertEqual(try CrockfordBase32.decode(mistyped), bytes)
    }

    func testIgnoresHyphensSpacesAndCase() throws {
        let bytes: [UInt8] = [1, 2, 3, 4, 5]
        let encoded = CrockfordBase32.encode(bytes)
        let messy = encoded.lowercased().map { String($0) }.joined(separator: " ")
        XCTAssertEqual(try CrockfordBase32.decode(messy), bytes)
    }

    func testRejectsForeignCharacters() {
        XCTAssertThrowsError(try CrockfordBase32.decode("ABC!"))
    }
}

final class RecoveryKeyTests: XCTestCase {
    func testFormatsAsNineGroupsOfFour() {
        let key = RecoveryKey()
        let groups = key.formatted.split(separator: "-")
        XCTAssertEqual(groups.count, RecoveryKey.groupCount)
        XCTAssertTrue(groups.allSatisfy { $0.count == RecoveryKey.groupSize })
        XCTAssertEqual(key.passphrase.count, RecoveryKey.groupCount * RecoveryKey.groupSize)
    }

    func testRoundTrips() throws {
        let key = RecoveryKey()
        XCTAssertEqual(try RecoveryKey(typed: key.formatted).entropy, key.entropy)
    }

    func testAcceptsItTypedBackCarelessly() throws {
        let key = RecoveryKey()
        let careless = key.formatted.lowercased().replacingOccurrences(of: "-", with: " ")
        XCTAssertEqual(try RecoveryKey(typed: careless).entropy, key.entropy)
    }

    /// The checksum earns its place here. Every single-character substitution must be
    /// caught at the point of typing — otherwise a counsellor is told "wrong recovery key"
    /// and has no idea whether the key is wrong or their vault is broken.
    func testCatchesEverySingleCharacterTypo() throws {
        let key = try RecoveryKey(entropy: Array(repeating: 0xA5, count: RecoveryKey.entropyBytes))
        let characters = Array(key.passphrase)

        // Every substitution is a burst error of at most five bits, which CRC-16/CCITT
        // detects without exception — so the expected number accepted is zero, not "few".
        var accepted: [String] = []
        for position in characters.indices {
            for replacement in CrockfordBase32.alphabet where replacement != characters[position] {
                var mutated = characters
                mutated[position] = replacement
                if (try? RecoveryKey(typed: String(mutated))) != nil {
                    accepted.append(String(mutated))
                }
            }
        }
        XCTAssertEqual(accepted, [], "\(accepted.count) single-character typos were accepted as valid keys")
    }

    func testRejectsAKeyOfTheWrongLength() {
        XCTAssertThrowsError(try RecoveryKey(typed: "ABCD-EFGH"))
    }

    func testTwoKeysDiffer() {
        XCTAssertNotEqual(RecoveryKey().entropy, RecoveryKey().entropy)
    }
}
