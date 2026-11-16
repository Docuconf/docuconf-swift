// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Shop",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The SDK in this repository, not a published release. `name:` lets the product reference below say
        // "docuconf-swift" whatever the checkout's folder is called (a fork, a ZIP's docuconf-swift-main).
        .package(name: "docuconf-swift", path: "../.."),
    ],
    targets: [
        // Contract-first mode (ContractDocument) is in DocuconfCore, which needs nothing but Foundation.
        .executableTarget(
            name: "Shop",
            dependencies: [
                .product(name: "DocuconfCore", package: "docuconf-swift"),
            ]
        ),
        .testTarget(
            name: "ShopTests",
            dependencies: ["Shop"]
        ),
    ]
)
