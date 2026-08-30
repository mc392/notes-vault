// swift-tools-version:5.9
import PackageDescription

// The app target itself lives in the Xcode project (generated from project.yml) because
// iOS/macOS app bundles cannot be expressed in SwiftPM. Everything below the UI can be,
// and is — so the whole storage/crypto/retention core builds and tests with `swift test`,
// with no Xcode involved.
let package = Package(
    name: "NotesVault",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "NotesVaultCore", targets: ["NotesVaultCore"]),
        .library(name: "NotesVaultCrypto", targets: ["NotesVaultCrypto"])
    ],
    dependencies: [
        // The audited vault format. Decision 04: reuse Cryptomator rather than roll our own.
        .package(url: "https://github.com/cryptomator/cryptolib-swift.git", from: "1.0.0")
    ],
    targets: [
        // Pure logic. Deliberately has NO crypto dependency: it talks to a `CryptoEngine`
        // protocol, so vault layout, retention and the note format are all testable
        // without scrypt burning a second per test case.
        .target(name: "NotesVaultCore"),
        .target(
            name: "NotesVaultCrypto",
            dependencies: [
                "NotesVaultCore",
                .product(name: "CryptomatorCryptoLib", package: "cryptolib-swift")
            ]
        ),
        .testTarget(
            name: "NotesVaultCoreTests",
            dependencies: ["NotesVaultCore"]
        ),
        // The core tests run against a stub engine, which proves the layout logic but says
        // nothing about whether what lands on disk is a real Cryptomator vault. These run
        // the actual cryptography against a real temporary folder, so the format itself is
        // under test rather than assumed. Slower — every vault creation is two scrypt
        // derivations — but this is the target that would catch a wrong directory hash or
        // an unsigned vault config.
        .testTarget(
            name: "NotesVaultCryptoTests",
            dependencies: ["NotesVaultCore", "NotesVaultCrypto"]
        )
    ],
    // Swift 5 language mode, so Swift 6's strict concurrency checking does not turn this
    // into a concurrency port before it has ever compiled once.
    //
    // This is the tools-5.9 spelling. The per-target `.swiftLanguageMode(.v5)` setting is a
    // Swift 6 API and does not exist in the 5.x PackageDescription — using it made the
    // manifest itself unparseable on Xcode 15, which is what the first CI run hit.
    swiftLanguageVersions: [.v5]
)
