import ButtonHeistTestSupport
import XCTest
import Network
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

final class TargetConfigTests: XCTestCase {

    // MARK: - ButtonHeistFileConfig Parsing

    func testParseValidConfig() throws {
        let json = """
        {
            "targets": {
                "sim1": {"device": "127.0.0.1:1455", "token": "abc123"},
                "sim2": {"device": "127.0.0.1:1456"}
            },
            "default": "sim1"
        }
        """
        let config = try JSONDecoder().decode(ButtonHeistFileConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.targets.count, 2)
        XCTAssertEqual(config.targets[targetName("sim1")]?.device, "127.0.0.1:1455")
        XCTAssertEqual(config.targets[targetName("sim1")]?.token, "abc123")
        XCTAssertEqual(config.targets[targetName("sim2")]?.device, "127.0.0.1:1456")
        XCTAssertNil(config.targets[targetName("sim2")]?.token)
        XCTAssertEqual(config.defaultTarget, targetName("sim1"))
    }

    func testParseConfigWithoutDefault() throws {
        let json = """
        {
            "targets": {
                "dev": {"device": "127.0.0.1:1455"}
            }
        }
        """
        let config = try JSONDecoder().decode(ButtonHeistFileConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.targets.count, 1)
        XCTAssertNil(config.defaultTarget)
    }

    func testParseEmptyTargets() throws {
        let json = """
        {"targets": {}}
        """
        let config = try JSONDecoder().decode(ButtonHeistFileConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.targets.isEmpty)
    }

    func testParseInvalidJSONFails() {
        let json = "not json"
        XCTAssertThrowsError(try JSONDecoder().decode(ButtonHeistFileConfig.self, from: Data(json.utf8)))
    }

    func testParseMissingTargetsKeyFails() {
        let json = """
        {"default": "sim1"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(ButtonHeistFileConfig.self, from: Data(json.utf8)))
    }

    func testFileConfigRejectsUnknownTopLevelFields() {
        let json = """
        {
            "targets": {
                "sim1": {"device": "127.0.0.1:1455"}
            },
            "unexpected": true
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(ButtonHeistFileConfig.self, from: Data(json.utf8))) { error in
            XCTAssertTrue(String(describing: error).contains("unexpected"), "Unexpected error: \(error)")
        }
    }

    func testTargetConfigRejectsUnknownFields() {
        let json = """
        {
            "targets": {
                "sim1": {"device": "127.0.0.1:1455", "unexpected": true}
            }
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(ButtonHeistFileConfig.self, from: Data(json.utf8))) { error in
            XCTAssertTrue(String(describing: error).contains("unexpected"), "Unexpected error: \(error)")
        }
    }

    func testTargetConfigRejectsRemovedCertFingerprintField() {
        let json = """
        {
            "targets": {
                "sim1": {
                    "device": "127.0.0.1:1455",
                    "token": "abc123",
                    "certFingerprint": "stale"
                }
            }
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(ButtonHeistFileConfig.self, from: Data(json.utf8))) { error in
            XCTAssertTrue(String(describing: error).contains("certFingerprint"), "Unexpected error: \(error)")
        }
    }

    // MARK: - TargetConfigResolver.resolveEffective

    func testEnvVarsOverrideEverything() {
        let config = ButtonHeistFileConfig(
            targets: targetConfigs(["sim1": TargetConfig(device: "127.0.0.1:1455", token: "config-token")]),
            defaultTarget: targetName("sim1")
        )
        let env = environment([
            .buttonheistDevice: "127.0.0.1:9999",
            .buttonheistToken: "env-token",
        ])

        let resolved = TargetConfigResolver.resolveEffective(targetName: targetName("sim1"), config: config, environment: env)
        XCTAssertEqual(resolved?.device, "127.0.0.1:9999")
        XCTAssertEqual(resolved?.token, "env-token")
    }

