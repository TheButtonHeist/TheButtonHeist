import Foundation
import ProjectDescription

let bundlePath = "TheInsideJob"
let frameworksURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("\(bundlePath)/XCFrameworks")
let frameworks = try FileManager.default.contentsOfDirectory(atPath: frameworksURL.path)
    .filter { $0.hasSuffix(".xcframework") }
    .sorted()

let project = Project(
    name: "BinaryConsumer",
    targets: [
        .target(
            name: "BinaryConsumer",
            destinations: .iOS,
            product: .app,
            bundleId: "com.buttonheist.binary-consumer",
            deploymentTargets: .iOS("16.0"),
            infoPlist: .extendingDefault(with: ["UILaunchScreen": [:]]),
            sources: ["Sources/**"],
            scripts: [
                .post(
                    path: .relativeToManifest("\(bundlePath)/Scripts/integrate-insidejob.sh"),
                    name: "Integrate TheInsideJob",
                    basedOnDependencyAnalysis: false
                ),
            ],
            dependencies: frameworks.map {
                .xcframework(path: .relativeToManifest("\(bundlePath)/XCFrameworks/\($0)"), status: .optional)
            },
            settings: .settings(base: [
                "SWIFT_VERSION": "6",
                "SWIFT_STRICT_CONCURRENCY": "complete",
                "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            ])
        ),
    ]
)
