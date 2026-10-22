// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PleviKit",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
        // The watch app links PleviDomain, PleviTransport, PleviKeychain, the two providers and
        // PleviLibraryIndex.
        .watchOS("26.0"),
    ],
    products: [
        .library(name: "PleviDomain", targets: ["PleviDomain"]),
        .library(name: "PleviTransport", targets: ["PleviTransport"]),
        .library(name: "PleviKeychain", targets: ["PleviKeychain"]),
        .library(name: "PleviMockProvider", targets: ["PleviMockProvider"]),
        .library(name: "PleviProviderContract", targets: ["PleviProviderContract"]),
        .library(name: "PleviSubsonicProvider", targets: ["PleviSubsonicProvider"]),
        .library(name: "PleviLibraryIndex", targets: ["PleviLibraryIndex"]),
        .library(name: "PleviPalette", targets: ["PleviPalette"]),
        .library(name: "PleviAudio", targets: ["PleviAudio"]),
        .library(name: "PleviPlexProvider", targets: ["PleviPlexProvider"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Provider-neutral domain models and the MusicServerProvider protocol.
        // Depends on nothing; every other module depends on it.
        .target(name: "PleviDomain"),

        // Per-server networking foundation: endpoint validation, TLS trust
        // evaluation (pinning), redirect policy, session isolation, redaction.
        .target(name: "PleviTransport", dependencies: ["PleviDomain"]),

        // Keychain-backed secret storage. No dependencies so it stays reusable.
        .target(name: "PleviKeychain"),

        // In-memory provider used by previews, UI development, and as the
        // reference implementation the contract suite validates itself against.
        .target(name: "PleviMockProvider", dependencies: ["PleviDomain"]),

        // The contract test suite every MusicServerProvider implementation
        // must pass. Framework-agnostic: returns results, test targets assert.
        .target(name: "PleviProviderContract", dependencies: ["PleviDomain"]),

        // Navidrome / OpenSubsonic backend. The only module that knows
        // Subsonic request and response shapes.
        .target(name: "PleviSubsonicProvider", dependencies: ["PleviDomain", "PleviTransport"]),

        // Local GRDB library index: full-library sync, instant browse and
        // FTS search with zero per-scroll server requests.
        .target(
            name: "PleviLibraryIndex",
            dependencies: [
                "PleviDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // Artwork colour analysis. Deliberately free of UI frameworks so the
        // colour maths can be tested directly.
        .target(name: "PleviPalette"),

        // Playback maths — loudness levelling and EQ curves — kept free of
        // AVFoundation so it can be tested on any platform.
        .target(name: "PleviAudio", dependencies: ["CVorbis"]),

        // stb_vorbis, vendored (public domain / MIT, Sean Barrett): the one decoder the app carries
        // itself, because iOS cannot read Ogg Vorbis.
        .target(name: "CVorbis", cSettings: [.unsafeFlags(["-O3"], .when(configuration: .debug))]),

        // Plex, as an additive provider behind the same protocol. Kept in
        // its own target so nothing Plex-shaped can reach the rest of the
        // app except through `MusicServerProvider`.
        .target(name: "PleviPlexProvider", dependencies: ["PleviDomain", "PleviTransport"]),

        .testTarget(name: "PleviDomainTests", dependencies: ["PleviDomain"]),
        .testTarget(name: "PleviPaletteTests", dependencies: ["PleviPalette"]),
        .testTarget(name: "PleviAudioTests", dependencies: ["PleviAudio"]),
        .testTarget(name: "PleviPlexProviderTests", dependencies: ["PleviPlexProvider"]),
        .testTarget(
            name: "PleviTransportTests",
            dependencies: ["PleviTransport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PleviKeychainTests", dependencies: ["PleviKeychain"]),
        .testTarget(
            name: "PleviContractTests",
            dependencies: ["PleviProviderContract", "PleviMockProvider"]
        ),
        .testTarget(
            name: "PleviSubsonicProviderTests",
            dependencies: ["PleviSubsonicProvider", "PleviProviderContract"]
        ),
        .testTarget(
            name: "PleviLibraryIndexTests",
            dependencies: ["PleviLibraryIndex", "PleviMockProvider"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
