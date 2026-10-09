#if canImport(UIKit)
import XCTest
import TheScore
@testable import TheInsideJob

final class StartupConfigurationTests: XCTestCase {

    func testAutoStartIsDisabledUnderXCTestEnvironment() {
        XCTAssertTrue(isRunningUnderXCTest(environment: environment([
            .configurationFilePath: "/tmp/session.xctestconfiguration"
        ])))
        XCTAssertTrue(isRunningUnderXCTest(environment: environment([
            .sessionIdentifier: "session"
        ])))
        XCTAssertFalse(isRunningUnderXCTest(environment: [:]))
    }

    func testEnvironmentOverridesInfoPlist() {
        let configuration = StartupConfiguration.resolve(
            env: environment([
                .disableAutoStart: "false",
                .token: "env-token",
                .instanceId: "env-id",
                .port: "4242",
                .scope: "network",
                .sessionTimeout: "45"
            ]),
            infoPlist: makeInfoPlist([
                .disableAutoStart: true,
                .token: "plist-token",
                .instanceId: "plist-id",
                .port: 5151,
                .scope: "simulator,usb",
                .sessionTimeout: 120.0
            ])
        )

        let expected = StartupConfiguration(
            disableAutoStart: ResolvedStartupValue(value: false, source: .environment),
            token: ResolvedStartupValue(value: "env-token", source: .environment),
            instanceId: ResolvedStartupValue(value: "env-id", source: .environment),
            preferredPort: ResolvedStartupValue(value: 4242, source: .environment),
            allowedScopes: ResolvedStartupValue(value: [.network], source: .environment),
            sessionTimeout: ResolvedStartupValue(value: 45.0, source: .environment),
            warnings: []
        )
        XCTAssertEqual(configuration, expected)
    }

    func testInfoPlistUsedWhenEnvironmentMissing() {
        let configuration = StartupConfiguration.resolve(
            env: .empty,
            infoPlist: makeInfoPlist([
                .disableAutoStart: true,
                .token: "plist-token",
                .instanceId: "plist-id",
                .port: 5151,
                .scope: ["simulator", "usb"],
                .sessionTimeout: 120.0
            ])
        )

        let expected = StartupConfiguration(
            disableAutoStart: ResolvedStartupValue(value: true, source: .infoPlist),
            token: ResolvedStartupValue(value: "plist-token", source: .infoPlist),
            instanceId: ResolvedStartupValue(value: "plist-id", source: .infoPlist),
            preferredPort: ResolvedStartupValue(value: 5151, source: .infoPlist),
            allowedScopes: ResolvedStartupValue(value: [.simulator, .usb], source: .infoPlist),
            sessionTimeout: ResolvedStartupValue(value: 120.0, source: .infoPlist),
            warnings: []
        )
        XCTAssertEqual(configuration, expected)
    }

    func testInfoPlistCompatibilityShapesFallBackWithWarnings() {
        let configuration = StartupConfiguration.resolve(
            env: .empty,
            infoPlist: makeInfoPlist([
                .disableAutoStart: "yes",
                .fingerprintsEnabled: "no",
                .port: "5151",
                .scope: "simulator,network",
                .sessionTimeout: " 120.5 "
            ])
        )

        XCTAssertEqual(configuration.disableAutoStart, ResolvedStartupValue(value: false, source: .defaultValue))
        XCTAssertEqual(configuration.fingerprintsEnabled, ResolvedStartupValue(value: true, source: .defaultValue))
        XCTAssertEqual(configuration.preferredPort, ResolvedStartupValue(value: 0, source: .defaultValue))
        XCTAssertEqual(configuration.allowedScopes, ResolvedStartupValue(value: ConnectionScope.default, source: .defaultValue))
        XCTAssertEqual(configuration.sessionTimeout, ResolvedStartupValue(value: 30, source: .defaultValue))
        XCTAssertEqual(configuration.warnings, [
            .invalidValueIgnored(key: StartupInfoPlistKey.disableAutoStart.rawValue, source: .infoPlist, value: "yes"),
            .invalidValueIgnored(key: StartupInfoPlistKey.fingerprintsEnabled.rawValue, source: .infoPlist, value: "no"),
            .invalidValueIgnored(key: StartupInfoPlistKey.port.rawValue, source: .infoPlist, value: "5151"),
            .invalidValueIgnored(key: StartupInfoPlistKey.scope.rawValue, source: .infoPlist, value: "simulator,network"),
            .invalidValueIgnored(key: StartupInfoPlistKey.sessionTimeout.rawValue, source: .infoPlist, value: " 120.5 ")
        ])
    }