    func testEnvDeviceWithoutTokenUsesNilToken() {
        let env = environment([.buttonheistDevice: "127.0.0.1:9999"])
        let resolved = TargetConfigResolver.resolveEffective(config: nil, environment: env)
        XCTAssertEqual(resolved?.device, "127.0.0.1:9999")
        XCTAssertNil(resolved?.token)
    }

    func testNamedTargetFromConfig() {
        let config = ButtonHeistFileConfig(
            targets: targetConfigs(["sim1": TargetConfig(device: "127.0.0.1:1455", token: "t1")]),
            defaultTarget: nil
        )
        let resolved = TargetConfigResolver.resolveEffective(targetName: targetName("sim1"), config: config, environment: .empty)
        XCTAssertEqual(resolved?.device, "127.0.0.1:1455")
        XCTAssertEqual(resolved?.token, "t1")
    }

    func testDefaultTargetFromConfig() {
        let config = ButtonHeistFileConfig(
            targets: targetConfigs([
                "sim1": TargetConfig(device: "127.0.0.1:1455"),
                "sim2": TargetConfig(device: "127.0.0.1:1456"),
            ]),
            defaultTarget: targetName("sim2")
        )
        let resolved = TargetConfigResolver.resolveEffective(config: config, environment: .empty)
        XCTAssertEqual(resolved?.device, "127.0.0.1:1456")
    }

    func testNoConfigNoEnvReturnsNil() {
        let resolved = TargetConfigResolver.resolveEffective(config: nil, environment: .empty)
        XCTAssertNil(resolved)
    }

    func testUnknownTargetNameReturnsNil() {
        let config = ButtonHeistFileConfig(
            targets: targetConfigs(["sim1": TargetConfig(device: "127.0.0.1:1455")]),
            defaultTarget: nil
        )
        let resolved = TargetConfigResolver.resolveEffective(targetName: targetName("unknown"), config: config, environment: .empty)
        XCTAssertNil(resolved)
    }

    func testEnvTokenOverridesConfigToken() {
        let config = ButtonHeistFileConfig(
            targets: targetConfigs(["sim1": TargetConfig(device: "127.0.0.1:1455", token: "config-token")]),
            defaultTarget: targetName("sim1")
        )
        let env = environment([.buttonheistToken: "env-token"])
        let resolved = TargetConfigResolver.resolveEffective(config: config, environment: env)
        XCTAssertEqual(resolved?.device, "127.0.0.1:1455")
        XCTAssertEqual(resolved?.token, "env-token")
    }

    // MARK: - TargetConfigResolver.loadConfig

    func testLoadConfigFromExplicitPath() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configFile = tmpDir.appendingPathComponent(".buttonheist.json")
        let json = """
        {
            "targets": {
                "test": {"device": "127.0.0.1:1455", "token": "test-token"}
            },
            "default": "test"
        }
        """
        try json.write(to: configFile, atomically: true, encoding: .utf8)

