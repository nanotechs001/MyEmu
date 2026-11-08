// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyEmu",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MyEmu", targets: ["MyEmu"]),
        // Loaded into the emulator engine; gfxstream presents straight into MyEmu's window.
        .library(name: "MyEmuDisplay", type: .dynamic, targets: ["MyEmuDisplay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        // Already pulled in by gRPC; named here for the MCP server's HTTP.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    ],
    targets: [
        .executableTarget(
            name: "MyEmu",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            plugins: [.plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")]
        ),
        .target(
            name: "MyEmuDisplay",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("QuartzCore"),
                             .linkedFramework("CoreGraphics")]
        ),
        // Resources/autopots: game screenshots from autopotsCO's own tests.
        .testTarget(name: "MyEmuTests", dependencies: ["MyEmu"], resources: [.copy("Resources")]),
    ]
)
