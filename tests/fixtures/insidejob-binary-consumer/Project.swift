import ProjectDescription

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
                    path: .relativeToManifest("TheInsideJob.xcframework/Scripts/integrate-insidejob.sh"),
                    name: "Integrate TheInsideJob",
                    basedOnDependencyAnalysis: false
                ),
            ],
            dependencies: [
                .xcframework(path: "TheInsideJob.xcframework", status: .optional),
            ],
            settings: .settings(base: [
                "SWIFT_VERSION": "6",
                "SWIFT_STRICT_CONCURRENCY": "complete",
                "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            ])
        ),
    ]
)
