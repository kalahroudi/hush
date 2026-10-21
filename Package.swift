// swift-tools-version:6.0
import PackageDescription

// No third-party dependencies: keeps the binary small and the memory footprint low.
let package = Package(
    name: "hush",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hush", targets: ["Hush"]),
        .executable(name: "hush-mcp", targets: ["hush-mcp"]),
        .library(name: "HushKit", targets: ["HushKit"]),
    ],
    targets: [
        // UI-free core: everything that touches the system, parses output or decides something. Unit tested.
        .target(name: "HushKit"),
        // The menu bar + Dock app.
        .executableTarget(name: "Hush", dependencies: ["HushKit"]),
        // Model Context Protocol server (stdio) so agents can drive the app's capabilities.
        .executableTarget(name: "hush-mcp", dependencies: ["HushKit"]),
        .testTarget(name: "HushKitTests", dependencies: ["HushKit", "hush-mcp"]),   // hush-mcp is built so the tests can run the real server
    ],
    swiftLanguageModes: [.v5]
)
