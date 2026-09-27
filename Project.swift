import ProjectDescription

func frameworkScheme(name: String) -> Scheme {
    .scheme(
        name: name,
        buildAction: .buildAction(targets: [
            .target(name),
        ]),
        runAction: .runAction(executable: .target(name))
    )
}

func hostedTestTarget(
    name: String,
    bundleId: String,
    sources: SourceFilesList
) -> Target {
    .target(
        name: name,
        destinations: [.iPhone, .iPad],
        product: .unitTests,
        bundleId: bundleId,
        deploymentTargets: .iOS("16.0"),
        infoPlist: .default,
        sources: sources,
        dependencies: [
            .target(name: "ButtonHeistHostedTestSupport"),
            .target(name: "ButtonHeistSupport"),
            .target(name: "ButtonHeistTestSupport"),
            .target(name: "ButtonHeistTesting"),
            .target(name: "TheInsideJob"),
            .target(name: "ThePlans"),
            .target(name: "TheScore"),
            .external(name: "AccessibilitySnapshotModel"),
            .project(target: "BH Demo", path: "TestApp"),
        ],
        settings: .settings(base: [
            "BUNDLE_LOADER": "$(TEST_HOST)",
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
            "SWIFT_VERSION": "6",
            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/BHDemo.app/BHDemo",
        ])
    )
}

func unhostedInsideJobTestTarget(
    name: String,
    bundleId: String,
    sources: SourceFilesList
) -> Target {
    .target(
        name: name,
        destinations: [.iPhone, .iPad],
        product: .unitTests,
        bundleId: bundleId,
        deploymentTargets: .iOS("16.0"),
        infoPlist: .default,
        sources: sources,
        dependencies: [
            .target(name: "ButtonHeistSupport"),
            .target(name: "ButtonHeistTestSupport"),
            .target(name: "ButtonHeistTesting"),
            .target(name: "TheInsideJob"),
            .target(name: "ThePlans"),
            .target(name: "TheScore"),
            .external(name: "AccessibilitySnapshotModel"),
        ],
        settings: .settings(base: [
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
            "SWIFT_VERSION": "6",
        ])
    )
}

func testScheme(name: String) -> Scheme {
    .scheme(
        name: name,
        buildAction: .buildAction(targets: [
            .target(name),
        ]),
        testAction: .targets([
            .testableTarget(target: .target(name)),
        ])
    )
}

func hostedTestScheme(name: String) -> Scheme {
    .scheme(
        name: name,
        buildAction: .buildAction(targets: [
            .target(name),
        ]),
        testAction: .targets(
            [
                .testableTarget(target: .target(name)),
            ],
            arguments: .arguments(environmentVariables: [
                "BUTTONHEIST_TEST_ANIMATION_SPEED": "$(BUTTONHEIST_TEST_ANIMATION_SPEED)",
            ]),
            expandVariableFromTarget: .target(name)
        )
    )
}

struct HostedTestDescriptor {
    let name: String
    let bundleId: String
    let sources: SourceFilesList
    let runsInBehaviorSuite: Bool

    var target: Target {
        hostedTestTarget(name: name, bundleId: bundleId, sources: sources)
    }

    var scheme: Scheme {
        hostedTestScheme(name: name)
    }
}

let insideJobLogicTestTarget = unhostedInsideJobTestTarget(
    name: "TheInsideJobLogicTests",
    bundleId: "com.buttonheist.theinsidejob.logic.tests",
    sources: [
        "ButtonHeist/Tests/TheInsideJobTests/Logic/**",
        "ButtonHeist/Tests/TheInsideJobTests/Shared/LogicWindow/**",
        "ButtonHeist/Tests/TheInsideJobTests/Shared/Socket/**",
    ]
)