    func testMalformedInfoPlistValuesFallBackWithWarnings() {
        let configuration = StartupConfiguration.resolve(
            env: .empty,
            infoPlist: makeInfoPlist([
                .disableAutoStart: ["true"],
                .fingerprintsEnabled: ["false"],
                .token: 42,
                .port: 12.5,
                .scope: ["simulator", "bogus"],
                .sessionTimeout: "soon"
            ])
        )

        XCTAssertEqual(configuration.disableAutoStart, ResolvedStartupValue(value: false, source: .defaultValue))
        XCTAssertEqual(configuration.fingerprintsEnabled, ResolvedStartupValue(value: true, source: .defaultValue))
        XCTAssertEqual(configuration.token, ResolvedStartupValue(value: nil, source: .generated))
        XCTAssertEqual(configuration.preferredPort, ResolvedStartupValue(value: 0, source: .defaultValue))
        XCTAssertEqual(configuration.allowedScopes, ResolvedStartupValue(value: ConnectionScope.default, source: .defaultValue))
        XCTAssertEqual(configuration.sessionTimeout, ResolvedStartupValue(value: 30.0, source: .defaultValue))
        XCTAssertEqual(configuration.warnings, [
            .invalidValueIgnored(key: StartupInfoPlistKey.disableAutoStart.rawValue, source: .infoPlist, value: "[\"true\"]"),
            .invalidValueIgnored(key: StartupInfoPlistKey.fingerprintsEnabled.rawValue, source: .infoPlist, value: "[\"false\"]"),
            .invalidValueIgnored(key: StartupInfoPlistKey.port.rawValue, source: .infoPlist, value: "12.5"),
            .invalidValueIgnored(key: StartupInfoPlistKey.scope.rawValue, source: .infoPlist, value: "[\"simulator\", \"bogus\"]"),
            .invalidValueIgnored(key: StartupInfoPlistKey.sessionTimeout.rawValue, source: .infoPlist, value: "soon")
        ])
    }

    func testInfoPlistStringArraysOnlyResolveForScope() {
        let configuration = StartupConfiguration.resolve(
            env: .empty,
            infoPlist: makeInfoPlist([
                .token: ["token"],
                .instanceId: ["instance-id"],
                .scope: ["simulator", "usb"]
            ])
        )

        let expected = StartupConfiguration(
            disableAutoStart: ResolvedStartupValue(value: false, source: .defaultValue),
            token: ResolvedStartupValue(value: nil, source: .generated),
            instanceId: ResolvedStartupValue(value: nil, source: .generated),
            preferredPort: ResolvedStartupValue(value: 0, source: .defaultValue),
            allowedScopes: ResolvedStartupValue(value: [.simulator, .usb], source: .infoPlist),
            sessionTimeout: ResolvedStartupValue(value: 30.0, source: .defaultValue),
            warnings: []
        )
        XCTAssertEqual(configuration, expected)
    }

    func testFingerprintsConfigResolvesPositiveEnableKey() {
        XCTAssertEqual(
            StartupConfiguration.resolve(
                env: environment([.fingerprintsEnabled: "false"]),
                infoPlist: makeInfoPlist([.fingerprintsEnabled: true])
            ).fingerprintsEnabled,
            ResolvedStartupValue(value: false, source: .environment)
        )
        XCTAssertEqual(
            StartupConfiguration.resolve(
                env: environment([.fingerprintsEnabled: "true"]),
                infoPlist: makeInfoPlist([.fingerprintsEnabled: false])
            ).fingerprintsEnabled,
            ResolvedStartupValue(value: true, source: .environment)
        )
        XCTAssertEqual(
            StartupConfiguration.resolve(
                env: .empty,
                infoPlist: makeInfoPlist([.fingerprintsEnabled: false])
            ).fingerprintsEnabled,
            ResolvedStartupValue(value: false, source: .infoPlist)
        )
    }

