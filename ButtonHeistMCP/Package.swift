// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ButtonHeistMCP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "buttonheist-mcp", targets: ["ButtonHeistMCP"])
    ],
    dependencies: [
        .package(name: "ButtonHeist", path: ".."),
        .package(url: "https://github.com/TheButtonHeist/AccessibilitySnapshotBH", exact: "0.25.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.0"))
    ],
    targets: [
        .executableTarget(
            name: "ButtonHeistMCP",
            dependencies: [
                .product(name: "ButtonHeist", package: "ButtonHeist"),
                .product(name: "TheScore", package: "ButtonHeist"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-parse-as-library", "-warnings-as-errors"])
            ]
        ),
        .testTarget(
            name: "ButtonHeistMCPTests",
            dependencies: [
                "ButtonHeistMCP",
                .product(name: "ButtonHeist", package: "ButtonHeist"),
                .product(name: "TheScore", package: "ButtonHeist"),
                .product(name: "AccessibilitySnapshotModel", package: "AccessibilitySnapshotBH"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Tests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-warnings-as-errors"])
            ]
        )
    ]
)