let hostedTestDescriptors = [
    HostedTestDescriptor(
        name: "TheInsideJobWindowTests",
        bundleId: "com.buttonheist.theinsidejob.window.tests",
        sources: [
            "ButtonHeist/Tests/TheInsideJobTests/Window/**",
            "ButtonHeist/Tests/TheInsideJobTests/Shared/LogicWindow/**",
            "ButtonHeist/Tests/TheInsideJobTests/Shared/Socket/**",
        ],
        runsInBehaviorSuite: false
    ),
    HostedTestDescriptor(
        name: "TheInsideJobIntegrationTests",
        bundleId: "com.buttonheist.theinsidejob.integration.tests",
        sources: [
            "ButtonHeist/Tests/TheInsideJobTests/Integration/**",
            "ButtonHeist/Tests/TheInsideJobTests/Shared/Socket/**",
        ],
        runsInBehaviorSuite: false
    ),
    HostedTestDescriptor(
        name: "TheInsideJobHostedBehaviorTests",
        bundleId: "com.buttonheist.theinsidejob.hosted-behavior.tests",
        sources: ["ButtonHeist/Tests/TheInsideJobTests/HostedBehavior/**"],
        runsInBehaviorSuite: true
    ),
    HostedTestDescriptor(
        name: "DogfoodFeatureFlowTests",
        bundleId: "com.buttonheist.dogfood.feature.tests",
        sources: ["ButtonHeist/Tests/DogfoodFeatureFlowTests/**"],
        runsInBehaviorSuite: true
    ),
    HostedTestDescriptor(
        name: "DogfoodRuntimeContractTests",
        bundleId: "com.buttonheist.dogfood.runtime.tests",
        sources: ["ButtonHeist/Tests/DogfoodRuntimeContractTests/**"],
        runsInBehaviorSuite: true
    ),
    HostedTestDescriptor(
        name: "AdversarialMutationTests",
        bundleId: "com.buttonheist.adversarial.mutation.tests",
        sources: ["ButtonHeist/Tests/AdversarialMutationTests/**"],
        runsInBehaviorSuite: true
    ),
    HostedTestDescriptor(
        name: "AdversarialNavigationTests",
        bundleId: "com.buttonheist.adversarial.navigation.tests",
        sources: ["ButtonHeist/Tests/AdversarialNavigationTests/**"],
        runsInBehaviorSuite: true
    ),
]

let hostedAggregateTestDescriptors = hostedTestDescriptors.filter {
    $0.name == "TheInsideJobWindowTests" || $0.runsInBehaviorSuite
}

let macFrameworkTestTargetNames = [
    "ButtonHeistSupportTests",
    "ThePlansTests",
    "TheScoreTests",
    "HeistDoctorCoreTests",
    "ButtonHeistTests",
]