    func testFailureEvidencePolicyResolvesAtStartupBoundary() {
        XCTAssertEqual(
            StartupConfiguration.resolve(
                env: environment([.failureEvidence: "hierarchy"]),
                infoPlist: makeInfoPlist([.failureEvidence: "accessibilitySnapshot"])
            ).failureEvidencePolicy,
            ResolvedStartupValue(value: .hierarchy, source: .environment)
        )
        XCTAssertEqual(
            StartupConfiguration.resolve(
                env: .empty,
                infoPlist: makeInfoPlist([.failureEvidence: "accessibilitySnapshot"])
            ).failureEvidencePolicy,
            ResolvedStartupValue(value: .accessibilitySnapshot, source: .infoPlist)
        )
        XCTAssertEqual(
            StartupConfiguration.resolve(env: .empty, infoPlist: makeInfoPlist([:])).failureEvidencePolicy,
            ResolvedStartupValue(value: .screenshot, source: .defaultValue)
        )
    }

    func testEmptyTokenAndInstanceIdAreIgnoredWithWarnings() {
        let configuration = StartupConfiguration.resolve(
            env: environment([
                .token: "",
                .instanceId: "   "
            ]),
            infoPlist: makeInfoPlist([
                .token: "plist-token",
                .instanceId: "plist-id"
            ])
        )

        let expected = StartupConfiguration(
            disableAutoStart: ResolvedStartupValue(value: false, source: .defaultValue),
            token: ResolvedStartupValue(value: "plist-token", source: .infoPlist),
            instanceId: ResolvedStartupValue(value: "plist-id", source: .infoPlist),
            preferredPort: ResolvedStartupValue(value: 0, source: .defaultValue),
            allowedScopes: ResolvedStartupValue(value: ConnectionScope.default, source: .defaultValue),
            sessionTimeout: ResolvedStartupValue(value: 30.0, source: .defaultValue),
            warnings: [
                .emptyValueIgnored(key: StartupEnvironmentKey.token.rawValue, source: .environment),
                .emptyValueIgnored(key: StartupEnvironmentKey.instanceId.rawValue, source: .environment)
            ]
        )
        XCTAssertEqual(configuration, expected)
    }

    func testInvalidValuesFallBackAndNumericValuesClamp() {
        let configuration = StartupConfiguration.resolve(
            env: environment([
                .port: "99999",
                .scope: "bogus",
                .sessionTimeout: "0"
            ]),
            infoPlist: makeInfoPlist([
                .port: 5151,
                .scope: ["usb"]
            ])
        )

        let expected = StartupConfiguration(
            disableAutoStart: ResolvedStartupValue(value: false, source: .defaultValue),
            token: ResolvedStartupValue(value: nil, source: .generated),
            instanceId: ResolvedStartupValue(value: nil, source: .generated),
            preferredPort: ResolvedStartupValue(value: 5151, source: .infoPlist),
            allowedScopes: ResolvedStartupValue(value: [.usb], source: .infoPlist),
            sessionTimeout: ResolvedStartupValue(value: 1.0, source: .environment),
            warnings: [
                .invalidValueIgnored(key: StartupEnvironmentKey.port.rawValue, source: .environment, value: "99999"),
                .invalidValueIgnored(key: StartupEnvironmentKey.scope.rawValue, source: .environment, value: "bogus")
            ]
        )
        XCTAssertEqual(configuration, expected)
    }

    func testRuntimeConfigurationAppliesAPIOverridesToResolvedStartupSnapshot() throws {
        let startupConfiguration = StartupConfiguration(
            disableAutoStart: ResolvedStartupValue(value: false, source: .defaultValue),
            token: ResolvedStartupValue(value: "startup-token", source: .environment),
            instanceId: ResolvedStartupValue(value: "startup-id", source: .environment),
            preferredPort: ResolvedStartupValue(value: 5151, source: .environment),
            allowedScopes: ResolvedStartupValue(value: [.simulator], source: .environment),
            sessionTimeout: ResolvedStartupValue(value: 12.0, source: .environment),
            warnings: []
        )

        let runtimeConfiguration = try InsideJobRuntimeConfiguration.resolve(
            startupConfiguration: startupConfiguration,
            token: "api-token",
            instanceId: "api-id",
            allowedScopes: [.network],
            port: 4242,
            addressFamily: .ipv4,
            fingerprintsEnabled: false
        )

        XCTAssertEqual(
            runtimeConfiguration.token,
            ResolvedStartupValue(value: "api-token", source: .api)
        )
        XCTAssertEqual(
            runtimeConfiguration.sessionIdentity.effectiveInstanceId,
            ResolvedStartupValue(value: "api-id", source: .api)
        )
        XCTAssertEqual(
            runtimeConfiguration.preferredPort,
            ResolvedStartupValue(value: 4242, source: .api)
        )
        XCTAssertEqual(
            runtimeConfiguration.allowedScopes,
            ResolvedStartupValue(value: [.network], source: .api)
        )
        XCTAssertEqual(runtimeConfiguration.addressFamily, .ipv4)
        XCTAssertEqual(runtimeConfiguration.sessionReleaseTimeout, startupConfiguration.sessionTimeout)
        XCTAssertEqual(
            runtimeConfiguration.fingerprintsEnabled,
            ResolvedStartupValue(value: false, source: .api)
        )
        XCTAssertEqual(runtimeConfiguration.failureEvidencePolicy, startupConfiguration.failureEvidencePolicy)
    }

