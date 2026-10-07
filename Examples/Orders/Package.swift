// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Orders",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The SDK in this repository, not a published release.
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "Orders",
            dependencies: [.product(name: "Docuconf", package: "docuconf-swift")]
        ),
    ]
)
