import XCTest
import ThePlans
import TheScore
@_spi(ButtonHeistTooling) @testable import ButtonHeist

final class EnvironmentConfigTests: XCTestCase {

    func testDefaultsWithEmptyEnv() throws {
        let config = try resolve(env: .empty)
        XCTAssertEqual(config.connectionTarget, DeviceResolutionTarget(filter: nil))
        XCTAssertFalse(config.hasConnectionTarget)
        XCTAssertNil(config.token)
        XCTAssertEqual(config.sessionTimeout, .after(60))
        XCTAssertEqual(config.connectionTimeout, 30.0)
        XCTAssertTrue(config.autoReconnect)
    }

    func testEnvVarDeviceAndToken() throws {
        let env = environment([
            .buttonheistDevice: "127.0.0.1:1455",
            .buttonheistToken: "tok-123",
        ])
        let config = try resolve(env: env)
        XCTAssertEqual(config.connectionTarget, DeviceResolutionTarget(filter: "127.0.0.1:1455"))
        XCTAssertTrue(config.hasConnectionTarget)
        XCTAssertEqual(config.token, "tok-123")
    }

    func testExplicitOverridesWinOverEnvVars() throws {
        let env = environment([
            .buttonheistDevice: "env-device",
            .buttonheistToken: "env-token",
        ])
        let config = try resolve(
            deviceFilter: "explicit-device",
            token: "explicit-token",
            env: env
        )
        XCTAssertEqual(config.connectionTarget, DeviceResolutionTarget(filter: "explicit-device"))
        XCTAssertEqual(config.token, "explicit-token")
    }

    func testDefaultConfigTargetUsesEnvironmentToken() throws {
        let name = TargetName(rawValue: "sim")
        let target = TargetConfig(device: "127.0.0.1:1455", token: "config-token")
        let config = try EnvironmentConfig.resolve(
            deviceFilter: nil,
            token: nil,
            sessionTimeout: nil,
            connectionTimeout: nil,
            autoReconnect: true,
            fileConfig: ButtonHeistFileConfig(targets: [name: target], defaultTarget: name),
            environment: ButtonHeistEnvironment(token: "env-token")
        )

        XCTAssertEqual(config.connectionTarget, DeviceResolutionTarget(config: target, named: name))
        XCTAssertEqual(config.token, "env-token")
    }

    func testSessionTimeoutFromEnvVar() throws {
        let env = environment([.buttonheistSessionTimeout: "120"])
        let config = try resolve(env: env)
        XCTAssertEqual(config.sessionTimeout, .after(120))
    }

    func testConnectionTimeoutFromEnvVar() throws {
        let env = environment([.buttonheistConnectionTimeout: "7.5"])
        let config = try resolve(env: env)
        XCTAssertEqual(config.connectionTimeout, 7.5)
    }

    func testExplicitSessionTimeoutOverridesEnv() throws {
        let env = environment([.buttonheistSessionTimeout: "120"])
        let config = try resolve(sessionTimeout: 300, env: env)
        XCTAssertEqual(config.sessionTimeout, .after(300))
    }

    func testExplicitConnectionTimeoutOverridesEnv() throws {
        let env = environment([.buttonheistConnectionTimeout: "7.5"])
        let config = try resolve(connectionTimeout: 2.0, env: env)
        XCTAssertEqual(config.connectionTimeout, 2.0)
    }

    func testExplicitTimeoutOverridesMalformedEnvironmentTimeout() throws {
        let config = try resolve(
            sessionTimeout: 300,
            connectionTimeout: 2,
            env: environment([
                .buttonheistSessionTimeout: "not-a-number",
                .buttonheistConnectionTimeout: "not-a-number",
            ])
        )
        XCTAssertEqual(config.sessionTimeout, .after(300))
        XCTAssertEqual(config.connectionTimeout, 2)
    }

    func testMalformedSessionTimeoutEnvironmentIsRejected() {
        assertTimeoutConfigurationError(
            sessionTimeout: "abc",
            expectedSource: .environment(.session),
            expectedObserved: "abc"
        )
    }

    func testMalformedConnectionTimeoutEnvironmentIsRejected() {
        assertTimeoutConfigurationError(
            connectionTimeout: "abc",
            expectedSource: .environment(.connection),
            expectedObserved: "abc"
        )
    }

    func testZeroSessionTimeoutDisablesIdleExpiration() throws {
        XCTAssertEqual(
            try resolve(sessionTimeout: 0, env: .empty).sessionTimeout,
            .disabled
        )
        XCTAssertEqual(
            try resolve(env: environment([.buttonheistSessionTimeout: "0"])).sessionTimeout,
            .disabled
        )
    }

