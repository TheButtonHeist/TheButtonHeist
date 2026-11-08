// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ButtonHeistConventions",
    platforms: [.macOS(.v15)],
    products: [.library(name: "BumperRules", targets: ["BumperRules"])],
    dependencies: [
        .package(url: "https://github.com/TheButtonHeist/BumperBowling.git", exact: "0.7.2")
    ],
    targets: [
        .target(
            name: "BumperRules",
            dependencies: [
                .product(name: "BumperBowlingCore", package: "BumperBowling")
            ], swiftSettings: [.treatAllWarnings(as: .error)]),
        .executableTarget(name: "BumperRulesRunner", dependencies: ["BumperRules"]),
        .testTarget(
            name: "BumperRulesTests",
            dependencies: [
                "BumperRules",
                .product(name: "BumperBowlingTestSupport", package: "BumperBowling"),
            ], swiftSettings: [.treatAllWarnings(as: .error)]),
    ]
)
