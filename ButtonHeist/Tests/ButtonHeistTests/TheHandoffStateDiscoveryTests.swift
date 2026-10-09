import ButtonHeistTestSupport
import Network
import os
import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

final class TheHandoffStateDiscoveryTests: XCTestCase {
    // MARK: - Discovery (existing)

    @ButtonHeistActor
    func testDiscoveryDevicesComeDirectlyFromCurrentSession() async {
        let handoff = TheHandoff()
        let mockDiscovery = MockDiscovery()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        handoff.makeDiscovery = { mockDiscovery }

        handoff.startDiscovery()
        mockDiscovery.discoveredDevices = [device]

        XCTAssertEqual(handoff.discoveryLifecycle.discoveredDevices, [device])
    }

    @ButtonHeistActor
    func testStoppedDiscoveryIgnoresStaleCallbacks() async {
        let handoff = TheHandoff()
        let staleDevice = DiscoveredDevice(
            id: "stale-service",
            name: "Stale#one",
            endpoint: .service(name: "stale-service", type: "_buttonheist._tcp", domain: "local.")
        )
        let mockDiscovery = MockDiscovery()
        handoff.makeDiscovery = { mockDiscovery }

        var foundDevices: [DiscoveredDevice] = []
        handoff.onDeviceFound = { foundDevices.append($0) }

        handoff.startDiscovery()
        XCTAssertTrue(handoff.discoveryLifecycle.isDiscovering)

        handoff.stopDiscovery()
        mockDiscovery.discoveredDevices = [staleDevice]
        mockDiscovery.onEvent?(.stateChanged(isReady: true))
        mockDiscovery.onEvent?(.found(staleDevice))

        XCTAssertFalse(handoff.discoveryLifecycle.isDiscovering)
        XCTAssertEqual(handoff.discoveryLifecycle.discoveredDevices, [])
        XCTAssertEqual(foundDevices, [])
    }

    @ButtonHeistActor
    func testDiscoveryFailureClearsDevicesAndStopsSession() async {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(
            id: "failed-service",
            name: "Failed#one",
            endpoint: .service(name: "failed-service", type: "_buttonheist._tcp", domain: "local.")
        )
        let mockDiscovery = MockDiscovery()
        mockDiscovery.discoveredDevices = [device]
        handoff.makeDiscovery = { mockDiscovery }

        handoff.startDiscovery()
        XCTAssertTrue(handoff.discoveryLifecycle.isDiscovering)
        XCTAssertEqual(handoff.discoveryLifecycle.discoveredDevices, [device])

        mockDiscovery.onEvent?(.failed(.noDeviceFound))

        XCTAssertFalse(handoff.discoveryLifecycle.isDiscovering)
        XCTAssertEqual(handoff.discoveryLifecycle.discoveredDevices, [])
        XCTAssertFalse(handoff.discoveryLifecycle.hasDiscoverySession)
        XCTAssertEqual(mockDiscovery.stopCount, 1)
    }

    @ButtonHeistActor
    func testReplacedDiscoveryIgnoresCallbacksFromPreviousSession() async {
        let handoff = TheHandoff()
        let staleDevice = DiscoveredDevice(
            id: "stale-service",
            name: "Stale#one",
            endpoint: .service(name: "stale-service", type: "_buttonheist._tcp", domain: "local.")
        )
        let currentDevice = DiscoveredDevice(
            id: "current-service",
            name: "Current#one",
            endpoint: .service(name: "current-service", type: "_buttonheist._tcp", domain: "local.")
        )
        let staleDiscovery = MockDiscovery()
        let currentDiscovery = MockDiscovery()
        currentDiscovery.discoveredDevices = [currentDevice]
        var discoveries = [staleDiscovery, currentDiscovery]
        handoff.makeDiscovery = { discoveries.removeFirst() }

        var foundDevices: [DiscoveredDevice] = []
        handoff.onDeviceFound = { foundDevices.append($0) }

        handoff.startDiscovery()
        handoff.stopDiscovery()
        handoff.startDiscovery()
        staleDiscovery.discoveredDevices = [staleDevice]
        staleDiscovery.onEvent?(.stateChanged(isReady: false))
        staleDiscovery.onEvent?(.found(staleDevice))

        XCTAssertTrue(handoff.discoveryLifecycle.isDiscovering)
        XCTAssertEqual(handoff.discoveryLifecycle.discoveredDevices, [currentDevice])
        XCTAssertEqual(foundDevices, [currentDevice])
    }

