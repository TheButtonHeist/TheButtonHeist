import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

final class TheHandoffLifecycleStateTests: XCTestCase {

    @ButtonHeistActor
    func testInitialState() async {
        let handoff = TheHandoff()

        XCTAssertTrue(handoff.discovery.discoveredDevices.isEmpty)
        XCTAssertNil(handoff.connectionLifecycle.connectedDevice)
        XCTAssertNil(handoff.connectionLifecycle.serverInfo)
        XCTAssertFalse(handoff.discovery.isReady)
        assertDisconnected(handoff.connectionPhase)
    }

    @ButtonHeistActor
    func testTransportReadyHookDoesNotMarkHandoffConnected() async {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let mock = MockConnection()
        mock.connectEventsOverride = []
        handoff.makeConnection = { _ in mock }

        handoff.connect(to: device)
        mock.onTransportReady?()

        assertConnecting(handoff.connectionPhase, device: device)
        XCTAssertNil(handoff.connectionLifecycle.connectedDevice)
    }

    @ButtonHeistActor
    func testDisconnectClearsConnectedStateAndClosesTransport() async {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let mock = MockConnection()
        mock.serverInfo = ServerInfo(
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
        handoff.makeConnection = { _ in mock }

        handoff.connect(to: device)
        XCTAssertEqual(handoff.connectionLifecycle.connectedDevice, device)
        XCTAssertEqual(handoff.connectionLifecycle.serverInfo?.appName, "TestApp")
        XCTAssertEqual(mock.disconnectCount, 0)

        handoff.disconnect()

        XCTAssertNil(handoff.connectionLifecycle.connectedDevice)
        XCTAssertNil(handoff.connectionLifecycle.serverInfo)
        assertDisconnected(handoff.connectionPhase)
        XCTAssertEqual(mock.disconnectCount, 1)
    }

    @ButtonHeistActor
    func testStopDiscoveryClearsFlag() async {
        let handoff = TheHandoff()

        handoff.startDiscovery()
        handoff.stopDiscovery()

        XCTAssertFalse(handoff.discovery.isReady)
    }

    @ButtonHeistActor
    func testServerErrorSetsConnectionPhaseFailed() async {
        let handoff = TheHandoff()
        let serverError = ServerError(kind: .general, message: "something went wrong")

        handoff.handleServerMessage(.error(serverError), requestId: nil)

        assertFailed(handoff.connectionPhase, failure: .serverFailure(serverError))
        XCTAssertEqual(handoff.connectionLifecycle.diagnosticFailure, .serverFailure(serverError))
    }
}
