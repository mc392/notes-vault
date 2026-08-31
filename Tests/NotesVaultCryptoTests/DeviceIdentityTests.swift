import XCTest
import NotesVaultCore
@testable import NotesVaultCrypto

/// `DeviceIdentity.current` carries a per-install suffix so two devices of the same kind
/// (old iPhone + new iPhone, both on the same iCloud account) never write the same
/// filename. These tests exercise the suffix itself, not the platform-specific base.
final class DeviceIdentityTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: "device.suffix")
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "device.suffix")
        try super.tearDownWithError()
    }

    func testSuffixIsStableAcrossReads() {
        let first = DeviceIdentity.current
        let second = DeviceIdentity.current
        XCTAssertEqual(first, second)
    }

    func testSuffixIsRegeneratedOnlyWhenAbsent() {
        let generated = DeviceIdentity.current
        UserDefaults.standard.set("fixed-suffix", forKey: "device.suffix")
        XCTAssertTrue(DeviceIdentity.current.hasSuffix("fixed-suffix"))
        XCTAssertNotEqual(DeviceIdentity.current, generated)
    }

    func testSuffixUsesLowercasedCrockfordCharacters() {
        let name = DeviceIdentity.current
        guard let suffix = name.split(separator: "-").last else {
            return XCTFail("expected a device name of the form base-suffix, got \(name)")
        }
        XCTAssertEqual(suffix.count, 3)
        let crockford = Set(CrockfordBase32.alphabet.map { Character($0.lowercased()) })
        XCTAssertTrue(suffix.allSatisfy { crockford.contains($0) }, "\(suffix) has a character outside the Crockford alphabet")
    }

    /// The device name is written into the note's `device` header, not parsed back out of
    /// the filename — so a suffixed name has to round-trip through the note format, not
    /// just be filename-safe.
    func testSuffixedDeviceNameRoundTripsThroughNoteFormat() throws {
        let device = DeviceIdentity.current
        let note = NoteRecord(
            client: ClientCode(validated: "SM2"),
            session: Fixture.date("2026-06-14T09:30:00+01:00"),
            sessionUTCOffset: 3600,
            device: device,
            body: "x"
        )

        XCTAssertEqual(note.preferredFilename, "2026-06-14T0930-\(device).note")

        let parsed = try NoteRecord.parse(note.serialised())
        XCTAssertEqual(parsed.device, device)
    }
}
