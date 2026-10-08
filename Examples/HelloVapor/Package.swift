// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HelloVapor",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The SDK in this repository; an app uses .package(url: "https://github.com/docuconf/docuconf-swift", branch: "main").
        .package(name: "docuconf-swift", path: "../.."),
        .package(url: "https://github.com/vapor/vapor", from: "4.110.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Docuconf", package: "docuconf-swift"),
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
    ]
)
