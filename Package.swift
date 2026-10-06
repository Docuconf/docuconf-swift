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
    dependencies: [
        .package(url: "https://github.com/apple/swift-configuration", from: "1.2.0"),
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
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        // A runnable example; not a product.
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
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            exclude: ["Fixtures"]
        ),
    ]
)
