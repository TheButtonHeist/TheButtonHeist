// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeistPlanTests",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(name: "ButtonHeist", path: ".."),
    ],
    targets: [
        .testTarget(
            name: "HeistPlanToolTests",
            dependencies: [
                .product(name: "ThePlans", package: "ButtonHeist"),
            ],
            path: "Tests/HeistPlanToolTests",
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
    ]
)
