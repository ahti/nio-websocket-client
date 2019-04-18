// swift-tools-version:5.0
import PackageDescription

let package = Package(
    name: "swift-nio-websocket-client",
    products: [
        .library(name: "NIOWebSocketClient", targets: ["NIOWebSocketClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "NIOWebSocketClient", dependencies: [
            "NIO", "NIOConcurrencyHelpers", "NIOHTTP1", "NIOSSL", "NIOWebSocket"
        ]),
        .testTarget(name: "NIOWebSocketClientTests", dependencies: ["NIOWebSocketClient"]),
    ]
)
