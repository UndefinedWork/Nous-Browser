// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Nous Core: Chromium's //chrome layer plus the //nous embedding API, built as
// NousCore.framework from the Chromium tree (see Engine/README.md). Like Dia's
// ArcCore.framework it is linked directly and imported as a Clang module.
let repositoryPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let nousCoreSDK = ProcessInfo.processInfo.environment["NOUS_CORE_SDK_DIR"]
    ?? repositoryPath + "/.build/nouscore/sdk"
let nousCoreSwift: [SwiftSetting] = [.unsafeFlags(["-F", nousCoreSDK])]
let nousCoreLink: [LinkerSetting] = [.unsafeFlags(["-F", nousCoreSDK, "-framework", "NousCore"])]

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
        .executableTarget(
            name: "NousBrowser",
            dependencies: ["NousAutomation", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/NousBrowser",
            swiftSettings: [.define("NOUS_CHROMIUM")] + nousCoreSwift,
            linkerSettings: nousCoreLink + [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "NousMCP",
            dependencies: ["NousAutomation", .product(name: "MCP", package: "swift-sdk")],
            path: "Sources/NousMCP"
        ),
        .testTarget(
            name: "NousBrowserTests",
            dependencies: ["NousBrowser", "NousAutomation"],
            path: "Tests/NousBrowserTests",
            swiftSettings: [.define("NOUS_CHROMIUM")] + nousCoreSwift,
            linkerSettings: nousCoreLink + [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", nousCoreSDK])]
        ),
        .testTarget(
            name: "NousAutomationTests",
            dependencies: ["NousAutomation", "NousMCP", .product(name: "MCP", package: "swift-sdk")],
            path: "Tests/NousAutomationTests"
        )
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx20
)
