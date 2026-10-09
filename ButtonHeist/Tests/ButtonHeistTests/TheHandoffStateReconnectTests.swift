import ButtonHeistTestSupport
import Network
import os
import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

final class TheHandoffStateReconnectTests: XCTestCase {
    // MARK: - Auto Reconnect

    @ButtonHeistActor
    func testDisableAutoReconnectCancelsReconnectRunner() async {
        let handoff = TheHandoff()
        let reconnectSleeper = ManualReconnectSleeper()
        handoff.reconnectSleeper = reconnectSleeper.sleep
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        var connectionCount = 0
        handoff.makeConnection = { _ in
            connectionCount += 1
            let mock = MockConnection()
            mock.connectEventsOverride = [
                .connected,
                .disconnected(.serverClosed),
            ]
            return mock
        }

        handoff.setupAutoReconnect(target: DeviceResolutionTarget(filter: "App"))
        handoff.connect(to: device)

        await Task.yield()
        XCTAssertEqual(reconnectSleeper.sleepCallCount, 1)

        handoff.disableAutoReconnect()
        reconnectSleeper.resumeNext()
        await Task.yield()

        XCTAssertEqual(connectionCount, 1)
    }

    @ButtonHeistActor
    func testReplacingAutoReconnectFilterPreventsStaleReconnect() async {
        let handoff = TheHandoff()
        let reconnectSleeper = ManualReconnectSleeper()
        handoff.reconnectSleeper = reconnectSleeper.sleep
        let oldDevice = DiscoveredDevice(
            id: "old-device",
            name: "OldApp#one",
            endpoint: .hostPort(host: "127.0.0.1", port: 1111)
        )
        let newDevice = DiscoveredDevice(
            id: "new-device",
            name: "NewApp#one",
            endpoint: .hostPort(host: "127.0.0.1", port: 2222)
        )

        let mockDiscovery = MockDiscovery()
        mockDiscovery.discoveredDevices = [oldDevice, newDevice]
        handoff.makeDiscovery = { mockDiscovery }
        handoff.startDiscovery()

        var connectedIDs: [DiscoveryDeviceID] = []
        handoff.makeConnection = { device in
            connectedIDs.append(device.id)
            let connection = MockConnection()
            connection.connectEventsOverride = connectedIDs.count == 1
                ? [.connected, .disconnected(.serverClosed)]
                : [.connected]
            return connection
        }

        handoff.setupAutoReconnect(target: DeviceResolutionTarget(filter: "OldApp"))
        handoff.connect(to: oldDevice)
        XCTAssertEqual(connectedIDs, ["old-device"])
        await Task.yield()
        XCTAssertEqual(reconnectSleeper.sleepCallCount, 1)

        handoff.setupAutoReconnect(target: DeviceResolutionTarget(filter: "NewApp"))
        reconnectSleeper.resumeNext()
        await Task.yield()

        XCTAssertEqual(connectedIDs, ["old-device"])
    }

    @ButtonHeistActor
    func testDisconnectEventWithEnabledPolicyTriggersReconnect() async throws {
        let handoff = TheHandoff()
        handoff.reconnectInterval = 0.01
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)

        let reconnected = expectation(description: "reconnect connection made")
        var connectionCount = 0
        handoff.makeConnection = { _ in
            connectionCount += 1
            let connection = MockConnection()
            if connectionCount == 1 {
                connection.connectEventsOverride = [
                    .connected,
                    .disconnected(.serverClosed),
                ]
            } else {
                connection.serverInfo = ServerInfo(
                    appName: "TestApp",
                    bundleIdentifier: "com.test",
                    deviceName: "Simulator",
                    systemVersion: "26.1",
                    screenWidth: 402,
                    screenHeight: 874,
                    instanceId: "test-session",
                    instanceIdentifier: "test",
                    listeningPort: 49152,
                    tlsActive: true
                )
                reconnected.fulfill()
            }
            return connection
        }

        let mockDiscovery = MockDiscovery()
        mockDiscovery.discoveredDevices = [device]
        handoff.makeDiscovery = { mockDiscovery }
        handoff.startDiscovery()

