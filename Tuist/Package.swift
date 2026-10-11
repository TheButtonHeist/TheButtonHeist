// swift-tools-version: 5.9
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    productTypes: [
        "AccessibilitySnapshotCore": .framework,
        "AccessibilitySnapshotModel": .framework,
        "AccessibilitySnapshotParser": .framework,
        "AccessibilitySnapshotParser-ObjC": .framework,
        "AccessibilitySnapshotPreviews": .framework,
    ]
)
#endif

let package = Package(
    name: "Dependencies",
    dependencies: [
        .package(url: "https://github.com/TheButtonHeist/AccessibilitySnapshotBH", exact: "0.25.1"),
    ]
)
