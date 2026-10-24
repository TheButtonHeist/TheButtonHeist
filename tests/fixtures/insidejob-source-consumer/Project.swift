import ProjectDescription

let packagePath = Environment.buttonheistSourcePackagePath.getString(default: "../../..")

let project = Project(
    name: "SourceConsumer",
    packages: [.local(path: .relativeToManifest(packagePath))],
    targets: [
        .target(
            name: "SourceConsumer",
            destinations: .iOS,
            product: .app,
            bundleId: "com.buttonheist.source-consumer",
            deploymentTargets: .iOS("16.0"),
            infoPlist: .extendingDefault(with: ["UILaunchScreen": [:]]),
            sources: ["Sources/**"],
            dependencies: [.package(product: "TheInsideJob")],
            settings: .settings(base: [
                "SWIFT_VERSION": "6",
                "SWIFT_STRICT_CONCURRENCY": "complete",
                "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
            ])
        ),
    ]
)