        handoff.setupAutoReconnect(target: DeviceResolutionTarget(filter: nil))

        handoff.connect(to: device)
        XCTAssertEqual(connectionCount, 1)

        await fulfillment(of: [reconnected], timeout: 5)

        XCTAssertGreaterThanOrEqual(connectionCount, 2)
    }

    @ButtonHeistActor
    func testConnectionLifecycleCancelsReplacedRunAndRejectsStaleCompletion() async {
        let lifecycle = HandoffConnectionLifecycle()
        let oldDevice = DiscoveredDevice(host: "127.0.0.1", port: 1111)
        let newDevice = DiscoveredDevice(host: "127.0.0.1", port: 2222)

        XCTAssertTrue(lifecycle.setup(target: DeviceResolutionTarget(filter: "OldApp")))
        guard let oldTarget = lifecycle.targetForDisconnectedDevice(oldDevice) else {
            return XCTFail("Expected old reconnect target")
        }
        guard let oldRun = lifecycle.run(target: oldTarget, operation: { _ in }) else {
            return XCTFail("Expected old reconnect run")
        }
        XCTAssertTrue(lifecycle.isReconnectRunning)

        XCTAssertTrue(lifecycle.setup(target: DeviceResolutionTarget(filter: "NewApp")))
        XCTAssertFalse(lifecycle.isReconnectRunning)
        XCTAssertFalse(lifecycle.finishSuccess(oldRun))
        XCTAssertFalse(lifecycle.finishFailure(oldRun, failure: .connectionFailed("stale")))

        guard let newTarget = lifecycle.targetForDisconnectedDevice(newDevice) else {
            return XCTFail("Expected new reconnect target")
        }
        guard let newRun = lifecycle.run(target: newTarget, operation: { _ in }) else {
            return XCTFail("Expected new reconnect run")
        }

        XCTAssertTrue(lifecycle.finishSuccess(newRun))
    }

    @ButtonHeistActor
    func testConnectionLifecycleRejectsDuplicateRunAndRetainsTargetAfterCancellation() async {
        let lifecycle = HandoffConnectionLifecycle()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)

        XCTAssertTrue(lifecycle.setup(target: DeviceResolutionTarget(filter: nil)))
        guard let target = lifecycle.targetForDisconnectedDevice(device) else {
            return XCTFail("Expected reconnect target")
        }

        XCTAssertNotNil(lifecycle.run(target: target, operation: { _ in }))
        XCTAssertNil(lifecycle.run(target: target, operation: { _ in }))
        XCTAssertTrue(lifecycle.cancelReconnectAttempt())
        XCTAssertEqual(lifecycle.targetForDisconnectedDevice(device), target)
    }

    @ButtonHeistActor
    func testConnectionLifecycleReconnectExhaustionRequiresExplicitRearming() async {
        let lifecycle = HandoffConnectionLifecycle()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let failure = HandoffConnectionError.connectionFailed("gave up")

        XCTAssertTrue(lifecycle.setup(target: DeviceResolutionTarget(filter: nil)))
        guard let target = lifecycle.targetForDisconnectedDevice(device) else {
            return XCTFail("Expected reconnect target")
        }
        guard let run = lifecycle.run(target: target, operation: { _ in }) else {
            return XCTFail("Expected reconnect run")
        }

        XCTAssertTrue(lifecycle.finishFailure(run, failure: failure))
        assertFailed(lifecycle.phase, failure: failure)
        XCTAssertFalse(lifecycle.isReconnectRunning)
        XCTAssertFalse(lifecycle.finishSuccess(run))
        XCTAssertFalse(lifecycle.finishFailure(run, failure: .connectionFailed("again")))
        XCTAssertNil(lifecycle.targetForDisconnectedDevice(device))

        XCTAssertTrue(lifecycle.setup(target: DeviceResolutionTarget(filter: nil)))
        XCTAssertNotNil(lifecycle.targetForDisconnectedDevice(device))
    }

    @ButtonHeistActor
    func testConnectionLifecycleReconnectSuccessRetainsOnlyFilterPolicy() async {
        let lifecycle = HandoffConnectionLifecycle()
        let firstDevice = DiscoveredDevice(host: "127.0.0.1", port: 1111)
        let secondDevice = DiscoveredDevice(host: "127.0.0.1", port: 2222)

        XCTAssertTrue(lifecycle.setup(target: DeviceResolutionTarget(filter: nil)))
        guard let firstTarget = lifecycle.targetForDisconnectedDevice(firstDevice),
              let firstRun = lifecycle.run(target: firstTarget, operation: { _ in })
        else {
            return XCTFail("Expected first reconnect run")
        }

        XCTAssertTrue(lifecycle.finishSuccess(firstRun))

        guard let secondTarget = lifecycle.targetForDisconnectedDevice(secondDevice) else {
            return XCTFail("Expected rearmed reconnect target")
        }
        XCTAssertEqual(secondTarget.device, secondDevice)
    }

    @ButtonHeistActor
    func testRetryableDisconnectEntersConnectionLifecycleReconnectPhase() async {
        let handoff = TheHandoff()
        handoff.reconnectInterval = 60
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        var observedPhases: [HandoffConnectionPhase] = []
        handoff.onConnectionStateChanged = { phase in
            observedPhases.append(phase)
        }

        handoff.makeConnection = { _ in
            let connection = MockConnection()
            connection.connectEventsOverride = [
                .connected,
                .disconnected(.serverClosed),
            ]
            return connection
        }

        handoff.setupAutoReconnect(target: DeviceResolutionTarget(filter: nil))
        handoff.connect(to: device)

        assertReconnecting(handoff.connectionPhase, device: device)
        XCTAssertEqual(handoff.connectionLifecycle.diagnosticFailure, .disconnected(.serverClosed))
        XCTAssertTrue(observedPhases.contains { phase in
            guard case .reconnecting(let attempt) = phase else { return false }
            return attempt.target.device == device
        })
        handoff.disableAutoReconnect()
    }

    @ButtonHeistActor
    func testReconnectPhaseNotifiesWhenAttemptIdentityChanges() async {
        let lifecycle = HandoffConnectionLifecycle()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let target = HandoffReconnectTarget(
            resolutionTarget: DeviceResolutionTarget(filter: nil),
            device: device
        )
        var phases: [HandoffConnectionPhase] = []
        lifecycle.onPhaseChanged = { phases.append($0) }

        XCTAssertTrue(lifecycle.setup(target: DeviceResolutionTarget(filter: nil)))
        guard let firstRun = lifecycle.run(target: target, operation: { _ in }) else {
            return XCTFail("Expected first reconnect run")
        }
        XCTAssertTrue(lifecycle.finishSuccess(firstRun))
        guard let secondRun = lifecycle.run(target: target, operation: { _ in }) else {
            return XCTFail("Expected second reconnect run")
        }

        let reconnectAttempts = phases.compactMap { phase -> HandoffReconnectAttempt? in
            guard case .reconnecting(let attempt) = phase else { return nil }
            return attempt
        }
        XCTAssertEqual(reconnectAttempts.map(\.id), [firstRun.id, secondRun.id])
        XCTAssertEqual(reconnectAttempts.map(\.target), [target, target])
    }

    @ButtonHeistActor
    func testReconnectAttemptFailurePreservesRunWithoutRepeatingPhaseNotification() async {
        let lifecycle = HandoffConnectionLifecycle()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let target = HandoffReconnectTarget(
            resolutionTarget: DeviceResolutionTarget(filter: nil),
            device: device
        )
        let failure = HandoffConnectionError.connectionFailed("retry failed")
        var phases: [HandoffConnectionPhase] = []
        lifecycle.onPhaseChanged = { phases.append($0) }

        XCTAssertTrue(lifecycle.setup(target: DeviceResolutionTarget(filter: nil)))
        guard let run = lifecycle.run(target: target, operation: { _ in }) else {
            return XCTFail("Expected reconnect run")
        }

        lifecycle.recordAttemptFailure(failure)

        assertReconnecting(lifecycle.phase, device: device)
        XCTAssertEqual(lifecycle.diagnosticFailure, failure)
        XCTAssertEqual(phases.compactMap { phase -> UUID? in
            guard case .reconnecting(let context) = phase else { return nil }
            return context.id
        }, [run.id])
    }

    @ButtonHeistActor
    func testNonRetryableDisconnectDoesNotTriggerReconnect() async throws {
        let handoff = TheHandoff()
        handoff.reconnectInterval = 0.01
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)

        let disconnected = expectation(description: "disconnect event received")
        var connectionCount = 0
        handoff.makeConnection = { _ in
            connectionCount += 1
            let connection = MockConnection()
            connection.connectEventsOverride = [
                .disconnected(.missingToken),
            ]
            return connection
        }
        handoff.onConnectionStateChanged = { state in
            if case .disconnected = state {
                disconnected.fulfill()
            }
        }

        let mockDiscovery = MockDiscovery()
        mockDiscovery.discoveredDevices = [device]
        handoff.makeDiscovery = { mockDiscovery }
        handoff.startDiscovery()
        handoff.setupAutoReconnect(target: DeviceResolutionTarget(filter: nil))

        handoff.connect(to: device)
        await fulfillment(of: [disconnected], timeout: 5)

        XCTAssertEqual(connectionCount, 1)
    }

    @ButtonHeistActor
    func testForceDisconnectSchedulesReconnectOnlyWhenPolicyAllows() async {
        let disabledPolicyHandoff = TheHandoff()
        let disabledPolicyDevice = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        _ = connectMockHandoff(disabledPolicyHandoff, device: disabledPolicyDevice)

        disabledPolicyHandoff.forceDisconnect()

        assertDisconnected(disabledPolicyHandoff.connectionPhase)

        let enabledPolicyHandoff = TheHandoff()
        let enabledPolicyDevice = DiscoveredDevice(host: "127.0.0.1", port: 5678)
        _ = connectMockHandoff(enabledPolicyHandoff, device: enabledPolicyDevice)
        enabledPolicyHandoff.setupAutoReconnect(target: DeviceResolutionTarget(filter: nil))

        enabledPolicyHandoff.forceDisconnect()

        assertReconnecting(enabledPolicyHandoff.connectionPhase, device: enabledPolicyDevice)
        enabledPolicyHandoff.disableAutoReconnect()
    }

    @ButtonHeistActor
    func testDisconnectEventWithDisabledPolicyDoesNotReconnect() async {
        let handoff = TheHandoff()
        let reconnectSleeper = ManualReconnectSleeper()
        handoff.reconnectSleeper = reconnectSleeper.sleep
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)

        let disconnected = expectation(description: "disconnect event received")
        var connectionCount = 0
        handoff.makeConnection = { _ in
            connectionCount += 1
            let connection = MockConnection()
            connection.connectEventsOverride = [
                .connected,
                .disconnected(.serverClosed),
            ]
            return connection
        }
        handoff.onConnectionStateChanged = { state in
            if case .disconnected = state {
                disconnected.fulfill()
            }
        }

        handoff.connect(to: device)
        XCTAssertEqual(connectionCount, 1)

        await fulfillment(of: [disconnected], timeout: 5)
        await Task.yield()

        XCTAssertEqual(connectionCount, 1)
        XCTAssertEqual(reconnectSleeper.sleepCallCount, 0)
    }

    @ButtonHeistActor
    func testStaleConnectionEventsDoNotMutateNewAttempt() async {
        let handoff = TheHandoff()
        let deviceA = DiscoveredDevice(
            id: "device-a",
            name: "App#A",
            endpoint: .hostPort(host: "127.0.0.1", port: 1111)
        )
        let deviceB = DiscoveredDevice(
            id: "device-b",
            name: "App#B",
            endpoint: .hostPort(host: "127.0.0.1", port: 2222)
        )
        let connectionA = MockConnection()
        let connectionB = MockConnection()
        connectionA.connectEventsOverride = []
        connectionB.connectEventsOverride = []
        handoff.makeConnection = { device in
            switch device.id {
            case deviceA.id: return connectionA
            case deviceB.id: return connectionB
            default:
                XCTFail("Unexpected device: \(device)")
                return MockConnection()
            }
        }

        handoff.connect(to: deviceA)
        assertConnecting(handoff.connectionPhase, device: deviceA)

        handoff.connect(to: deviceB)
        assertConnecting(handoff.connectionPhase, device: deviceB)

        connectionA.onEvent?(.connected)
        assertConnecting(handoff.connectionPhase, device: deviceB)
        XCTAssertNil(handoff.connectionLifecycle.connectedDevice)

        connectionB.onEvent?(.connected)
        assertConnected(handoff.connectionPhase, device: deviceB)

        connectionA.onEvent?(.disconnected(.serverClosed))
        assertConnected(handoff.connectionPhase, device: deviceB)
    }

    @ButtonHeistActor
    func testRuntimePhaseDropsConnectionHandleWhenDisconnecting() async {
        let handoff = TheHandoff()
        let mock = connectPendingMockHandoff(handoff)
        handoff.setupAutoReconnect(target: DeviceResolutionTarget(filter: nil))

        XCTAssertNotNil(handoff.connectionLifecycle.activeConnection)

        handoff.disconnect()

        XCTAssertNil(handoff.connectionLifecycle.activeConnection)
        XCTAssertEqual(mock.disconnectCount, 1)
        assertDisconnected(handoff.connectionPhase)
        XCTAssertNil(handoff.connectionLifecycle.targetForDisconnectedDevice(.init(host: "127.0.0.1", port: 1234)))
        XCTAssertEqual(handoff.send(.ping, requestId: nil), .failed(.notConnected))
    }

    @ButtonHeistActor
    func testAutoReconnectDirectEndpointDoesNotRequireDiscovery() async {
        let handoff = TheHandoff()
        handoff.reconnectInterval = 0
        handoff.reconnectMaxAttempts = 2
        handoff.reconnectAttemptTimeout = 0.1
        let device = DiscoveredDevice.fromHostPort("127.0.0.1:1456")!
        let reconnected = expectation(description: "direct endpoint reconnected")

        var connectedIDs: [DiscoveryDeviceID] = []
        handoff.makeConnection = { device in
            connectedIDs.append(device.id)
            let connection = MockConnection()
            connection.connectEventsOverride = connectedIDs.count == 1
                ? [.connected, .disconnected(.serverClosed)]
                : [.connected]
            if connectedIDs.count == 2 {
                reconnected.fulfill()
            }
            return connection
        }

        handoff.setupAutoReconnect(target: DeviceResolutionTarget(filter: "127.0.0.1:1456"))
        handoff.connect(to: device)

        await fulfillment(of: [reconnected], timeout: 5)

        XCTAssertEqual(connectedIDs, [device.id, device.id])
        assertConnected(handoff.connectionPhase, device: device)
    }

    @ButtonHeistActor
    func testAutoReconnectAttemptDoesNotCancelOwnRunner() async {
        let handoff = TheHandoff()
        handoff.reconnectInterval = 0
        handoff.reconnectMaxAttempts = 3
        handoff.reconnectAttemptTimeout = 0.1
        let device = DiscoveredDevice.fromHostPort("127.0.0.1:1457")!
        let reconnected = expectation(description: "runner survived failed reconnect attempt")

        var connectionCount = 0
        handoff.makeConnection = { _ in
            connectionCount += 1
            let connection = MockConnection()
            switch connectionCount {
            case 1:
                connection.connectEventsOverride = [.connected, .disconnected(.serverClosed)]
            case 2:
                connection.connectEventsOverride = [.disconnected(.serverClosed)]
            default:
                connection.connectEventsOverride = [.connected]
                reconnected.fulfill()
            }
            return connection
        }

        handoff.setupAutoReconnect(target: DeviceResolutionTarget(filter: "127.0.0.1:1457"))
        handoff.connect(to: device)

        await fulfillment(of: [reconnected], timeout: 5)

        XCTAssertEqual(connectionCount, 3)
        assertConnected(handoff.connectionPhase, device: device)
    }

    @ButtonHeistActor
    func testAutoReconnectTimeoutDisconnectsAttemptBeforeRetry() async {
        let handoff = TheHandoff()
        handoff.reconnectInterval = 0
        handoff.reconnectMaxAttempts = 1
        handoff.reconnectAttemptTimeout = 0
        let device = DiscoveredDevice.fromHostPort("127.0.0.1:1458")!

        var connections: [MockConnection] = []
        handoff.makeConnection = { _ in
            let connection = MockConnection()
            connections.append(connection)
            connection.connectEventsOverride = connections.count == 1
                ? [.connected, .disconnected(.serverClosed)]
                : []
            return connection
        }

        handoff.setupAutoReconnect(target: DeviceResolutionTarget(filter: "127.0.0.1:1458"))
        handoff.connect(to: device)

        let timedOutAttemptDisconnected = await eventually(within: .seconds(1)) {
            connections.count >= 2 && connections[1].disconnectCount > 0
        }

        XCTAssertTrue(timedOutAttemptDisconnected, "Timed-out reconnect attempt must close before any later retry")
        XCTAssertFalse(handoff.connectionLifecycle.isConnected)
        guard connections.indices.contains(1) else {
            XCTFail("Expected a reconnect attempt")
            return
        }

        connections[1].onEvent?(.connected)

        XCTAssertFalse(handoff.connectionLifecycle.isConnected, "Late success from a timed-out reconnect attempt must not resurrect stale state")
        handoff.disableAutoReconnect()
    }

    @ButtonHeistActor
    func testAutoReconnectRetriesOriginalDeviceWithoutDiscoverySelection() async {
        let handoff = TheHandoff()
        handoff.reconnectInterval = 0
        handoff.reconnectMaxAttempts = 1
        handoff.reconnectAttemptTimeout = 0.1
        let originalDevice = DiscoveredDevice(
            id: "old-service",
            name: "Checkout#old",
            endpoint: .service(name: "old-service", type: "_buttonheist._tcp", domain: "local."),
            installationId: "old-installation"
        )
        let differentDeviceMatchingFilter = DiscoveredDevice(
            id: "new-service",
            name: "Checkout#new",
            endpoint: .service(name: "new-service", type: "_buttonheist._tcp", domain: "local."),
            installationId: "new-installation"
        )
        let gaveUp = expectation(description: "reconnect reports terminal failure")

        let mockDiscovery = MockDiscovery()
        mockDiscovery.discoveredDevices = [differentDeviceMatchingFilter]
        handoff.makeDiscovery = { mockDiscovery }
        handoff.startDiscovery()

        var connectedIDs: [DiscoveryDeviceID] = []
        handoff.makeConnection = { device in
            connectedIDs.append(device.id)
            let connection = MockConnection()
            connection.connectEventsOverride = [.connected, .disconnected(.serverClosed)]
            return connection
        }
        handoff.onStatus = { message in
            if message.contains("Auto-reconnect gave up") {
                gaveUp.fulfill()
            }
        }

        handoff.setupAutoReconnect(target: DeviceResolutionTarget(filter: "Checkout"))
        handoff.connect(to: originalDevice)

        await fulfillment(of: [gaveUp], timeout: 5)

        XCTAssertEqual(connectedIDs, [originalDevice.id, originalDevice.id])
        assertFailed(
            handoff.connectionPhase,
            failure: .connectionFailed(
                "Auto-reconnect gave up after 1 attempts to \(originalDevice.name). Retry the connection or choose a new target."
            )
        )
    }

    func testAutoReconnectRecoveryPolicyUsesFixedJitterAndNamesTerminalFailure() {
        let policy = AutoReconnectRecoveryPolicy(maxAttempts: 3, baseInterval: 2)

        let sleepDurations = (0..<100).map { _ in policy.sleepDuration() }
        XCTAssertTrue(sleepDurations.allSatisfy { 2...2.4 ~= $0 })
        XCTAssertEqual(
            policy.terminalFailureMessage(targetDisplayName: "Checkout#old"),
            "Auto-reconnect gave up after 3 attempts to Checkout#old. Retry the connection or choose a new target."
        )
    }

}
