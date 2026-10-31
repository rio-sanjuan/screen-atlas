// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenAtlas",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "screenatlas", targets: ["screenatlas"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    ],
    targets: [
        .target(
            name: "AtlasKit",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "screenatlas",
            dependencies: [
                "AtlasKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "AtlasKitTests", dependencies: ["AtlasKit"]),
    ]
)