    @ButtonHeistActor
    func testDeviceDiscoveryStartTwiceDoesNotReplaceActiveBrowser() async {
        let browser = FakeDiscoveryBrowser()
        let discovery = DeviceDiscovery(
            reachabilityValidationInterval: 60,
            makeBrowser: { browser }
        )

        discovery.start()
        discovery.start()

        XCTAssertEqual(browser.startCount, 1)
        XCTAssertEqual(browser.cancelCount, 0)
    }

    @ButtonHeistActor
    func testDeviceDiscoveryRepeatedStopInvalidatesCallbacksAndReleasesBrowsers() async {
        weak var browserProbe: FakeDiscoveryBrowser?

        for _ in 0..<3 {
            do {
                let browser = FakeDiscoveryBrowser()
                browserProbe = browser
                let discovery = DeviceDiscovery(
                    reachabilityValidationInterval: 60,
                    makeBrowser: { browser }
                )

                discovery.start()
                XCTAssertTrue(browser.hasInstalledCallbacks)
                discovery.stop()

                XCTAssertEqual(browser.cancelCount, 1)
                XCTAssertFalse(browser.hasInstalledCallbacks)
            }
            XCTAssertNil(browserProbe)
        }
    }

    @ButtonHeistActor
    func testDeviceDiscoveryDeliversEventsAtBufferCapacity() async {
        let browser = FakeDiscoveryBrowser()
        let discovery = DeviceDiscovery(
            reachabilityValidationInterval: 60,
            makeBrowser: { browser }
        )
        var deliveredStateCount = 0
        var failures: [HandoffConnectionError] = []
        let capacityDelivered = HandoffTestSignal()
        discovery.onEvent = { event in
            switch event {
            case .stateChanged:
                deliveredStateCount += 1
                if deliveredStateCount == DeviceDiscoveryEventStream.bufferLimit {
                    capacityDelivered.signal()
                }
            case .failed(let failure):
                failures.append(failure)
            case .found, .lost:
                break
            }
        }

        discovery.start()
        for _ in 0..<DeviceDiscoveryEventStream.bufferLimit {
            browser.emit(.waiting)
        }
        await capacityDelivered.wait()

        XCTAssertEqual(deliveredStateCount, DeviceDiscoveryEventStream.bufferLimit)
        XCTAssertEqual(failures, [])
        XCTAssertEqual(browser.cancelCount, 0)
        discovery.stop()
    }

    @ButtonHeistActor
    func testDeviceDiscoveryOverflowInvalidatesBufferedEventsAndFailsOnce() async {
        let browser = FakeDiscoveryBrowser()
        let discovery = DeviceDiscovery(
            reachabilityValidationInterval: 60,
            makeBrowser: { browser }
        )
        var deliveredStateCount = 0
        var failures: [HandoffConnectionError] = []
        let terminalDelivered = HandoffTestSignal()
        discovery.onEvent = { event in
            switch event {
            case .stateChanged:
                deliveredStateCount += 1
            case .failed(let failure):
                failures.append(failure)
                terminalDelivered.signal()
            case .found, .lost:
                break
            }
        }

        discovery.start()
        for _ in 0...DeviceDiscoveryEventStream.bufferLimit {
            browser.emit(.waiting)
        }
        for _ in 0..<DeviceDiscoveryEventStream.bufferLimit {
            browser.emit(.ready)
        }

        XCTAssertEqual(deliveredStateCount, 0)
        XCTAssertEqual(browser.cancelCount, 1)

        await terminalDelivered.wait()

        XCTAssertEqual(deliveredStateCount, 0)
        XCTAssertEqual(failures, [
            .discoveryBacklogOverflow(capacity: DeviceDiscoveryEventStream.bufferLimit),
        ])
        XCTAssertEqual(discovery.discoveredDevices, [])
        XCTAssertEqual(browser.cancelCount, 1)
    }

