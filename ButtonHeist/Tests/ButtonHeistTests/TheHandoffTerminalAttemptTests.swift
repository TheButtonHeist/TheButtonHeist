import ButtonHeistTestSupport
import Foundation
import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

final class TheHandoffTerminalAttemptTests: XCTestCase {

    @ButtonHeistActor
    func testTerminalAttemptIgnoresLateRequestScopedError() async {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let serverError = ServerError(kind: .general, message: "connection failed")
        let mock = MockConnection()
        mock.connectEventsOverride = []
        handoff.makeConnection = { _ in mock }

        var receivedMessage: ServerMessage?
        var receivedRequestID: RequestID?
        handoff.onServerMessage = { message, requestID in
            receivedMessage = message
            receivedRequestID = requestID
        }

        handoff.connect(to: device)
        mock.onEvent?(.connected)
        mock.onEvent?(.message(
            .error(serverError),
            requestId: nil
        ))
        assertFailed(handoff.connectionPhase, failure: .serverFailure(serverError))

        mock.onEvent?(.message(
            .error(ServerError(kind: .general, message: "request failed")),
            requestId: "request-1"
        ))

        XCTAssertNil(receivedMessage)
        XCTAssertNil(receivedRequestID)
        assertFailed(handoff.connectionPhase, failure: .serverFailure(serverError))
    }

    @ButtonHeistActor
    func testTerminalAttemptIgnoresLateRequestScopedObservationPayloads() async {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let serverError = ServerError(kind: .general, message: "connection failed")
        let mock = MockConnection()
        mock.connectEventsOverride = []
        handoff.makeConnection = { _ in mock }

        var receivedMessages: [(message: ServerMessage, requestID: RequestID?)] = []
        handoff.onServerMessage = { message, requestID in
            receivedMessages.append((message, requestID))
        }

        handoff.connect(to: device)
        mock.onEvent?(.connected)
        mock.onEvent?(.message(
            .error(serverError),
            requestId: nil
        ))
        assertFailed(handoff.connectionPhase, failure: .serverFailure(serverError))

        let interface = makeTestInterface(
            elements: [makeTestHeistElement(label: "Title")],
            timestamp: Date(timeIntervalSince1970: 100)
        )
        mock.onEvent?(.message(
            .interface(interface),
            requestId: "interface-1"
        ))

        let screen = ScreenPayload(
            pngData: "base64png",
            width: 390,
            height: 844,
            timestamp: Date(timeIntervalSince1970: 200),
            interface: makeTestInterface(elements: [], timestamp: Date(timeIntervalSince1970: 200))
        )
        mock.onEvent?(.message(
            .screen(screen),
            requestId: "screen-1"
        ))

        XCTAssertTrue(receivedMessages.isEmpty)
        assertFailed(handoff.connectionPhase, failure: .serverFailure(serverError))
    }

    @ButtonHeistActor
    func testTerminalAttemptIgnoresStateMutatingRequestScopedMessages() async {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let serverError = ServerError(kind: .general, message: "connection failed")
        let mock = MockConnection()
        mock.connectEventsOverride = []
        handoff.makeConnection = { _ in mock }

        handoff.connect(to: device)
        mock.onEvent?(.connected)
        mock.onEvent?(.message(
            .error(serverError),
            requestId: nil
        ))

        mock.onEvent?(.message(
            .info(TheFenceFixtures.testServerInfo),
            requestId: "request-1"
        ))

        XCTAssertNil(handoff.connectionLifecycle.serverInfo)
        assertFailed(handoff.connectionPhase, failure: .serverFailure(serverError))
    }

    @ButtonHeistActor
    func testWaitForConnectionResultPreservesDisconnectCause() async {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let mock = MockConnection()
        mock.connectEventsOverride = [
            .disconnected(.missingToken),
        ]
        handoff.makeConnection = { _ in mock }

        handoff.connect(to: device)

        do {
            try await handoff.waitForConnectionResult(timeout: 30)
            XCTFail("Expected disconnect failure")
        } catch let error as HandoffConnectionError {
            guard case .disconnected(let reason) = error else {
                return XCTFail("Expected .disconnected, got \(error)")
            }
            XCTAssertEqual(reason, .missingToken)
            XCTAssertEqual(error.failureDetails.code, .tlsMissingToken)
            XCTAssertEqual(error.failureCode, KnownFailureCode.tlsMissingToken.rawValue)
            XCTAssertEqual(error.phase, .tls)
            XCTAssertFalse(error.retryable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @ButtonHeistActor
    func testSendAfterLocalDisconnectFailsTyped() async {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let mock = MockConnection()
        handoff.makeConnection = { _ in mock }
        handoff.connect(to: device)
        handoff.disconnect()

        let outcome = handoff.send(.ping, requestId: "late")

        guard case .failed(.notConnected) = outcome else {
            return XCTFail("Expected notConnected send failure, got \(outcome)")
        }
        XCTAssertTrue(mock.sent.isEmpty, "Local disconnect must close the send path")
    }
}
