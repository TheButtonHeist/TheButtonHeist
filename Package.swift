// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ButtonHeist",
    platforms: [
        .iOS(.v16),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ThePlans", targets: ["ThePlans"]),
        .library(name: "TheScore", targets: ["TheScore"]),
        .executable(name: "heist-plan", targets: ["HeistPlanTool"]),
        .executable(name: "heist-doctor", targets: ["HeistDoctorTool"]),
        // TheInsideJob with auto-start: includes both Swift implementation and ObjC loader
        .library(name: "TheInsideJob", targets: ["TheInsideJob", "ThePlant"]),
        .library(name: "ButtonHeistTesting", targets: ["ButtonHeistTesting"]),
        .library(name: "ButtonHeist", targets: ["ButtonHeist"])
    ],
    dependencies: [
        // Parser semantics are part of Button Heist's release contract.
        // Keep this exact tag aligned with submodules/AccessibilitySnapshotBH
        // via scripts/check-parser-contract.sh and scripts/bump-parser.sh.
        .package(url: "https://github.com/TheButtonHeist/AccessibilitySnapshotBH", exact: "0.25.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMinor(from: "1.7.0")),
        // Source-shape validation runs the dependency's executable product
        // directly through SwiftPM; it is not linked into a Button Heist target.
        .package(url: "https://github.com/TheButtonHeist/BumperBowling.git", exact: "0.6.0"),
    ],
    targets: [
        .target(
            name: "ButtonHeistSupport",
            dependencies: [],
            path: "ButtonHeist/Sources/ButtonHeistSupport"
        ),
        .target(
            name: "ThePlans",
            dependencies: [],
            path: "ButtonHeist/Sources/ThePlans"
        ),
        .target(
            name: "TheScore",
            dependencies: [
                "ThePlans",
                .product(name: "AccessibilitySnapshotModel", package: "AccessibilitySnapshotBH"),
            ],
            path: "ButtonHeist/Sources/TheScore"
        ),
        .executableTarget(
            name: "HeistPlanTool",
            dependencies: [
                "ThePlans",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "ButtonHeist/Sources/HeistPlanTool"
        ),
        .target(
            name: "HeistDoctorCore",
            dependencies: [
                "ThePlans",
                "TheScore",
            ],
            path: "ButtonHeist/Sources/HeistDoctorCore"
        ),
        .executableTarget(
            name: "HeistDoctorTool",
            dependencies: [
                "HeistDoctorCore",
                "TheScore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "ButtonHeist/Sources/HeistDoctorTool"
        ),
        // Swift implementation of TheInsideJob
        .target(
            name: "TheInsideJob",
            dependencies: [
                "ButtonHeistSupport",
                "ThePlans",
                "TheScore",
                .product(name: "AccessibilitySnapshotModel", package: "AccessibilitySnapshotBH"),
                .product(
                    name: "AccessibilitySnapshotParser",
                    package: "AccessibilitySnapshotBH",
                    condition: .when(platforms: [.iOS])
                ),
                .product(
                    name: "AccessibilitySnapshotCore",
                    package: "AccessibilitySnapshotBH",
                    condition: .when(platforms: [.iOS])
                ),
                .product(
                    name: "AccessibilitySnapshotPreviews",
                    package: "AccessibilitySnapshotBH",
                    condition: .when(platforms: [.iOS])
                ),
            ],
            path: "ButtonHeist/Sources/TheInsideJob"
        ),
        // Objective-C loader that triggers auto-start via +load
        .target(
            name: "ThePlant",
            dependencies: ["TheInsideJob"],
            path: "ButtonHeist/Sources/ThePlant",
            publicHeadersPath: "include"
        ),
        .target(
            name: "ButtonHeistTesting",
            dependencies: [
                "TheInsideJob",
                "ThePlans",
            ],
            path: "ButtonHeist/Sources/ButtonHeistTesting"
        ),
        .target(
            name: "ButtonHeist",
            dependencies: [
                "ButtonHeistSupport",
                "ThePlans",
                "TheScore",
                .product(name: "AccessibilitySnapshotModel", package: "AccessibilitySnapshotBH"),
            ],
            path: "ButtonHeist/Sources/TheButtonHeist"
        ),
        .target(
            name: "ButtonHeistTestSupport",
            dependencies: [
                "ThePlans",
                "TheScore",
                .product(name: "AccessibilitySnapshotModel", package: "AccessibilitySnapshotBH"),
            ],
            path: "ButtonHeist/Tests/TestSupport"
        ),
        .testTarget(
            name: "TheScoreTests",
            dependencies: [
                "ButtonHeistTestSupport",
                "ThePlans",
                "TheScore",
                .product(name: "AccessibilitySnapshotModel", package: "AccessibilitySnapshotBH"),
            ],
            path: "ButtonHeist/Tests/TheScoreTests"
        ),
        .testTarget(
            name: "ButtonHeistSupportTests",
            dependencies: ["ButtonHeistSupport"],
            path: "ButtonHeist/Tests/ButtonHeistSupportTests"
        ),
        .testTarget(
            name: "ThePlansTests",
            dependencies: ["ButtonHeistTestSupport", "ThePlans"],
            path: "ButtonHeist/Tests/ThePlansTests"
        ),
        .testTarget(
            name: "HeistDoctorCoreTests",
            dependencies: [
                "ButtonHeistTestSupport",
                "HeistDoctorCore",
                "TheScore",
            ],
            path: "ButtonHeist/Tests/HeistDoctorCoreTests"
        ),
        .testTarget(
            name: "ButtonHeistTests",
            dependencies: [
                "ButtonHeistTestSupport",
                "ButtonHeist",
                "ButtonHeistSupport",
                "ThePlans",
                "TheScore",
                .product(name: "AccessibilitySnapshotModel", package: "AccessibilitySnapshotBH"),
            ],
            path: "ButtonHeist/Tests/ButtonHeistTests"
        ),
        .testTarget(
            name: "TheInsideJobTests",
            dependencies: [
                "ButtonHeistSupport",
                "ButtonHeistTestSupport",
                "ButtonHeistTesting",
                "TheInsideJob",
                "ThePlans",
                "TheScore",
                .product(name: "AccessibilitySnapshotModel", package: "AccessibilitySnapshotBH"),
            ],
            path: "ButtonHeist/Tests/TheInsideJobTests"
        )
    ]
)