let project = Project(
    name: "ButtonHeist",
    options: .options(
        automaticSchemesOptions: .disabled
    ),
    settings: .settings(base: [
        "SWIFT_VERSION": "6",
        "LastSwiftMigration": "2620",
        "OTHER_SWIFT_FLAGS": "$(inherited) -package-name ButtonHeist",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
    ]),
    targets: [
        // MARK: - Package-Internal Shared Support
        .target(
            name: "ButtonHeistSupport",
            destinations: [.iPhone, .iPad, .mac],
            product: .framework,
            bundleId: "com.buttonheist.support",
            deploymentTargets: .multiplatform(iOS: "16.0", macOS: "14.0"),
            infoPlist: .default,
            sources: ["ButtonHeist/Sources/ButtonHeistSupport/**"],
            dependencies: []
        ),

        // MARK: - Pure Heist Language
        .target(
            name: "ThePlans",
            destinations: [.iPhone, .iPad, .mac],
            product: .framework,
            bundleId: "com.buttonheist.theplans",
            deploymentTargets: .multiplatform(iOS: "16.0", macOS: "14.0"),
            infoPlist: .default,
            sources: ["ButtonHeist/Sources/ThePlans/**"],
            dependencies: [],
            settings: .settings(base: [
                "SWIFT_VERSION": "6",
                "LastSwiftMigration": "2620",
            ])
        ),

        // MARK: - Shared Protocol Types (cross-platform)
        .target(
            name: "TheScore",
            destinations: [.iPhone, .iPad, .mac],
            product: .framework,
            bundleId: "com.buttonheist.thescore",
            deploymentTargets: .multiplatform(iOS: "16.0", macOS: "14.0"),
            infoPlist: .default,
            sources: ["ButtonHeist/Sources/TheScore/**"],

            dependencies: [
                .target(name: "ThePlans"),
                .external(name: "AccessibilitySnapshotModel"),
            ],

            settings: .settings(base: [
                "SWIFT_VERSION": "6",
                "LastSwiftMigration": "2620",
            ])
        ),

        // MARK: - Result Diagnosis (macOS tooling core)
        .target(
            name: "HeistDoctorCore",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.buttonheist.heistdoctorcore",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["ButtonHeist/Sources/HeistDoctorCore/**"],
            dependencies: [
                .target(name: "ThePlans"),
                .target(name: "TheScore"),
            ]
        ),

        // MARK: - iOS Server Framework (embeds in iOS apps)
        // Includes ThePlant for automatic initialization via ObjC +load
        .target(
            name: "TheInsideJob",
            destinations: [.iPhone, .iPad],
            product: .framework,
            bundleId: "com.buttonheist.theinsidejob",
            deploymentTargets: .iOS("16.0"),
            infoPlist: .default,
            sources: [
                "ButtonHeist/Sources/TheInsideJob/**",
                "ButtonHeist/Sources/ThePlant/**",
            ],
            headers: .headers(
                public: ["ButtonHeist/Sources/ThePlant/include/**"]
            ),

            dependencies: [
                .target(name: "ButtonHeistSupport"),
                .target(name: "ThePlans"),
                .target(name: "TheScore"),
                .external(name: "AccessibilitySnapshotCore"),
                .external(name: "AccessibilitySnapshotModel"),
                .external(name: "AccessibilitySnapshotParser"),
                .external(name: "AccessibilitySnapshotPreviews"),
            ]
        ),

        // MARK: - Public iOS Test Facade
        .target(
            name: "ButtonHeistTesting",
            destinations: [.iPhone, .iPad],
            product: .framework,
            bundleId: "com.buttonheist.testing",
            deploymentTargets: .iOS("16.0"),
            infoPlist: .default,
            sources: ["ButtonHeist/Sources/ButtonHeistTesting/**"],

            dependencies: [
                .target(name: "TheInsideJob"),
                .target(name: "ThePlans"),
            ],
            settings: .settings(base: [
                "ENABLE_TESTING_SEARCH_PATHS": "YES",
            ])
        ),

        // MARK: - macOS Client Framework (single import for Mac consumers)
        .target(
            name: "ButtonHeist",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.buttonheist.buttonheist",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["ButtonHeist/Sources/TheButtonHeist/**"],

            dependencies: [
                .target(name: "ButtonHeistSupport"),
                .target(name: "ThePlans"),
                .target(name: "TheScore"),
                .external(name: "AccessibilitySnapshotModel"),
            ]
        ),

        // MARK: - Shared Test Support
        .target(
            name: "ButtonHeistTestSupport",
            destinations: [.iPhone, .iPad, .mac],
            product: .framework,
            bundleId: "com.buttonheist.testsupport",
            deploymentTargets: .multiplatform(iOS: "16.0", macOS: "14.0"),
            infoPlist: .default,
            sources: ["ButtonHeist/Tests/TestSupport/**"],
            dependencies: [
                .target(name: "ButtonHeistSupport"),
                .target(name: "ThePlans"),
                .target(name: "TheScore"),
                .external(name: "AccessibilitySnapshotModel"),
            ]
        ),

        // MARK: - iOS Hosted Test Support
        .target(
            name: "ButtonHeistHostedTestSupport",
            destinations: [.iPhone, .iPad],
            product: .framework,
            bundleId: "com.buttonheist.hostedtestsupport",
            deploymentTargets: .iOS("16.0"),
            infoPlist: .default,
            sources: ["ButtonHeist/Tests/HostedTestSupport/**"],
            dependencies: [
                .target(name: "ButtonHeistTesting"),
                .target(name: "TheInsideJob"),
                .target(name: "ThePlans"),
                .target(name: "TheScore"),
            ],
            settings: .settings(base: [
                "ENABLE_TESTING_SEARCH_PATHS": "YES",
                "SWIFT_STRICT_CONCURRENCY": "complete",
            ])
        ),

        // MARK: - ButtonHeistSupport Tests
        .target(
            name: "ButtonHeistSupportTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.buttonheist.support.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["ButtonHeist/Tests/ButtonHeistSupportTests/**"],
            dependencies: [
                .target(name: "ButtonHeistSupport"),
            ]
        ),

        // MARK: - HeistDoctorCore Tests
        .target(
            name: "HeistDoctorCoreTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.buttonheist.heistdoctorcore.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["ButtonHeist/Tests/HeistDoctorCoreTests/**"],
            dependencies: [
                .target(name: "ButtonHeistTestSupport"),
                .target(name: "HeistDoctorCore"),
                .target(name: "TheScore"),
            ]
        ),

        // MARK: - ThePlans Tests
        .target(
            name: "ThePlansTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.buttonheist.theplans.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["ButtonHeist/Tests/ThePlansTests/**"],
            dependencies: [
                .target(name: "ThePlans"),
                .target(name: "ButtonHeistTestSupport"),
            ]
        ),

        // MARK: - TheScore Tests
        .target(
            name: "TheScoreTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.buttonheist.thescore.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["ButtonHeist/Tests/TheScoreTests/**"],
            dependencies: [
                .target(name: "ButtonHeistTestSupport"),
                .target(name: "ThePlans"),
                .target(name: "TheScore"),
                .external(name: "AccessibilitySnapshotModel"),
            ]
        ),

        // MARK: - ButtonHeist Tests
        .target(
            name: "ButtonHeistTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.buttonheist.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["ButtonHeist/Tests/ButtonHeistTests/**"],
            dependencies: [
                .target(name: "ButtonHeistSupport"),
                .target(name: "ButtonHeistTestSupport"),
                .target(name: "ButtonHeist"),
                .target(name: "ThePlans"),
                .target(name: "TheScore"),
                .external(name: "AccessibilitySnapshotModel"),
            ]
        ),

    ] + [insideJobLogicTestTarget] + hostedTestDescriptors.map(\.target),
    schemes: [
        frameworkScheme(name: "ThePlans"),
        frameworkScheme(name: "TheScore"),
        frameworkScheme(name: "ButtonHeist"),
        frameworkScheme(name: "ButtonHeistSupport"),
        frameworkScheme(name: "ButtonHeistTesting"),
        frameworkScheme(name: "ButtonHeistTestSupport"),
        frameworkScheme(name: "HeistDoctorCore"),
        frameworkScheme(name: "TheInsideJob"),
        testScheme(name: "ButtonHeistSupportTests"),
        testScheme(name: "HeistDoctorCoreTests"),
        .scheme(
            name: "ThePlansTests",
            buildAction: .buildAction(targets: [
                .target("ThePlansTests"),
            ]),
            testAction: .targets([
                .testableTarget(target: .target("ThePlansTests")),
            ], arguments: .arguments(environmentVariables: [
                "HEIST_THEPLANS_BUILD_DIR": "$(BUILT_PRODUCTS_DIR)",
                "DEVELOPER_DIR": "$(DEVELOPER_DIR)",
            ]), expandVariableFromTarget: .target("ThePlansTests"))
        ),
        testScheme(name: "TheScoreTests"),
        testScheme(name: "ButtonHeistTests"),
        testScheme(name: "TheInsideJobLogicTests"),
        .scheme(
            name: "MacFrameworkTests",
            buildAction: .buildAction(
                targets: macFrameworkTestTargetNames.map { .target($0) }
            ),
            testAction: .targets(
                macFrameworkTestTargetNames.map {
                    .testableTarget(target: .target($0), parallelization: .enabled)
                },
                arguments: .arguments(environmentVariables: [
                    "HEIST_THEPLANS_BUILD_DIR": "$(BUILT_PRODUCTS_DIR)",
                    "DEVELOPER_DIR": "$(DEVELOPER_DIR)",
                ]),
                expandVariableFromTarget: .target("ThePlansTests")
            )
        ),
    ] + hostedTestDescriptors.map(\.scheme) + [
        .scheme(
            name: "HostedBehaviorTests",
            buildAction: .buildAction(
                targets: hostedAggregateTestDescriptors.map { .target($0.name) }
            ),
            testAction: .targets(
                hostedAggregateTestDescriptors.map {
                    .testableTarget(target: .target($0.name), parallelization: .disabled)
                },
                arguments: .arguments(environmentVariables: [
                    "BUTTONHEIST_TEST_ANIMATION_SPEED": "$(BUTTONHEIST_TEST_ANIMATION_SPEED)",
                ]),
                expandVariableFromTarget: .target("DogfoodFeatureFlowTests")
            )
        ),
    ]
)
