// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Docuconf",
    platforms: [
        // swift-configuration 1.x requires these.
        .macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2),
    ],
    products: [
        // Declaration model and contract writer. Foundation only, so it builds anywhere
        // Swift does (including iOS), with no server or Linux-only dependencies.
        .library(name: "DocuconfCore", targets: ["DocuconfCore"]),
    ],
    targets: [
        .target(name: "DocuconfCore"),
        .testTarget(name: "DocuconfCoreTests", dependencies: ["DocuconfCore"], exclude: ["Golden"]),
    ]
)
