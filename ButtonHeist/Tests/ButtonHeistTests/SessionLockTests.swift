import ButtonHeistTestSupport
import XCTest
import TheScore
@_spi(ButtonHeistTooling) @testable import ButtonHeist

/// Tests for session locking behavior using direct message injection.
final class SessionLockTests: XCTestCase {
    // MARK: - Tests

    @ButtonHeistActor
    func testSessionLockedEmitsPayloadWithoutDisconnectingTransport() async throws {
        let conn = DeviceConnection(device: TheFenceFixtures.testDevice)
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
        try conn.handleMessage(testResponseEnvelopeData(.sessionLocked(payload)))

        assertDeviceConnectionConnected(conn)
        XCTAssertEqual(receivedPayload?.message, payload.message)
        XCTAssertEqual(receivedPayload?.activeConnections, payload.activeConnections)
        XCTAssertFalse(disconnected)
    }

}
