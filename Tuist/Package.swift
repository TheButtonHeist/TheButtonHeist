// swift-tools-version: 5.9
import PackageDescription

#if TUIST
import ProjectDescription

let insideJobDependencyProduct: ProjectDescription.Product = Environment.insidejobDistribution.getBoolean(default: false)
    ? .staticFramework : .framework

let accessibilitySnapshotProducts: [String: ProjectDescription.Product] = [
    "AccessibilitySnapshotCore": insideJobDependencyProduct,
    "AccessibilitySnapshotModel": insideJobDependencyProduct,
    "AccessibilitySnapshotParser": insideJobDependencyProduct,
    "AccessibilitySnapshotParser-ObjC": insideJobDependencyProduct,
    "AccessibilitySnapshotPreviews": insideJobDependencyProduct,
]

let packageSettings = PackageSettings(
    productTypes: accessibilitySnapshotProducts,
    targetSettings: accessibilitySnapshotProducts.mapValues { _ in
        Settings.settings(base: ["IPHONEOS_DEPLOYMENT_TARGET": "16.0"])
    }
)
#endif

let package = Package(
    name: "Dependencies",
    dependencies: [
        .package(url: "https://github.com/TheButtonHeist/AccessibilitySnapshotBH", exact: "0.25.1"),
    ]
)
