// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Docuconf",
    platforms: [
        // swift-configuration 1.x requires these.
        .macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2),
    ],
    products: [
        // Server SDK: load and validate configuration at boot with swift-configuration.
        .library(name: "Docuconf", targets: ["Docuconf"]),
        // Declaration model and contract writer. Foundation only, so it builds anywhere
        // Swift does (including iOS), with no server or Linux-only dependencies.
        .library(name: "DocuconfCore", targets: ["DocuconfCore"]),
    ],
    traits: [
        // Off by default, so an app that declares only variables and config files does not build
        // swift-certificates and swift-crypto. Turn it on to check TLS key pairs, CA bundles and keystores:
        //   .package(url: "https://github.com/docuconf/docuconf-swift", branch: "main", traits: ["TLS"])
        .trait(name: "TLS", description: "Boot checks for TLS key pairs, CA bundles and keystores (swift-certificates, swift-crypto)."),
        .default(enabledTraits: []),
    ],
    dependencies: [
        // YAML adds YAMLSnapshot, for YAML config-file overlays (it uses Yams, which docuconf already needs).
        .package(url: "https://github.com/apple/swift-configuration", from: "1.2.0", traits: ["JSON", "YAML"]),
        .package(url: "https://github.com/apple/swift-certificates", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto", "3.12.3"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-asn1", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams", "5.4.0"..<"7.0.0"),
    ],
    targets: [
        .target(name: "DocuconfCore"),
        .target(
            name: "Docuconf",
            dependencies: [
                "DocuconfCore",
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "X509", package: "swift-certificates", condition: .when(traits: ["TLS"])),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(traits: ["TLS"])),
                .product(name: "SwiftASN1", package: "swift-asn1", condition: .when(traits: ["TLS"])),
            ]
        ),
        // A runnable example; not a product. Its TLS input needs the trait: swift run --traits TLS GatewayExample
        .executableTarget(
            name: "GatewayExample",
            dependencies: ["Docuconf", .product(name: "Configuration", package: "swift-configuration")],
            path: "Examples/Gateway",
            exclude: ["dev-root", "contract.cue"]
        ),
        // Runs cue for the tests: vets exported contracts and renders overlays with the meta-schema.
        .target(name: "CueTestSupport", path: "Tests/CueTestSupport"),
        .testTarget(name: "DocuconfCoreTests", dependencies: ["DocuconfCore", "CueTestSupport"], exclude: ["Golden"]),
        .testTarget(
            name: "DocuconfTests",
            dependencies: [
                "Docuconf",
                "CueTestSupport",
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "X509", package: "swift-certificates", condition: .when(traits: ["TLS"])),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(traits: ["TLS"])),
                .product(name: "_CryptoExtras", package: "swift-crypto", condition: .when(traits: ["TLS"])),
                .product(name: "SwiftASN1", package: "swift-asn1", condition: .when(traits: ["TLS"])),
            ],
            exclude: ["Fixtures"]
        ),
    ]
)