    @ButtonHeistActor
    func testDeviceDiscoveryTerminalFailureClearsAndFails() async {
        let browser = FakeDiscoveryBrowser()
        let discovery = DeviceDiscovery(
            reachabilityValidationInterval: 60,
            makeBrowser: { browser }
        )
        var states: [Bool] = []
        var failures: [HandoffConnectionError] = []
        let terminalDelivered = HandoffTestSignal()
        discovery.onEvent = { event in
            switch event {
            case .stateChanged(let isReady):
                states.append(isReady)
            case .failed(let failure):
                failures.append(failure)
                terminalDelivered.signal()
            case .found, .lost:
                break
            }
        }

        discovery.start()
        browser.emit(.ready)
        browser.emit(.failed("boom"))
        await terminalDelivered.wait()

        XCTAssertEqual(states, [true])
        XCTAssertEqual(failures, [.connectionFailed("Bonjour discovery failed: boom")])
        XCTAssertEqual(discovery.discoveredDevices, [])
        XCTAssertEqual(browser.cancelCount, 1)
    }

    @ButtonHeistActor
    func testDeviceDiscoveryIgnoresStaleCallbacksAfterOverflowAndRestart() async {
        let firstBrowser = FakeDiscoveryBrowser()
        let secondBrowser = FakeDiscoveryBrowser()
        var browsers = [firstBrowser, secondBrowser]
        let discovery = DeviceDiscovery(
            reachabilityValidationInterval: 60,
            makeBrowser: { browsers.removeFirst() }
        )
        var readyStateCount = 0
        var failures: [HandoffConnectionError] = []
        let overflowDelivered = HandoffTestSignal()
        let currentReadyDelivered = HandoffTestSignal()
        discovery.onEvent = { event in
            switch event {
            case .stateChanged(let isReady):
                if isReady {
                    readyStateCount += 1
                    currentReadyDelivered.signal()
                }
            case .failed(let failure):
                failures.append(failure)
                overflowDelivered.signal()
            case .found, .lost:
                break
            }
        }

        discovery.start()
        for _ in 0...DeviceDiscoveryEventStream.bufferLimit {
            firstBrowser.emit(.waiting)
        }
        await overflowDelivered.wait()

        discovery.start()
        firstBrowser.emit(.ready)
        secondBrowser.emit(.ready)
        await currentReadyDelivered.wait()

        XCTAssertEqual(firstBrowser.cancelCount, 1)
        XCTAssertEqual(secondBrowser.startCount, 1)
        XCTAssertEqual(secondBrowser.cancelCount, 0)
        XCTAssertEqual(readyStateCount, 1)
        XCTAssertEqual(failures, [
            .discoveryBacklogOverflow(capacity: DeviceDiscoveryEventStream.bufferLimit),
        ])
        discovery.stop()
    }

    @ButtonHeistActor
    func testDiscoverReachableDevicesPreservesExistingDiscoverySession() async {
        let reachableDevice = DiscoveredDevice(
            id: "reachable-device",
            name: "ReachableApp#live",
            endpoint: .hostPort(host: "::1", port: 1)
        )
        let handoff = TheHandoff()
        let mockDiscovery = MockDiscovery()
        mockDiscovery.discoveredDevices = [reachableDevice]
        handoff.makeDiscovery = { mockDiscovery }

        let previousProvider = makeReachabilityConnection
        makeReachabilityConnection = { device in
            let connection = MockConnection()
            connection.emitTransportReadyOnConnect = true
            if device.id == reachableDevice.id {
                connection.responseScript = { message in
                    switch message {
                    case .status:
                        return .status(StatusPayload(
                            identity: StatusIdentity(
                                appName: "ReachableApp",
                                bundleIdentifier: "com.test.reachable",
                                appBuild: "1",
                                deviceName: "Simulator",
                                systemVersion: "18.5",
                                buttonHeistVersion: "5.0.0"
                            ),
                            session: StatusSession(active: false, watchersAllowed: false, activeConnections: 0)
                        ))
                    default:
                        XCTFail("Unexpected probe message: \(message)")
                        return .error(ServerError(kind: .general, message: "unexpected"))
                    }
                }
            }
            return connection
        }
        defer { makeReachabilityConnection = previousProvider }

        handoff.startDiscovery()
        XCTAssertTrue(handoff.discoveryLifecycle.isDiscovering)
        XCTAssertEqual(handoff.discoveryLifecycle.discoveredDevices, [reachableDevice])

        let devices = await handoff.discoverReachableDevices(timeout: 0.3)

        XCTAssertEqual(devices, [reachableDevice])
        XCTAssertTrue(handoff.discoveryLifecycle.isDiscovering)
        XCTAssertEqual(handoff.discoveryLifecycle.discoveredDevices, [reachableDevice])
        XCTAssertEqual(mockDiscovery.startCount, 1)
        XCTAssertEqual(mockDiscovery.stopCount, 0)
    }