    func testRuntimeConfigurationUsesExplicitStartupSnapshotForSessionDefaults() throws {
        let startupConfiguration = StartupConfiguration(
            disableAutoStart: ResolvedStartupValue(value: false, source: .defaultValue),
            token: ResolvedStartupValue(value: "startup-token", source: .environment),
            instanceId: ResolvedStartupValue(value: "startup-id", source: .environment),
            preferredPort: ResolvedStartupValue(value: 5151, source: .environment),
            allowedScopes: ResolvedStartupValue(value: [.usb], source: .infoPlist),
            sessionTimeout: ResolvedStartupValue(value: 24.0, source: .infoPlist),
            warnings: []
        )

        let runtimeConfiguration = try InsideJobRuntimeConfiguration.resolve(
            startupConfiguration: startupConfiguration,
            token: nil,
            instanceId: nil,
            allowedScopes: nil,
            port: 0
        )

        XCTAssertEqual(
            runtimeConfiguration.token,
            ResolvedStartupValue(value: "startup-token", source: .environment)
        )
        XCTAssertEqual(runtimeConfiguration.sessionIdentity.effectiveInstanceId.source, .generated)
        XCTAssertEqual(
            runtimeConfiguration.preferredPort,
            ResolvedStartupValue(value: 0, source: .defaultValue)
        )
        XCTAssertEqual(
            runtimeConfiguration.allowedScopes,
            ResolvedStartupValue(value: [.usb], source: .infoPlist)
        )
        XCTAssertEqual(runtimeConfiguration.addressFamily, .dualStack)
        XCTAssertEqual(runtimeConfiguration.sessionReleaseTimeout, startupConfiguration.sessionTimeout)
    }

    func testRuntimeConfigurationRejectsBlankExplicitValues() {
        let startupConfiguration = StartupConfiguration.resolve(env: .empty, infoPlist: makeInfoPlist([:]))

        XCTAssertThrowsError(
            try InsideJobRuntimeConfiguration.resolve(
                startupConfiguration: startupConfiguration,
                token: " ",
                instanceId: nil,
                allowedScopes: nil,
                port: 0
            )
        ) { error in
            XCTAssertEqual(error as? InsideJobConfigurationError, .blankToken)
        }

        XCTAssertThrowsError(
            try InsideJobRuntimeConfiguration.resolve(
                startupConfiguration: startupConfiguration,
                token: nil,
                instanceId: "\t",
                allowedScopes: nil,
                port: 0
            )
        ) { error in
            XCTAssertEqual(error as? InsideJobConfigurationError, .blankInstanceID)
        }
    }

    @MainActor
    func testSharedConfigurationStateRejectsRepeatedAndLiveConfiguration() throws {
        let startupConfiguration = StartupConfiguration.resolve(env: .empty, infoPlist: makeInfoPlist([:]))
        let runtimeConfiguration = InsideJobRuntimeConfiguration.resolve(
            startupConfiguration: startupConfiguration
        )
        var configuredState = TheInsideJob.SharedState.unconfigured

        try configuredState.configure { runtimeConfiguration }
        XCTAssertThrowsError(try configuredState.configure { runtimeConfiguration }) { error in
            XCTAssertEqual(error as? InsideJobConfigurationError, .alreadyConfigured)
        }

        let job = TheInsideJob(runtimeConfiguration: runtimeConfiguration)
        var liveState = TheInsideJob.SharedState.live(job)
        XCTAssertThrowsError(try liveState.configure { runtimeConfiguration }) { error in
            XCTAssertEqual(error as? InsideJobConfigurationError, .alreadyLive)
        }
    }

