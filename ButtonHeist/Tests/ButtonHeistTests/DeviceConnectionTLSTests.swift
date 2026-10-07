import XCTest
import Network
import ButtonHeistSupport
import ButtonHeistTestSupport
import TheScore
@_spi(ButtonHeistTooling) @testable import ButtonHeist

final class DeviceConnectionTLSTests: XCTestCase {
    private func makeDummyDevice() -> DiscoveredDevice {
        DiscoveredDevice(
            id: "test",
            name: "TestApp#abc",
            endpoint: DiscoveredDeviceEndpoint.service(name: "test", type: "_test._tcp", domain: "local.")
        )
    }

    @ButtonHeistActor
    private func makeConnectedConnection() -> (DeviceConnection, NWConnection) {
        let transportConnection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let connection = DeviceConnection(device: makeDummyDevice())
        connection.runtimePhase = .connected(DeviceConnection.RuntimeSession(connection: transportConnection))
        return (connection, transportConnection)
    }

    // MARK: - DisconnectReason

    func testAllDisconnectReasonsHaveDescriptions() {
        let reasons: [DisconnectReason] = [
            .networkError(NetworkTransportFailure(.posix(.ECONNRESET))),
            .bufferOverflow,
            .eventBacklogOverflow(maxEvents: 512),
            .serverClosed,
            .authFailed("bad token"),
            .sessionLocked("locked"),
            .buttonHeistVersionMismatch(serverVersion: "0.5.0", clientVersion: "0.6.0"),
            .localDisconnect,
            .missingToken,
        ]

        for reason in reasons {
            XCTAssertNotNil(reason.errorDescription, "Missing description for \(reason)")
            XCTAssertFalse(reason.errorDescription!.isEmpty, "Empty description for \(reason)")
        }
    }

    func testDisconnectReasonTaxonomy() {
        let cases: [(DisconnectReason, KnownFailureCode, FailurePhase, Bool)] = [
            (.networkError(NetworkTransportFailure(.posix(.ECONNRESET))), .transportNetworkError, .transport, true),
            (.bufferOverflow, .transportBufferOverflow, .transport, false),
            (.eventBacklogOverflow(maxEvents: 512), .transportEventBacklogOverflow, .transport, true),
            (.serverClosed, .transportServerClosed, .transport, true),
            (.authFailed("bad token"), .authFailed, .authentication, false),
            (.sessionLocked("busy"), .sessionLocked, .session, true),
            (
                .buttonHeistVersionMismatch(serverVersion: "0.5.0", clientVersion: "0.6.0"),
                .protocolMismatch, .protocolNegotiation, false
            ),
            (.localDisconnect, .clientLocalDisconnect, .client, false),
            (.missingToken, .tlsMissingToken, .tls, false),
        ]

        for (reason, knownCode, phase, retryable) in cases {
            XCTAssertEqual(reason.failureDetails.code, knownCode)
            XCTAssertEqual(reason.failureCode, knownCode.rawValue)
            XCTAssertEqual(reason.phase, phase)
            XCTAssertEqual(reason.retryable, retryable)
            if knownCode != .clientLocalDisconnect, knownCode != .authFailed {
                XCTAssertNotNil(reason.hint, "Expected hint for \(reason)")
            }
        }
    }

    func testDisconnectReasonConnectionFailureMessagePreservesCause() {
        let message = DisconnectReason.missingToken.connectionFailureMessage

        XCTAssertTrue(message.contains("connection failed in tls"))
        XCTAssertTrue(message.contains("observed No token available for TLS pre-shared-key authentication"))
        XCTAssertTrue(message.contains("Set BUTTONHEIST_TOKEN"))
    }

    func testExplicitTokenAuthFailureHintDoesNotSuggestUIApproval() {
        let reason = DisconnectReason.authFailed(
            "Invalid token. Retry with the configured token.",
            hint: "Retry with the configured token."
        )

        XCTAssertEqual(reason.hint, "Retry with the configured token.")
        XCTAssertTrue(reason.connectionFailureMessage.contains("Retry with the configured token."))
        XCTAssertFalse(reason.connectionFailureMessage.contains("Retry without a token"))
    }

    func testDeviceTransportSendFailurePreservesNetworkDiagnosticReason() {
        let diagnostic = NetworkTransportFailure(.posix(.ECONNRESET))
        let failure = DeviceSendFailure.transportFailed(diagnostic)

        guard case .transportFailed(let capturedDiagnostic) = failure else {
            return XCTFail("Expected typed transport failure, got \(failure)")
        }
        XCTAssertEqual(capturedDiagnostic.reason, .posix(code: Int(POSIXErrorCode.ECONNRESET.rawValue)))
        XCTAssertTrue(capturedDiagnostic.description.contains("posix"))
        XCTAssertTrue(failure.localizedDescription.contains("posix"))
    }