        let config = try TargetConfigResolver.loadConfig(from: configFile.path)
        XCTAssertEqual(config.targets[targetName("test")]?.device, "127.0.0.1:1455")
        XCTAssertEqual(config.targets[targetName("test")]?.token, "test-token")
        XCTAssertEqual(config.defaultTarget, targetName("test"))
    }

    func testExplicitMissingConfigPathThrowsDiagnosticError() {
        let path = "/nonexistent/path/.buttonheist.json"

        XCTAssertThrowsError(try TargetConfigResolver.loadConfig(from: path)) { error in
            guard let error = error as? TargetConfigLoadError else {
                XCTFail("Expected TargetConfigLoadError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(error.kind, .readFailed)
            XCTAssertEqual(error.path, path)
            XCTAssertTrue(error.localizedDescription.contains("Failed to read config"))
            XCTAssertEqual(error.failureDetails.code, .configReadFailed)
            XCTAssertEqual(error.failureDetails.phase, .setup)
        }
    }

    func testExplicitUnreadableConfigPathThrowsDiagnosticError() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        XCTAssertThrowsError(try TargetConfigResolver.loadConfig(from: tmpDir.path)) { error in
            guard let error = error as? TargetConfigLoadError else {
                XCTFail("Expected TargetConfigLoadError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(error.kind, .readFailed)
            XCTAssertEqual(error.path, tmpDir.path)
            XCTAssertTrue(error.localizedDescription.contains("Failed to read config"))
            XCTAssertEqual(error.failureDetails.code, .configReadFailed)
        }
    }

    func testExplicitMalformedConfigPathThrowsDiagnosticError() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configFile = tmpDir.appendingPathComponent(".buttonheist.json")
        try "not json".write(to: configFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try TargetConfigResolver.loadConfig(from: configFile.path)) { error in
            guard let error = error as? TargetConfigLoadError else {
                XCTFail("Expected TargetConfigLoadError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(error.kind, .decodeFailed)
            XCTAssertEqual(error.path, configFile.path)
            XCTAssertTrue(error.localizedDescription.contains("Failed to decode config"))
            XCTAssertEqual(error.failureDetails.code, .configDecodeFailed)
            XCTAssertEqual(error.failureDetails.phase, .setup)
        }
    }

    func testAbsentDefaultConfigReturnsNil() throws {
        let config = try TargetConfigResolver.loadConfig(searchPaths: [
            "/nonexistent/default/.buttonheist.json",
            "/nonexistent/default/config.json",
        ])
        XCTAssertNil(config)
    }

    func testDefaultConfigSearchRejectsRemovedCertFingerprintField() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configFile = tmpDir.appendingPathComponent(".buttonheist.json")
        let json = """
        {
            "targets": {
                "sim1": {
                    "device": "127.0.0.1:1455",
                    "certFingerprint": "stale"
                }
            }
        }
        """
        try json.write(to: configFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try TargetConfigResolver.loadConfig(searchPaths: [configFile.path])) { error in
            guard let error = error as? TargetConfigLoadError else {
                XCTFail("Expected TargetConfigLoadError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(error.kind, .decodeFailed)
            XCTAssertEqual(error.path, configFile.path)
            XCTAssertEqual(error.failureDetails.code, .configDecodeFailed)
        }
    }

    // MARK: - TheFence.configTargetsAsDevices

    @ButtonHeistActor
    func testConfigTargetsAsDevices() async {
        let config = ButtonHeistFileConfig(
            targets: targetConfigs([
                "sim1": TargetConfig(device: "127.0.0.1:1455"),
                "sim2": TargetConfig(device: "127.0.0.1:1456", token: "tok"),
            ])
        )
        let devices = TheFence.configTargetsAsDevices(config)
        XCTAssertEqual(devices.count, 2)

        let sim1 = devices.first { $0.id == "config-sim1" }
        XCTAssertNotNil(sim1)
        XCTAssertEqual(sim1?.name, "sim1")

        let sim2 = devices.first { $0.id == "config-sim2" }
        XCTAssertNotNil(sim2)
        XCTAssertEqual(sim2?.name, "sim2")
    }

    @ButtonHeistActor
    func testConfigTargetsWithInvalidDeviceSkipped() async {
        let config = ButtonHeistFileConfig(
            targets: targetConfigs([
                "good": TargetConfig(device: "127.0.0.1:1455"),
                "bad": TargetConfig(device: "no-port-here"),
            ])
        )
        let devices = TheFence.configTargetsAsDevices(config)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, "config-good")
    }

    // MARK: - FenceResponse.targets formatting

    func testTargetsResponseHumanFormatting() {
        let response = FenceResponse.targets(
            targetConfigs(["sim1": TargetConfig(device: "127.0.0.1:1455")]),
            defaultTarget: targetName("sim1")
        )
        let text = response.humanFormatted()
        XCTAssertTrue(text.contains("sim1"))
        XCTAssertTrue(text.contains("127.0.0.1:1455"))
        XCTAssertTrue(text.contains("(default)"))
    }

    func testTargetsResponseEmptyHumanFormatting() {
        let response = FenceResponse.targets([:], defaultTarget: nil)
        XCTAssertEqual(response.humanFormatted(), "No targets configured")
    }

    func testTargetsResponseJSON() throws {
        let response = FenceResponse.targets(
            targetConfigs([
                "sim1": TargetConfig(device: "127.0.0.1:1455", token: "tok"),
                "sim2": TargetConfig(device: "127.0.0.1:1456"),
            ]),
            defaultTarget: targetName("sim1")
        )
        let json = try publicJSONProbe(response)
        XCTAssertEqual(try json.string("status"), "ok")
        XCTAssertEqual(try json.string("default"), "sim1")
        let targets = try json.object("targets")
        XCTAssertEqual(try targets.object("sim1").string("device"), "127.0.0.1:1455")
        XCTAssertEqual(try targets.object("sim1").bool("hasToken"), true)
        try targets.object("sim2").assertMissing("hasToken")
    }

    func testTargetsResponseCompactFormatting() {
        let response = FenceResponse.targets(
            targetConfigs(["sim1": TargetConfig(device: "127.0.0.1:1455")]),
            defaultTarget: targetName("sim1")
        )
        let text = response.compactFormatted()
        XCTAssertTrue(text.contains("sim1"))
        XCTAssertTrue(text.contains("*"))
    }

    // MARK: - TheFence connect dispatch (with mock injection)

    private static let testDevice = DiscoveredDevice(
        id: "mock-device",
        name: "MockApp#test",
        endpoint: DiscoveredDeviceEndpoint.hostPort(host: "::1", port: 1)
    )

    private static let testServerInfo = ServerInfo(
        appName: "MockApp",
        bundleIdentifier: "com.test.mock",
        deviceName: "MockDevice",
        systemVersion: "18.0",
        screenWidth: 393,
        screenHeight: 852,
        instanceId: "mock-session",
        instanceIdentifier: "mock-server",
        listeningPort: 49152,
        tlsActive: true
    )

    @ButtonHeistActor
    private func makeMockFence(fileConfig: ButtonHeistFileConfig? = nil) -> TheFence {
        let mockConn = MockConnection()
        mockConn.serverInfo = Self.testServerInfo
        mockConn.responseScript = { message in
            switch message {
            case .requestInterface:
                return .interface(makeTestInterface(elements: [], timestamp: Date()))
            default:
                return .actionResult(ActionResult.success(payload: .activate))
            }
        }

        let mockDisc = MockDiscovery()
        mockDisc.discoveredDevices = [Self.testDevice]

        let fence = TheFence(configuration: .init(fileConfig: fileConfig))
        fence.handoff.makeDiscovery = { mockDisc }
        fence.handoff.makeConnection = { _ in mockConn }

        makeReachabilityConnection = { _ in
            let probe = MockConnection()
            probe.emitTransportReadyOnConnect = true
            probe.responseScript = { message in
                if case .status = message {
                    return .status(StatusPayload(
                        identity: StatusIdentity(
                            appName: "Mock", bundleIdentifier: "com.test",
                            appBuild: "1", deviceName: "Mock",
                            systemVersion: "18.0", buttonHeistVersion: "0.0.1"
                        ),
                        session: StatusSession(active: false, watchersAllowed: false, activeConnections: 0)
                    ))
                }
                return .actionResult(ActionResult.success(payload: .activate))
            }
            return probe
        }

        return fence
    }

    @ButtonHeistActor
    func testConnectWithNamedTargetSwitchesConnection() async throws {
        let config = ButtonHeistFileConfig(
            targets: targetConfigs([
                "sim1": TargetConfig(device: "127.0.0.1:1455", token: "tok1"),
                "sim2": TargetConfig(device: "127.0.0.1:1456", token: "tok2"),
            ]),
            defaultTarget: targetName("sim1")
        )
        let fence = makeMockFence(fileConfig: config)

        let response = try await fence.execute(command: .connect, values: ["target": .string("sim2")])
        guard case .sessionState(let payload) = response else {
            XCTFail("Expected sessionState response, got \(response)")
            return
        }
        guard case .connected = payload.state else {
            return XCTFail("Expected connected session state, got \(payload.state)")
        }
        XCTAssertEqual(fence.config.deviceFilter, "127.0.0.1:1456")
        XCTAssertEqual(fence.config.token, "tok2")
    }

    @ButtonHeistActor
    func testConnectWithDirectDeviceSwitchesConnection() async throws {
        let fence = makeMockFence()
        fence.handoff.setupAutoReconnect(filter: "stale-target")

        let response = try await fence.execute(command: .connect, values: [
            "device": .string("127.0.0.1:9999"),
            "token": .string("direct-tok"),
        ])
        guard case .sessionState(let payload) = response else {
            XCTFail("Expected sessionState response, got \(response)")
            return
        }
        guard case .connected = payload.state else {
            return XCTFail("Expected connected session state, got \(payload.state)")
        }
        XCTAssertEqual(fence.config.deviceFilter, "127.0.0.1:9999")
        XCTAssertEqual(fence.config.token, "direct-tok")
    }

    @ButtonHeistActor
    func testConnectFailureLeavesDisconnectedOnRequestedTarget() async throws {
        let config = ButtonHeistFileConfig(
            targets: targetConfigs([
                "sim1": TargetConfig(device: "127.0.0.1:1455", token: "tok1"),
            ]),
            defaultTarget: targetName("sim1")
        )
        let fence = TheFence(configuration: .init(
            deviceFilter: "127.0.0.1:1455",
            token: "tok1",
            fileConfig: config
        ))

        var connectAttempt = 0

        let mockDisc = MockDiscovery()
        mockDisc.discoveredDevices = [Self.testDevice]
        fence.handoff.makeDiscovery = { mockDisc }
        fence.handoff.makeConnection = { _ in
            connectAttempt += 1
            let failing = MockConnection()
            failing.connectEventsOverride = [
                .disconnected(.authFailed("denied")),
            ]
            return failing
        }

        makeReachabilityConnection = { _ in
            let probe = MockConnection()
            probe.emitTransportReadyOnConnect = true
            probe.responseScript = { message in
                if case .status = message {
                    return .status(StatusPayload(
                        identity: StatusIdentity(
                            appName: "Mock", bundleIdentifier: "com.test",
                            appBuild: "1", deviceName: "Mock",
                            systemVersion: "18.0", buttonHeistVersion: "0.0.1"
                        ),
                        session: StatusSession(active: false, watchersAllowed: false, activeConnections: 0)
                    ))
                }
                return .actionResult(ActionResult.success(payload: .activate))
            }
            return probe
        }

        let response = try await fence.execute(command: .connect, values: [
            "device": .string("127.0.0.1:9999"),
            "token": .string("bad-tok"),
        ])
        if case .error(let failure) = response {
            XCTAssertTrue(failure.message.contains("Connect failed; disconnected from previous target"))
            XCTAssertTrue(failure.message.contains("denied"))
        } else {
            XCTFail("Expected error response, got \(response)")
        }
        XCTAssertEqual(fence.config.deviceFilter, "127.0.0.1:9999")
        XCTAssertEqual(fence.config.token, "bad-tok")
        XCTAssertEqual(connectAttempt, 1)
        XCTAssertFalse(fence.handoff.connectionLifecycle.isConnected)
    }

    @ButtonHeistActor
    func testConnectWithoutTargetOrDeviceReturnsError() async throws {
        let fence = TheFence(configuration: .init())
        do {
            _ = try await fence.execute(command: .connect)
            XCTFail("Expected invalid request")
        } catch let error as FenceError {
            guard case .invalidRequest(let message) = error else {
                return XCTFail("Expected invalidRequest, got \(error)")
            }
            XCTAssertTrue(message.contains("Must specify"))
        }
    }

    @ButtonHeistActor
    func testConnectWithUnknownTargetReturnsError() async throws {
        let config = ButtonHeistFileConfig(
            targets: targetConfigs(["sim1": TargetConfig(device: "127.0.0.1:1455")]),
            defaultTarget: targetName("sim1")
        )
        let fence = TheFence(configuration: .init(fileConfig: config))
        do {
            _ = try await fence.execute(command: .connect, values: ["target": .string("nonexistent")])
            XCTFail("Expected invalid request")
        } catch let error as FenceError {
            guard case .invalidRequest(let message) = error else {
                return XCTFail("Expected invalidRequest, got \(error)")
            }
            XCTAssertTrue(message.contains("Unknown target"))
            XCTAssertTrue(message.contains("sim1"))
        }
    }

    @ButtonHeistActor
    func testConnectWithNoConfigFileReturnsError() async throws {
        let fence = TheFence(configuration: .init())
        do {
            _ = try await fence.execute(command: .connect, values: ["target": .string("sim1")])
            XCTFail("Expected invalid request")
        } catch let error as FenceError {
            guard case .invalidRequest(let message) = error else {
                return XCTFail("Expected invalidRequest, got \(error)")
            }
            XCTAssertTrue(message.contains("No config file"))
        }
    }

    @ButtonHeistActor
    func testListTargetsWithNoConfig() async throws {
        let fence = TheFence(configuration: .init())
        let response = try await fence.execute(command: .listTargets)
        if case .targets(let targets, _) = response {
            XCTAssertTrue(targets.isEmpty)
        } else {
            XCTFail("Expected targets response, got \(response)")
        }
    }

    @ButtonHeistActor
    func testListTargetsWithConfig() async throws {
        let config = ButtonHeistFileConfig(
            targets: targetConfigs([
                "sim1": TargetConfig(device: "127.0.0.1:1455"),
                "sim2": TargetConfig(device: "127.0.0.1:1456"),
            ]),
            defaultTarget: targetName("sim1")
        )
        let fence = TheFence(configuration: .init(fileConfig: config))
        let response = try await fence.execute(command: .listTargets)
        if case .targets(let targets, let defaultTarget) = response {
            XCTAssertEqual(targets.count, 2)
            XCTAssertEqual(defaultTarget, targetName("sim1"))
        } else {
            XCTFail("Expected targets response, got \(response)")
        }
    }

    // MARK: - TargetConfig Codable round-trip

    func testTargetConfigRoundTrip() throws {
        let original = TargetConfig(device: "127.0.0.1:1455", token: "secret")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TargetConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testButtonHeistFileConfigRoundTrip() throws {
        let original = ButtonHeistFileConfig(
            targets: targetConfigs([
                "sim1": TargetConfig(device: "127.0.0.1:1455", token: "tok"),
                "sim2": TargetConfig(device: "127.0.0.1:1456"),
            ]),
            defaultTarget: targetName("sim1")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ButtonHeistFileConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    private func targetName(_ value: String) -> TargetName {
        TargetName(rawValue: value)
    }

    private func targetConfigs(_ values: [String: TargetConfig]) -> [TargetName: TargetConfig] {
        Dictionary(uniqueKeysWithValues: values.map { key, value in
            (targetName(key), value)
        })
    }

    private func environment(_ values: [EnvironmentKey: String]) -> ButtonHeistEnvironment {
        ButtonHeistEnvironment(
            device: values[.buttonheistDevice],
            token: values[.buttonheistToken],
            sessionTimeout: values[.buttonheistSessionTimeout],
            connectionTimeout: values[.buttonheistConnectionTimeout]
        )
    }
}