    @ButtonHeistActor
    func testConnectWithDiscoveryDefaultSelectsSingleDiscoveredDevice() async throws {
        let discoveredDevice = DiscoveredDevice(
            id: "reachable-device",
            name: "AccessibilityTestApp#live",
            endpoint: .hostPort(host: "::1", port: 2)
        )

        let handoff = TheHandoff()
        let mockDiscovery = MockDiscovery()
        mockDiscovery.discoveredDevices = [discoveredDevice]
        handoff.makeDiscovery = { mockDiscovery }

        var connectedDeviceID: DiscoveryDeviceID?
        handoff.makeConnection = { device in
            connectedDeviceID = device.id
            let connection = MockConnection()
            connection.serverInfo = ServerInfo(
                appName: "AccessibilityTestApp",
                bundleIdentifier: "com.buttonheist.testapp",
                deviceName: "iPhone 16 Pro",
                systemVersion: "26.1",
                screenWidth: 402,
                screenHeight: 874,
                instanceId: "accessibility-session",
                instanceIdentifier: "accessibility",
                listeningPort: 49152,
                tlsActive: true
            )
            return connection
        }

        try await handoff.connect(target: DeviceResolutionTarget(filter: nil), timeout: 0.5)

        XCTAssertEqual(connectedDeviceID, discoveredDevice.id)
        XCTAssertEqual(handoff.connectionLifecycle.connectedDevice, discoveredDevice)
        XCTAssertTrue(handoff.connectionLifecycle.isConnected)
    }

    @ButtonHeistActor
    func testConnectWithDiscoveryDoesNotProbeReachabilityBeforeOpeningConnection() async throws {
        let device = DiscoveredDevice(
            id: "single-device",
            name: "AccessibilityTestApp#single",
            endpoint: .hostPort(host: "::1", port: 3)
        )

        let handoff = TheHandoff()
        let mockDiscovery = MockDiscovery()
        mockDiscovery.discoveredDevices = [device]
        handoff.makeDiscovery = { mockDiscovery }

        handoff.makeConnection = { _ in
            let connection = MockConnection()
            connection.serverInfo = ServerInfo(
                appName: "AccessibilityTestApp",
                bundleIdentifier: "com.buttonheist.testapp",
                deviceName: "iPhone 16 Pro",
                systemVersion: "26.1",
                screenWidth: 402,
                screenHeight: 874,
                instanceId: "accessibility-session",
                instanceIdentifier: "accessibility",
                listeningPort: 49152,
                tlsActive: true
            )
            return connection
        }

        let previousProvider = makeReachabilityConnection
        makeReachabilityConnection = { _ in
            XCTFail("discovered target resolution should not probe reachability")
            return MockConnection()
        }
        defer { makeReachabilityConnection = previousProvider }

        try await handoff.connect(target: DeviceResolutionTarget(filter: nil), timeout: 0.5)

        XCTAssertEqual(handoff.connectionLifecycle.connectedDevice, device)
        XCTAssertTrue(handoff.connectionLifecycle.isConnected)
    }

    @ButtonHeistActor
    func testConnectWithDiscoveryWithoutFilterThrowsWhenMultipleDiscoveredDevicesExist() async throws {
        let firstDevice = DiscoveredDevice(
            id: "first-device",
            name: "AccessibilityTestApp#first",
            endpoint: .hostPort(host: "::1", port: 4)
        )
        let secondDevice = DiscoveredDevice(
            id: "second-device",
            name: "AccessibilityTestApp#second",
            endpoint: .hostPort(host: "::1", port: 5)
        )

        let handoff = TheHandoff()
        let mockDiscovery = MockDiscovery()
        mockDiscovery.discoveredDevices = [firstDevice, secondDevice]
        handoff.makeDiscovery = { mockDiscovery }

        do {
            try await handoff.connect(target: DeviceResolutionTarget(filter: nil), timeout: 0.5)
            XCTFail("Expected ambiguousDeviceTarget to be thrown")
        } catch let error as HandoffConnectionError {
            guard case .ambiguousDeviceTarget(let filter, let matches) = error else {
                return XCTFail("Expected ambiguousDeviceTarget, got \(error)")
            }
            XCTAssertEqual(filter, "(none)")
            XCTAssertEqual(matches, [firstDevice.name, secondDevice.name])
        }
    }

