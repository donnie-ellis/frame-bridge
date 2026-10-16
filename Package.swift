// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "frame-bridge",
    // EventKit full-access APIs need macOS 14. The Mac mini (Intel) tops out at macOS 15.
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FrameBridge", targets: ["FrameBridge"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.1"),
        // Hummingbird 2.27.1 imports ServiceContextModule, which tracing 1.6.0 stopped depending
        // on. Drop this pin once Hummingbird builds against tracing 1.6+.
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", .upToNextMinor(from: "1.5.0")),
    ],
    targets: [
        .executableTarget(
            name: "FrameBridge",
            dependencies: ["FrameBridgeCore"]
        ),
        .target(
            name: "FrameBridgeCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .testTarget(
            name: "FrameBridgeCoreTests",
            dependencies: [
                "FrameBridgeCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
