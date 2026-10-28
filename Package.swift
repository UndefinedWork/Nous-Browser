// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NousBrowser",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NousBrowser", targets: ["NousBrowser"]),
        .executable(name: "NousBrowserMCP", targets: ["NousMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "NousAutomation", path: "Sources/NousAutomation"),
        .executableTarget(name: "NousBrowser", dependencies: ["NousAutomation", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/NousBrowser",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]) ]),
        .executableTarget(
            name: "NousMCP",
            dependencies: ["NousAutomation", .product(name: "MCP", package: "swift-sdk")],
            path: "Sources/NousMCP"
        ),
        .testTarget(
            name: "NousBrowserTests",
            dependencies: ["NousBrowser", "NousAutomation"],
            path: "Tests/NousBrowserTests"
        ),
        .testTarget(
            name: "NousAutomationTests",
            dependencies: ["NousAutomation", "NousMCP", .product(name: "MCP", package: "swift-sdk")],
            path: "Tests/NousAutomationTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