    @ButtonHeistActor
    func testConnectWithDiscoveryFailureReplacesExistingSession() async throws {
        let existingDevice = DiscoveredDevice(
            id: "existing-device",
            name: "AccessibilityTestApp#existing",
            endpoint: .hostPort(host: "::1", port: 6)
        )
        let firstDevice = DiscoveredDevice(
            id: "replacement-first",
            name: "AccessibilityTestApp#first",
            endpoint: .hostPort(host: "::1", port: 7)
        )
        let secondDevice = DiscoveredDevice(
            id: "replacement-second",
            name: "AccessibilityTestApp#second",
            endpoint: .hostPort(host: "::1", port: 8)
        )

        let handoff = TheHandoff()
        let existingConnection = MockConnection()
        handoff.makeConnection = { _ in existingConnection }

        var disconnectReasons: [DisconnectReason] = []
        handoff.onConnectionStateChanged = { _ in
            if case .disconnected(let reason) = handoff.connectionLifecycle.diagnosticFailure {
                disconnectReasons.append(reason)
            }
        }

        handoff.connect(to: existingDevice)
        assertConnected(handoff.connectionPhase, device: existingDevice)
        XCTAssertTrue(existingConnection.isConnected)

        let mockDiscovery = MockDiscovery()
        mockDiscovery.discoveredDevices = [firstDevice, secondDevice]
        handoff.makeDiscovery = { mockDiscovery }
        handoff.makeConnection = { _ in
            XCTFail("Discovery selection failed; no replacement connection should be opened")
            return MockConnection()
        }

        do {
            try await handoff.connect(target: DeviceResolutionTarget(filter: nil), timeout: 0.5)
            XCTFail("Expected ambiguousDeviceTarget to be thrown")
        } catch let error as HandoffConnectionError {
            guard case .ambiguousDeviceTarget(let filter, let matches) = error else {
                return XCTFail("Expected ambiguousDeviceTarget, got \(error)")
            }
            XCTAssertEqual(filter, "(none)")
            XCTAssertEqual(matches, [firstDevice.name, secondDevice.name])
        }

        XCTAssertFalse(existingConnection.isConnected)
        XCTAssertEqual(disconnectReasons, [.localDisconnect])
        assertDisconnected(handoff.connectionPhase)
        XCTAssertEqual(
            handoff.connectionLifecycle.diagnosticFailure,
            .ambiguousDeviceTarget(filter: "(none)", matches: [firstDevice.name, secondDevice.name])
        )
    }

    @ButtonHeistActor
    func testConnectWithDiscoverySuccessReplacesExistingSession() async throws {
        let existingDevice = DiscoveredDevice(
            id: "existing-device",
            name: "AccessibilityTestApp#existing",
            endpoint: .hostPort(host: "::1", port: 9)
        )
        let replacementDevice = DiscoveredDevice(
            id: "replacement-device",
            name: "AccessibilityTestApp#replacement",
            endpoint: .hostPort(host: "::1", port: 10)
        )

        let handoff = TheHandoff()
        let existingConnection = MockConnection()
        let replacementConnection = MockConnection()
        handoff.makeConnection = { device in
            switch device.id {
            case existingDevice.id:
                return existingConnection
            case replacementDevice.id:
                return replacementConnection
            default:
                XCTFail("Unexpected connection device: \(device)")
                return MockConnection()
            }
        }

        var disconnectReasons: [DisconnectReason] = []
        handoff.onConnectionStateChanged = { _ in
            if case .disconnected(let reason) = handoff.connectionLifecycle.diagnosticFailure {
                disconnectReasons.append(reason)
            }
        }

        handoff.connect(to: existingDevice)
        assertConnected(handoff.connectionPhase, device: existingDevice)
        XCTAssertTrue(existingConnection.isConnected)

        let mockDiscovery = MockDiscovery()
        mockDiscovery.discoveredDevices = [replacementDevice]
        handoff.makeDiscovery = { mockDiscovery }

        try await handoff.connect(target: DeviceResolutionTarget(filter: nil), timeout: 0.5)

        XCTAssertFalse(existingConnection.isConnected)
        XCTAssertTrue(replacementConnection.isConnected)
        XCTAssertEqual(disconnectReasons, [.localDisconnect])
        assertConnected(handoff.connectionPhase, device: replacementDevice)
        XCTAssertNil(handoff.connectionLifecycle.diagnosticFailure)
    }

}
