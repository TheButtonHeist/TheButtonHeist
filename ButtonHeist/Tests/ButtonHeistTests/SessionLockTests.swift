import XCTest
import Network
import TheScore
@_spi(ButtonHeistTooling) @testable import ButtonHeist

/// Tests for session locking behavior using direct message injection.
final class SessionLockTests: XCTestCase {

    private func makeDummyDevice() -> DiscoveredDevice {
        DiscoveredDevice(
            id: "mock",
            name: "MockApp#test",
            endpoint: DiscoveredDeviceEndpoint.hostPort(host: "::1", port: 1)
        )
    }

    private func encode(_ message: ServerMessage) throws -> Data {
        try JSONEncoder().encode(ResponseEnvelope(message: message))
    }

    // MARK: - Tests

    @ButtonHeistActor
    func testSessionLockedEmitsPayloadWithoutDisconnectingTransport() async throws {
        let conn = DeviceConnection(device: makeDummyDevice())
        conn.simulateConnected()

        var receivedPayload: SessionLockedPayload?
        var disconnected = false
        conn.onEvent = { event in
            switch event {
            case .message(.sessionLocked(let payload), _):
                receivedPayload = payload
            case .disconnected:
                disconnected = true
            default:
                break
            }
        }

        let payload = SessionLockedPayload(
            message: "Session held by another driver; owner driver id: driver-a; active connections: 1; remaining timeout: 5s.",
            activeConnections: 1
        )
        try conn.handleMessage(encode(.sessionLocked(payload)))

        assertDeviceConnectionConnected(conn)
        XCTAssertEqual(receivedPayload?.message, payload.message)
        XCTAssertEqual(receivedPayload?.activeConnections, payload.activeConnections)
        XCTAssertFalse(disconnected)
    }

}