    func testNonPositiveAndNonFiniteEnvironmentTimeoutsAreRejected() {
        for (sessionTimeout, connectionTimeout, source, observed) in [
            ("-5", nil, EnvironmentTimeoutConfigurationError.Source.environment(.session), "-5"),
            ("nan", nil, .environment(.session), "nan"),
            ("1e309", nil, .environment(.session), "1e309"),
            (nil, "0", .environment(.connection), "0"),
            (nil, "-5", .environment(.connection), "-5"),
            (nil, "nan", .environment(.connection), "nan"),
            (nil, "1e309", .environment(.connection), "1e309"),
        ] {
            assertTimeoutConfigurationError(
                sessionTimeout: sessionTimeout,
                connectionTimeout: connectionTimeout,
                expectedSource: source,
                expectedObserved: observed
            )
        }
    }

    func testFenceConfigurationProducesMatchingValues() throws {
        let config = try resolve(
            deviceFilter: "127.0.0.1:1455",
            token: "tok",
            connectionTimeout: 15,
            autoReconnect: false,
            env: .empty
        )
        let fence = config.fenceConfiguration
        XCTAssertEqual(fence.connectionTarget, DeviceResolutionTarget(filter: "127.0.0.1:1455"))
        XCTAssertEqual(fence.token, "tok")
        XCTAssertEqual(fence.connectionTimeout, 15.0)
        XCTAssertEqual(fence.autoReconnect, false)
    }

    func testExplicitNonPositiveAndNonFiniteTimeoutsAreRejected() {
        for (sessionTimeout, connectionTimeout, source) in [
            (-5.0, nil, EnvironmentTimeoutConfigurationError.Source.explicit(.session)),
            (.infinity, nil, .explicit(.session)),
            (.nan, nil, .explicit(.session)),
            (nil, 0.0, .explicit(.connection)),
            (nil, -5.0, .explicit(.connection)),
            (nil, .infinity, .explicit(.connection)),
            (nil, .nan, .explicit(.connection)),
        ] {
            XCTAssertThrowsError(try resolve(
                sessionTimeout: sessionTimeout,
                connectionTimeout: connectionTimeout,
                env: .empty
            )) { error in
                XCTAssertEqual(
                    (error as? EnvironmentTimeoutConfigurationError)?.source,
                    source
                )
            }
        }
    }

    func testExplicitConfigPathFailurePropagatesDiagnosticError() {
        let path = "/nonexistent/path/.buttonheist.json"

        XCTAssertThrowsError(try EnvironmentConfig.resolve(configPath: path, environment: .empty)) { error in
            guard let error = error as? TargetConfigLoadError else {
                XCTFail("Expected TargetConfigLoadError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(error.kind, .readFailed)
            XCTAssertEqual(error.path, path)
            XCTAssertEqual(error.failureDetails.code, .configReadFailed)
        }
    }

    private func resolve(
        deviceFilter: String? = nil,
        token: String? = nil,
        sessionTimeout: TimeInterval? = nil,
        connectionTimeout: TimeInterval? = nil,
        autoReconnect: Bool = true,
        env: ButtonHeistEnvironment
    ) throws -> EnvironmentConfig {
        try EnvironmentConfig.resolve(
            deviceFilter: deviceFilter,
            token: token,
            sessionTimeout: sessionTimeout,
            connectionTimeout: connectionTimeout,
            autoReconnect: autoReconnect,
            fileConfig: nil,
            environment: env
        )
    }

    private func environment(_ values: [EnvironmentKey: String]) -> ButtonHeistEnvironment {
        ButtonHeistEnvironment(
            device: values[.buttonheistDevice],
            token: values[.buttonheistToken],
            sessionTimeout: values[.buttonheistSessionTimeout],
            connectionTimeout: values[.buttonheistConnectionTimeout]
        )
    }

    private func assertTimeoutConfigurationError(
        sessionTimeout: String? = nil,
        connectionTimeout: String? = nil,
        expectedSource: EnvironmentTimeoutConfigurationError.Source,
        expectedObserved: String
    ) {
        XCTAssertThrowsError(try resolve(env: ButtonHeistEnvironment(
            sessionTimeout: sessionTimeout,
            connectionTimeout: connectionTimeout
        ))) { error in
            guard let error = error as? EnvironmentTimeoutConfigurationError else {
                return XCTFail("Expected EnvironmentTimeoutConfigurationError, got \(type(of: error))")
            }
            XCTAssertEqual(error.source, expectedSource)
            XCTAssertEqual(error.observed, expectedObserved)
        }
    }
}