    func testConnectionEventStreamDrainsAcceptedCallbacksBeforeOverflowTermination() async {
        let stream = DeviceConnectionEventStream()
        let sessionID = UUID()
        let connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)

        for _ in 0..<DeviceConnectionEventStream.bufferLimit {
            stream.yield(.state(.setup, sessionID: sessionID, connection: connection))
        }
        stream.yield(.state(.waiting(NWError.posix(.EAGAIN)), sessionID: sessionID, connection: connection))

        var deliveredCount = 0
        for await _ in stream.events {
            deliveredCount += 1
        }

        XCTAssertEqual(deliveredCount, DeviceConnectionEventStream.bufferLimit)
        XCTAssertTrue(stream.didOverflow)
    }

    // MARK: - DeviceConnection Init (actor-isolated)

    @ButtonHeistActor
    func testConnectWithoutTokenEmitsMissingToken() async {
        let connection = DeviceConnection(device: makeDummyDevice(), token: nil)
        var disconnectReason: DisconnectReason?
        connection.onEvent = { event in
            if case .disconnected(let reason) = event {
                disconnectReason = reason
            }
        }

        connection.connect()

        XCTAssertEqual(disconnectReason, .missingToken)
    }

    @ButtonHeistActor
    func testRepeatedDisconnectInvalidatesTransportCallbacksBeforeRelease() async {
        let connection = DeviceConnection(device: makeDummyDevice(), token: "token")

        for _ in 0..<3 {
            let transportConnection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
            var callbackProbe: DeviceConnectionCallbackProbe? = DeviceConnectionCallbackProbe()
            weak var callbackReference: DeviceConnectionCallbackProbe?
            callbackReference = callbackProbe
            transportConnection.stateUpdateHandler = { [callbackProbe] _ in
                _ = callbackProbe
            }
            connection.runtimePhase = .connecting(DeviceConnection.RuntimeSession(
                connection: transportConnection
            ))
            callbackProbe = nil

            connection.disconnect()

            XCTAssertNil(transportConnection.stateUpdateHandler)
            XCTAssertNil(callbackReference)
            assertDeviceConnectionDisconnected(connection)
        }
    }

    // MARK: - Receive Events

    @ButtonHeistActor
    func testReceiveErrorWithContentDisconnectsAsNetworkError() async {
        let (connection, transportConnection) = makeConnectedConnection()
        let expectedError = NWError.posix(.ECONNRESET)
        var disconnectReason: DisconnectReason?
        var deliveredMessage = false
        connection.onEvent = { event in
            switch event {
            case .message:
                deliveredMessage = true
            case .disconnected(let reason):
                disconnectReason = reason
            default:
                break
            }
        }

        connection.handleReceive(
            DeviceReceiveEvent(content: Data(#"{"type":"info"}"#.utf8), isComplete: true, error: expectedError),
            connection: transportConnection
        )

        guard let reason = disconnectReason, case .networkError(let failure) = reason else {
            return XCTFail("Expected network error disconnect, got \(String(describing: disconnectReason))")
        }
        XCTAssertEqual(failure, NetworkTransportFailure(expectedError))
        XCTAssertTrue(failure.description.contains("posix"))
        XCTAssertFalse(deliveredMessage)
        assertDeviceConnectionDisconnected(connection)
    }

    @ButtonHeistActor
    func testNilContentNoncompleteReceiveKeepsConnectionOpen() async {
        let (connection, transportConnection) = makeConnectedConnection()

        connection.handleReceive(
            DeviceReceiveEvent(content: nil, isComplete: false, error: nil),
            connection: transportConnection
        )

        assertDeviceConnectionConnected(connection)
    }

    @ButtonHeistActor
    func testReceiveFramesFragmentedAndBatchedMessagesWithOneRetainedRemainder() async throws {
        let (connection, transportConnection) = makeConnectedConnection()
        let encodedMessage = try testResponseEnvelopeData(.serverHello)
        let splitIndex = encodedMessage.count / 2
        var receivedMessages = 0
        connection.onEvent = { event in
            if case .message(.serverHello, _) = event {
                receivedMessages += 1
            }
        }

        connection.handleReceive(
            .content(Data(encodedMessage.prefix(splitIndex))),
            connection: transportConnection
        )

        XCTAssertEqual(receivedMessages, 0)

        var secondBatch = Data(encodedMessage.suffix(from: splitIndex))
        secondBatch.append(WireFrameLimits.newlineDelimiterByte)
        secondBatch.append(encodedMessage)
        secondBatch.append(contentsOf: [
            WireFrameLimits.newlineDelimiterByte,
            WireFrameLimits.newlineDelimiterByte,
        ])
        secondBatch.append(Data("partial".utf8))

        connection.handleReceive(.content(secondBatch), connection: transportConnection)

        XCTAssertEqual(receivedMessages, 2)
        guard case .connected(let session) = connection.runtimePhase else {
            return XCTFail("Expected connected receive session")
        }
        XCTAssertEqual(session.receiveFramer.pendingData, Data("partial".utf8))
    }

    @ButtonHeistActor
    func testCompleteReceiveWithoutContentDisconnectsAsServerClosed() async {
        let (connection, transportConnection) = makeConnectedConnection()
        var disconnectReason: DisconnectReason?
        connection.onEvent = { event in
            if case .disconnected(let reason) = event {
                disconnectReason = reason
            }
        }

        connection.handleReceive(
            DeviceReceiveEvent(content: nil, isComplete: true, error: nil),
            connection: transportConnection
        )

        XCTAssertEqual(disconnectReason, .serverClosed)
        assertDeviceConnectionDisconnected(connection)
    }

    @ButtonHeistActor
    func testStaleReadyCallbackWithWrongSessionIDDoesNotConnectCurrentAttempt() async {
        let transportConnection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let connection = DeviceConnection(device: makeDummyDevice(), token: "token")
        connection.runtimePhase = .connecting(DeviceConnection.RuntimeSession(connection: transportConnection))
        var transportReadyCount = 0
        connection.onTransportReady = {
            transportReadyCount += 1
        }

        connection.handleStateChange(.ready, sessionID: UUID(), connection: transportConnection)

        guard case .connecting = connection.runtimePhase else {
            return XCTFail("Expected stale ready callback to leave the connection attempt in progress")
        }
        XCTAssertEqual(transportReadyCount, 0)

        connection.handleStateChange(.ready, connection: transportConnection)

        assertDeviceConnectionConnected(connection)
        XCTAssertEqual(transportReadyCount, 1)
    }

    @ButtonHeistActor
    func testStaleReceiveCallbackWithWrongSessionIDDoesNotCloseCurrentSession() async {
        let (connection, transportConnection) = makeConnectedConnection()
        var disconnectReason: DisconnectReason?
        connection.onEvent = { event in
            if case .disconnected(let reason) = event {
                disconnectReason = reason
            }
        }

        connection.handleReceive(.completed, connection: transportConnection, sessionID: UUID())

        assertDeviceConnectionConnected(connection)
        XCTAssertNil(disconnectReason)

        connection.handleReceive(.completed, connection: transportConnection)

        XCTAssertEqual(disconnectReason, .serverClosed)
        assertDeviceConnectionDisconnected(connection)
    }

    // MARK: - Loopback Detection

    func testIPv4LoopbackDetected() {
        let endpoint = DiscoveredDeviceEndpoint.hostPort(host: "127.0.0.1", port: 8080)
        XCTAssertTrue(DeviceConnection.isLoopbackEndpoint(endpoint))
    }

    func testIPv6LoopbackDetected() {
        let endpoint = DiscoveredDeviceEndpoint.hostPort(host: "::1", port: 8080)
        XCTAssertTrue(DeviceConnection.isLoopbackEndpoint(endpoint))
    }

    func testHostnameLocalhostNotTreatedAsLoopback() {
        let endpoint = DiscoveredDeviceEndpoint.hostPort(host: "localhost", port: 8080)
        XCTAssertFalse(DeviceConnection.isLoopbackEndpoint(endpoint), "Hostname 'localhost' must not be treated as loopback")
    }

    func testRemoteIPNotLoopback() {
        let endpoint = DiscoveredDeviceEndpoint.hostPort(host: "192.168.1.1", port: 8080)
        XCTAssertFalse(DeviceConnection.isLoopbackEndpoint(endpoint))
    }

    func testServiceEndpointNotLoopback() {
        let endpoint = DiscoveredDeviceEndpoint.service(name: "test", type: "_test._tcp", domain: "local.")
        XCTAssertFalse(DeviceConnection.isLoopbackEndpoint(endpoint))
    }
}

private final class DeviceConnectionCallbackProbe: Sendable {}
