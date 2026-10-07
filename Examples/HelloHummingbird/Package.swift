// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HelloHummingbird",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The SDK in this repository; an app uses .package(url: "https://github.com/docuconf/docuconf-swift", branch: "main").
        .package(name: "docuconf-swift", path: "../.."),
        .package(url: "https://github.com/apple/swift-configuration", from: "1.2.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.5.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Docuconf", package: "docuconf-swift"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
    ]
)
