import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

final class TheHandoffKeepaliveStateTests: XCTestCase {

    @ButtonHeistActor
    func testPongResetsKeepaliveCounterAndForwardsRequestScopedPong() async {
        let handoff = TheHandoff()
        _ = connectMockHandoff(handoff)
        var forwarded: [(ServerMessage, RequestID?)] = []
        handoff.onServerMessage = { message, requestId in
            forwarded.append((message, requestId))
        }

        XCTAssertEqual(handoff.tickKeepalive(), 1)
        XCTAssertEqual(handoff.tickKeepalive(), 2)

        handoff.handleServerMessage(.pong(PongPayload(bundleIdentifier: "com.buttonheist.test")), requestId: "ping-1")

        XCTAssertEqual(handoff.connectionLifecycle.missedPongCount, 0)
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertEqual(forwarded.first?.1, "ping-1")
        guard case .pong = forwarded.first?.0 else {
            return XCTFail("Expected request-scoped pong to be forwarded")
        }
    }

    @ButtonHeistActor
    func testConnectionEventForwardsTypedSendFailureRequestID() async {
        let handoff = TheHandoff()
        let connection = connectMockHandoff(handoff)
        let requestID: RequestID = "request-1"
        var received: (DeviceSendFailure, RequestID?)?
        handoff.onSendFailure = { failure, eventRequestID in
            received = (failure, eventRequestID)
        }

        connection.onEvent?(.sendFailed(.notConnected, requestId: requestID))

        XCTAssertEqual(received?.0, .notConnected)
        XCTAssertEqual(received?.1, requestID)
    }

    @ButtonHeistActor
    func testKeepaliveToleratesDebuggerLengthMissedPongGapThenRecovers() async {
        let handoff = TheHandoff()
        _ = connectMockHandoff(handoff)

        let sixtySecondPauseTicks = 12
        XCTAssertLessThan(sixtySecondPauseTicks, TheHandoff.maxMissedPongs)

        for count in 1...sixtySecondPauseTicks {
            XCTAssertEqual(handoff.tickKeepalive(), count)
            assertConnected(handoff.connectionPhase)
        }

        handoff.handleServerMessage(.pong(PongPayload(bundleIdentifier: "com.buttonheist.test")), requestId: nil)

        XCTAssertEqual(handoff.connectionLifecycle.missedPongCount, 0)
        XCTAssertEqual(handoff.tickKeepalive(), 1)
        assertConnected(handoff.connectionPhase)
    }

    @ButtonHeistActor
    func testStaleKeepaliveAttemptCannotDisconnectReplacementSession() async {
        let handoff = TheHandoff()
        let firstDevice = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let firstMock = connectMockHandoff(handoff, device: firstDevice)
        guard case .connected(let firstSession) = handoff.connectionPhase else {
            return XCTFail("Expected first session to connect")
        }

        let secondDevice = DiscoveredDevice(host: "127.0.0.1", port: 4321)
        let secondMock = MockConnection()
        handoff.makeConnection = { _ in secondMock }
        handoff.connect(to: secondDevice)

        XCTAssertEqual(firstMock.disconnectCount, 1)
        assertConnected(handoff.connectionPhase, device: secondDevice)

        XCTAssertEqual(handoff.tickKeepalive(expectedAttemptID: firstSession.attemptID), 0)
        handoff.forceDisconnect(expectedAttemptID: firstSession.attemptID)

        XCTAssertEqual(secondMock.disconnectCount, 0)
        XCTAssertTrue(secondMock.sent.isEmpty)
        assertConnected(handoff.connectionPhase, device: secondDevice)
    }

    @ButtonHeistActor
    func testMultipleDisconnectsSafe() async {
        let handoff = TheHandoff()

        handoff.disconnect()
        handoff.disconnect()
        handoff.disconnect()

        assertDisconnected(handoff.connectionPhase)
    }
}