    func testRuntimeConfigurationGeneratesUUIDSessionToken() {
        let configuration = StartupConfiguration.resolve(env: .empty, infoPlist: makeInfoPlist([:]))
        let runtimeConfiguration = InsideJobRuntimeConfiguration.resolve(startupConfiguration: configuration)

        XCTAssertEqual(runtimeConfiguration.token.source, .generated)
        XCTAssertNotNil(UUID(uuidString: runtimeConfiguration.token.value.description))
    }

    func testRuntimeKnobsUseDefaults() {
        let knobs = ButtonHeistRuntimeKnobs.resolve(environment: .empty)

        XCTAssertEqual(knobs.tripwirePulseFramesPerSecond, 10)
        XCTAssertEqual(knobs.maxScrollsPerContainer, 200)
        XCTAssertEqual(knobs.maxScrollsPerDiscovery, 200)
        XCTAssertEqual(knobs.visibleElementBudget, 300)
        XCTAssertEqual(knobs.totalNodeBudget, 5_000)
    }

    func testRuntimeKnobsReadEnvironmentFromOneResolver() {
        let knobs = ButtonHeistRuntimeKnobs.resolve(environment: RuntimeKnobEnvironment(values: [
            .tripwirePulseFramesPerSecond: "60",
            .maxScrollsPerContainer: "25",
            .maxScrollsPerDiscovery: "30",
            .scrollSubtreeElementBudget: "75",
            .totalNodeBudget: "4000"
        ]))

        XCTAssertEqual(knobs.tripwirePulseFramesPerSecond, 60)
        XCTAssertEqual(knobs.maxScrollsPerContainer, 25)
        XCTAssertEqual(knobs.maxScrollsPerDiscovery, 30)
        XCTAssertEqual(knobs.visibleElementBudget, 75)
        XCTAssertEqual(knobs.totalNodeBudget, 4_000)
    }

    func testRuntimeKnobsReadTestRunnerPrefixedEnvironmentAndClamp() {
        let knobs = ButtonHeistRuntimeKnobs.resolve(environment: RuntimeKnobEnvironment(values: [
            .tripwirePulseFramesPerSecond.testRunnerPrefixed: "0",
            .maxScrollsPerContainer.testRunnerPrefixed: "9999",
            .maxScrollsPerDiscovery.testRunnerPrefixed: "9999",
            .scrollSubtreeElementBudget.testRunnerPrefixed: "9999",
            .totalNodeBudget.testRunnerPrefixed: "9999"
        ]))

        XCTAssertEqual(knobs.tripwirePulseFramesPerSecond, 1)
        XCTAssertEqual(knobs.maxScrollsPerContainer, 2_000)
        XCTAssertEqual(knobs.maxScrollsPerDiscovery, 2_000)
        XCTAssertEqual(knobs.visibleElementBudget, 1_000)
        XCTAssertEqual(knobs.totalNodeBudget, 5_000)
    }
}

private enum InfoPlistFixtureValue {
    case bool(Bool)
    case string(String)
    case integer(Int)
    case double(Double)
    case stringArray([String])

    var propertyListObject: NSObject {
        switch self {
        case .bool(let value):
            return NSNumber(value: value)
        case .string(let value):
            return NSString(string: value)
        case .integer(let value):
            return NSNumber(value: value)
        case .double(let value):
            return NSNumber(value: value)
        case .stringArray(let value):
            return NSArray(array: value)
        }
    }
}

extension InfoPlistFixtureValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension InfoPlistFixtureValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension InfoPlistFixtureValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self = .integer(value)
    }
}

extension InfoPlistFixtureValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension InfoPlistFixtureValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: String...) {
        self = .stringArray(elements)
    }
}

private func environment(_ values: [StartupEnvironmentKey: String]) -> StartupEnvironment {
    StartupEnvironment(values: values)
}

private func environment(_ values: [XCTestEnvironmentKey: String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
}

private func makeInfoPlist(
    _ values: [StartupInfoPlistKey: InfoPlistFixtureValue],
    file: StaticString = #filePath,
    line: UInt = #line
) -> StartupInfoPlist {
    do {
        let propertyList = NSDictionary(
            dictionary: Dictionary(
                uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value.propertyListObject) }
            )
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StartupConfigurationTests-\(UUID().uuidString)")
            .appendingPathExtension("plist")
        try data.write(to: url)
        return StartupInfoPlist(contentsOf: url)
    } catch {
        XCTFail("Failed to write Info.plist fixture: \(error)", file: file, line: line)
        return StartupInfoPlist(contentsOf: URL(fileURLWithPath: "/dev/null"))
    }
}
#endif
