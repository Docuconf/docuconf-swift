// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Orders",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The SDK in this repository, not a published release. `name:` lets the product reference below say
        // "docuconf-swift" whatever the checkout's folder is called (a fork, a ZIP's docuconf-swift-main).
        .package(name: "docuconf-swift", path: "../.."),
        // HMAC-SHA256 for the payment webhook signatures, on Linux as on macOS.
        .package(url: "https://github.com/apple/swift-crypto", "3.12.3"..<"6.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Orders",
            dependencies: [
                .product(name: "Docuconf", package: "docuconf-swift"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "OrdersTests",
            dependencies: ["Orders"]
        ),
    ]
)
