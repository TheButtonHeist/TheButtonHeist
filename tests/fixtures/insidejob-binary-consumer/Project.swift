import ProjectDescription

let configurations: [Configuration] = [
    .debug(name: "Debug", settings: [
        "INCLUDED_SOURCE_FILE_NAMES": "$(inherited) TheInsideJob.*framework",
    ]),
    .release(name: "Release"),
    .release(name: "Staging"),
]

let project = Project(
    name: "BinaryConsumer",
    settings: .settings(configurations: configurations),
    targets: [
        .target(
            name: "BinaryConsumer",
            destinations: .iOS,
            product: .app,
            bundleId: "com.buttonheist.binary-consumer",
            deploymentTargets: .iOS("16.0"),
            infoPlist: .extendingDefault(with: ["UILaunchScreen": [:]]),
            sources: ["Sources/**"],
            dependencies: [
                .xcframework(path: "TheInsideJob.xcframework"),
            ],
            settings: .settings(base: [
                "SWIFT_VERSION": "6",
                "SWIFT_STRICT_CONCURRENCY": "complete",
                "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
                "EXCLUDED_SOURCE_FILE_NAMES": "$(inherited) TheInsideJob.*framework",
            ], configurations: configurations)
        ),
    ]
)
