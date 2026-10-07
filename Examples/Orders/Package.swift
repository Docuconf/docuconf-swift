// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Orders",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The SDK in this repository, not a published release. `name:` lets the product reference below say
        // "docuconf-swift" whatever the checkout's folder is called (a fork, a ZIP's docuconf-swift-main).
        .package(name: "docuconf-swift", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "Orders",
            dependencies: [.product(name: "Docuconf", package: "docuconf-swift")]
        ),
    ]
)
