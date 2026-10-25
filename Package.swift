// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NousBrowser",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NousBrowser", targets: ["NousBrowser"])
    ],
    targets: [
        .executableTarget(name: "NousBrowser", path: "Sources/NousBrowser"),
        .testTarget(
            name: "NousBrowserTests",
            dependencies: ["NousBrowser"],
            path: "Tests/NousBrowserTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
