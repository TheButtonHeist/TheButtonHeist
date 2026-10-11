#if canImport(UIKit)
import XCTest
import TheScore
@testable import TheInsideJob

final class InsideJobRuntimeConfigurationTests: XCTestCase {

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
        let configuration = InsideJobRuntimeConfiguration.resolve(
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

        XCTAssertEqual(configuration.disableAutoStart, ResolvedConfigurationValue(value: false, source: .environment))
        XCTAssertEqual(configuration.token, ResolvedConfigurationValue(value: "env-token", source: .environment))
        XCTAssertEqual(
            configuration.sessionIdentity.effectiveInstanceId,
            ResolvedConfigurationValue(value: "env-id", source: .environment)
        )
        XCTAssertEqual(configuration.preferredPort, ResolvedConfigurationValue(value: 4242, source: .environment))
        XCTAssertEqual(configuration.allowedScopes, ResolvedConfigurationValue(value: [.network], source: .environment))
        XCTAssertEqual(configuration.sessionReleaseTimeout, ResolvedConfigurationValue(value: 45.0, source: .environment))
        XCTAssertEqual(configuration.warnings, [])
    }

    func testInfoPlistUsedWhenEnvironmentMissing() {
        let configuration = InsideJobRuntimeConfiguration.resolve(
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

        XCTAssertEqual(configuration.disableAutoStart, ResolvedConfigurationValue(value: true, source: .infoPlist))
        XCTAssertEqual(configuration.token, ResolvedConfigurationValue(value: "plist-token", source: .infoPlist))
        XCTAssertEqual(
            configuration.sessionIdentity.effectiveInstanceId,
            ResolvedConfigurationValue(value: "plist-id", source: .infoPlist)
        )
        XCTAssertEqual(configuration.preferredPort, ResolvedConfigurationValue(value: 5151, source: .infoPlist))
        XCTAssertEqual(configuration.allowedScopes, ResolvedConfigurationValue(value: [.simulator, .usb], source: .infoPlist))
        XCTAssertEqual(configuration.sessionReleaseTimeout, ResolvedConfigurationValue(value: 120.0, source: .infoPlist))
        XCTAssertEqual(configuration.warnings, [])
    }

    func testInfoPlistCompatibilityShapesFallBackWithWarnings() {
        let configuration = InsideJobRuntimeConfiguration.resolve(
            env: .empty,
            infoPlist: makeInfoPlist([
                .disableAutoStart: "yes",
                .fingerprintsEnabled: "no",
                .port: "5151",
                .scope: "simulator,network",
                .sessionTimeout: " 120.5 "
            ])
        )

        XCTAssertEqual(configuration.disableAutoStart, ResolvedConfigurationValue(value: false, source: .defaultValue))
        XCTAssertEqual(configuration.fingerprintsEnabled, ResolvedConfigurationValue(value: true, source: .defaultValue))
        XCTAssertEqual(configuration.preferredPort, ResolvedConfigurationValue(value: 0, source: .defaultValue))
        XCTAssertEqual(configuration.allowedScopes, ResolvedConfigurationValue(value: ConnectionScope.default, source: .defaultValue))
        XCTAssertEqual(configuration.sessionReleaseTimeout, ResolvedConfigurationValue(value: 30, source: .defaultValue))
        XCTAssertEqual(configuration.warnings, [
            .invalidValueIgnored(key: StartupInfoPlistKey.disableAutoStart.rawValue, source: .infoPlist, value: "yes"),
            .invalidValueIgnored(key: StartupInfoPlistKey.fingerprintsEnabled.rawValue, source: .infoPlist, value: "no"),
            .invalidValueIgnored(key: StartupInfoPlistKey.port.rawValue, source: .infoPlist, value: "5151"),
            .invalidValueIgnored(key: StartupInfoPlistKey.scope.rawValue, source: .infoPlist, value: "simulator,network"),
            .invalidValueIgnored(key: StartupInfoPlistKey.sessionTimeout.rawValue, source: .infoPlist, value: " 120.5 ")
        ])
    }

    func testMalformedInfoPlistValuesFallBackWithWarnings() {
        let configuration = InsideJobRuntimeConfiguration.resolve(
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

        XCTAssertEqual(configuration.disableAutoStart, ResolvedConfigurationValue(value: false, source: .defaultValue))
        XCTAssertEqual(configuration.fingerprintsEnabled, ResolvedConfigurationValue(value: true, source: .defaultValue))
        XCTAssertEqual(configuration.token.source, .generated)
        XCTAssertNotNil(UUID(uuidString: configuration.token.value.description))
        XCTAssertEqual(configuration.preferredPort, ResolvedConfigurationValue(value: 0, source: .defaultValue))
        XCTAssertEqual(configuration.allowedScopes, ResolvedConfigurationValue(value: ConnectionScope.default, source: .defaultValue))
        XCTAssertEqual(configuration.sessionReleaseTimeout, ResolvedConfigurationValue(value: 30.0, source: .defaultValue))
        XCTAssertEqual(configuration.warnings, [
            .invalidValueIgnored(key: StartupInfoPlistKey.disableAutoStart.rawValue, source: .infoPlist, value: "[\"true\"]"),
            .invalidValueIgnored(key: StartupInfoPlistKey.fingerprintsEnabled.rawValue, source: .infoPlist, value: "[\"false\"]"),
            .invalidValueIgnored(key: StartupInfoPlistKey.port.rawValue, source: .infoPlist, value: "12.5"),
            .invalidValueIgnored(key: StartupInfoPlistKey.scope.rawValue, source: .infoPlist, value: "[\"simulator\", \"bogus\"]"),
            .invalidValueIgnored(key: StartupInfoPlistKey.sessionTimeout.rawValue, source: .infoPlist, value: "soon")
        ])
    }

    func testInfoPlistStringArraysOnlyResolveForScope() {
        let configuration = InsideJobRuntimeConfiguration.resolve(
            env: .empty,
            infoPlist: makeInfoPlist([
                .token: ["token"],
                .instanceId: ["instance-id"],
                .scope: ["simulator", "usb"]
            ])
        )

        XCTAssertEqual(configuration.disableAutoStart, ResolvedConfigurationValue(value: false, source: .defaultValue))
        XCTAssertEqual(configuration.token.source, .generated)
        XCTAssertEqual(configuration.sessionIdentity.effectiveInstanceId.source, .generated)
        XCTAssertEqual(configuration.preferredPort, ResolvedConfigurationValue(value: 0, source: .defaultValue))
        XCTAssertEqual(configuration.allowedScopes, ResolvedConfigurationValue(value: [.simulator, .usb], source: .infoPlist))
        XCTAssertEqual(configuration.sessionReleaseTimeout, ResolvedConfigurationValue(value: 30.0, source: .defaultValue))
        XCTAssertEqual(configuration.warnings, [])
    }

    func testFingerprintsConfigResolvesPositiveEnableKey() {
        XCTAssertEqual(
            InsideJobRuntimeConfiguration.resolve(
                env: environment([.fingerprintsEnabled: "false"]),
                infoPlist: makeInfoPlist([.fingerprintsEnabled: true])
            ).fingerprintsEnabled,
            ResolvedConfigurationValue(value: false, source: .environment)
        )
        XCTAssertEqual(
            InsideJobRuntimeConfiguration.resolve(
                env: environment([.fingerprintsEnabled: "true"]),
                infoPlist: makeInfoPlist([.fingerprintsEnabled: false])
            ).fingerprintsEnabled,
            ResolvedConfigurationValue(value: true, source: .environment)
        )
        XCTAssertEqual(
            InsideJobRuntimeConfiguration.resolve(
                env: .empty,
                infoPlist: makeInfoPlist([.fingerprintsEnabled: false])
            ).fingerprintsEnabled,
            ResolvedConfigurationValue(value: false, source: .infoPlist)
        )
    }

    func testFailureEvidencePolicyResolvesAtStartupBoundary() {
        XCTAssertEqual(
            InsideJobRuntimeConfiguration.resolve(
                env: environment([.failureEvidence: "hierarchy"]),
                infoPlist: makeInfoPlist([.failureEvidence: "accessibilitySnapshot"])
            ).failureEvidencePolicy,
            ResolvedConfigurationValue(value: .hierarchy, source: .environment)
        )
        XCTAssertEqual(
            InsideJobRuntimeConfiguration.resolve(
                env: .empty,
                infoPlist: makeInfoPlist([.failureEvidence: "accessibilitySnapshot"])
            ).failureEvidencePolicy,
            ResolvedConfigurationValue(value: .accessibilitySnapshot, source: .infoPlist)
        )
        XCTAssertEqual(
            InsideJobRuntimeConfiguration.resolve(env: .empty, infoPlist: makeInfoPlist([:])).failureEvidencePolicy,
            ResolvedConfigurationValue(value: .screenshot, source: .defaultValue)
        )
    }

    func testEmptyTokenAndInstanceIdAreIgnoredWithWarnings() {
        let configuration = InsideJobRuntimeConfiguration.resolve(
            env: environment([
                .token: "",
                .instanceId: "   "
            ]),
            infoPlist: makeInfoPlist([
                .token: "plist-token",
                .instanceId: "plist-id"
            ])
        )

        XCTAssertEqual(configuration.token, ResolvedConfigurationValue(value: "plist-token", source: .infoPlist))
        XCTAssertEqual(
            configuration.sessionIdentity.effectiveInstanceId,
            ResolvedConfigurationValue(value: "plist-id", source: .infoPlist)
        )
        XCTAssertEqual(configuration.warnings, [
            .emptyValueIgnored(key: StartupEnvironmentKey.token.rawValue, source: .environment),
            .emptyValueIgnored(key: StartupEnvironmentKey.instanceId.rawValue, source: .environment)
        ])
    }

    func testInvalidValuesFallBackAndNumericValuesClamp() {
        let configuration = InsideJobRuntimeConfiguration.resolve(
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

        XCTAssertEqual(configuration.preferredPort, ResolvedConfigurationValue(value: 5151, source: .infoPlist))
        XCTAssertEqual(configuration.allowedScopes, ResolvedConfigurationValue(value: [.usb], source: .infoPlist))
        XCTAssertEqual(configuration.sessionReleaseTimeout, ResolvedConfigurationValue(value: 1.0, source: .environment))
        XCTAssertEqual(configuration.warnings, [
            .invalidValueIgnored(key: StartupEnvironmentKey.port.rawValue, source: .environment, value: "99999"),
            .invalidValueIgnored(key: StartupEnvironmentKey.scope.rawValue, source: .environment, value: "bogus")
        ])
    }

    func testRuntimeConfigurationAppliesAPIOverridesDuringResolution() throws {
        let runtimeConfiguration = try InsideJobRuntimeConfiguration.resolve(
            env: environment([
                .token: "startup-token",
                .instanceId: "startup-id",
                .port: "5151",
                .scope: "simulator",
                .sessionTimeout: "12"
            ]),
            infoPlist: makeInfoPlist([:]),
            token: "api-token",
            instanceId: "api-id",
            allowedScopes: [.network],
            port: 4242,
            addressFamily: .ipv4,
            fingerprintsEnabled: false
        )

        XCTAssertEqual(
            runtimeConfiguration.token,
            ResolvedConfigurationValue(value: "api-token", source: .api)
        )
        XCTAssertEqual(
            runtimeConfiguration.sessionIdentity.effectiveInstanceId,
            ResolvedConfigurationValue(value: "api-id", source: .api)
        )
        XCTAssertEqual(
            runtimeConfiguration.preferredPort,
            ResolvedConfigurationValue(value: 4242, source: .api)
        )
        XCTAssertEqual(
            runtimeConfiguration.allowedScopes,
            ResolvedConfigurationValue(value: [.network], source: .api)
        )
        XCTAssertEqual(runtimeConfiguration.addressFamily, .ipv4)
        XCTAssertEqual(
            runtimeConfiguration.sessionReleaseTimeout,
            ResolvedConfigurationValue(value: 12.0, source: .environment)
        )
        XCTAssertEqual(
            runtimeConfiguration.fingerprintsEnabled,
            ResolvedConfigurationValue(value: false, source: .api)
        )
        XCTAssertEqual(
            runtimeConfiguration.failureEvidencePolicy,
            ResolvedConfigurationValue(value: .screenshot, source: .defaultValue)
        )
    }

    func testRuntimeConfigurationUsesResolvedBoundaryDefaultsWhenAPIOverridesAreAbsent() throws {
        let runtimeConfiguration = try InsideJobRuntimeConfiguration.resolve(
            env: environment([.token: "startup-token"]),
            infoPlist: makeInfoPlist([
                .instanceId: "startup-id",
                .scope: ["usb"],
                .sessionTimeout: 24.0
            ]),
            token: nil,
            instanceId: nil,
            allowedScopes: nil,
            port: 0
        )

        XCTAssertEqual(
            runtimeConfiguration.token,
            ResolvedConfigurationValue(value: "startup-token", source: .environment)
        )
        XCTAssertEqual(runtimeConfiguration.sessionIdentity.effectiveInstanceId.source, .generated)
        XCTAssertEqual(
            runtimeConfiguration.preferredPort,
            ResolvedConfigurationValue(value: 0, source: .defaultValue)
        )
        XCTAssertEqual(
            runtimeConfiguration.allowedScopes,
            ResolvedConfigurationValue(value: [.usb], source: .infoPlist)
        )
        XCTAssertEqual(runtimeConfiguration.addressFamily, .dualStack)
        XCTAssertEqual(
            runtimeConfiguration.sessionReleaseTimeout,
            ResolvedConfigurationValue(value: 24.0, source: .infoPlist)
        )
    }

    func testRuntimeConfigurationRejectsBlankExplicitValues() {
        XCTAssertThrowsError(
            try InsideJobRuntimeConfiguration.resolve(
                env: .empty,
                infoPlist: makeInfoPlist([:]),
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
                env: .empty,
                infoPlist: makeInfoPlist([:]),
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
        let runtimeConfiguration = InsideJobRuntimeConfiguration.resolve(
            env: .empty,
            infoPlist: makeInfoPlist([:])
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
        let runtimeConfiguration = InsideJobRuntimeConfiguration.resolve(
            env: .empty,
            infoPlist: makeInfoPlist([:])
        )

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
            .appendingPathComponent("InsideJobRuntimeConfigurationTests-\(UUID().uuidString)")
            .appendingPathExtension("plist")
        try data.write(to: url)
        return StartupInfoPlist(contentsOf: url)
    } catch {
        XCTFail("Failed to write Info.plist fixture: \(error)", file: file, line: line)
        return StartupInfoPlist(contentsOf: URL(fileURLWithPath: "/dev/null"))
    }
}
#endif
