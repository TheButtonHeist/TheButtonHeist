// Integration tests for the socket listener lifecycle and client transport.
// Uses real NWListener on loopback and real NWConnection — requires TCP networking.

import XCTest
import os
import TheScore
@testable import TheInsideJob

final class SimpleSocketServerIntegrationTests: XCTestCase {

    private var server: SimpleSocketServer!

    override func setUp() {
        super.setUp()
        server = SimpleSocketServer()
    }

    override func tearDown() async throws {
        await server.stop()
        server = nil
        try await super.tearDown()
    }

    // MARK: - Connection admission

    func testConnectionAdmissionRejectsReadyAfterEarlyCancel() {
        let admission = ConnectionAdmission()

        XCTAssertEqual(admission.recordCancellation(), .noRegisteredClient)
        XCTAssertEqual(admission.recordReady(), .ignore)
    }

    func testConnectionAdmissionRequestsCleanupWhenCancelArrivesDuringAcceptance() {
        let admission = ConnectionAdmission()

        XCTAssertEqual(admission.recordReady(), .accept)
        XCTAssertEqual(admission.recordCancellation(), .noRegisteredClient)
        XCTAssertEqual(
            admission.recordAcceptance(.registered(clientId: 7)),
            .removeRegisteredClient(7)
        )
        XCTAssertEqual(admission.recordCancellation(), .noRegisteredClient)
    }

    func testConnectionAdmissionReturnsAcceptedClientForLateCancel() {
        let admission = ConnectionAdmission()

        XCTAssertEqual(admission.recordReady(), .accept)
        XCTAssertEqual(
            admission.recordAcceptance(.registered(clientId: 7)),
            .keepRegisteredClient
        )
        XCTAssertEqual(admission.recordCancellation(), .removeRegisteredClient(7))
        XCTAssertEqual(admission.recordCancellation(), .noRegisteredClient)
    }

    func testConnectionAdmissionRejectedReadyIsTerminal() {
        let admission = ConnectionAdmission()

        XCTAssertEqual(admission.recordReady(), .accept)
        XCTAssertEqual(admission.recordAcceptance(.rejected), .noRegisteredClient)
        XCTAssertEqual(admission.recordCancellation(), .noRegisteredClient)
        XCTAssertEqual(admission.recordReady(), .ignore)
    }

    func testConnectionAdmissionIgnoresDuplicateReadyDuringAcceptance() {
        let admission = ConnectionAdmission()

        XCTAssertEqual(admission.recordReady(), .accept)
        XCTAssertEqual(admission.recordReady(), .ignore)
        XCTAssertEqual(
            admission.recordAcceptance(.registered(clientId: 7)),
            .keepRegisteredClient
        )
        XCTAssertEqual(admission.recordCancellation(), .removeRegisteredClient(7))
    }

    func testConnectionAdmissionIgnoresAcceptanceBeforeReady() {
        let admission = ConnectionAdmission()

        XCTAssertEqual(
            admission.recordAcceptance(.registered(clientId: 7)),
            .noRegisteredClient
        )
        XCTAssertEqual(admission.recordReady(), .accept)
        XCTAssertEqual(
            admission.recordAcceptance(.registered(clientId: 8)),
            .keepRegisteredClient
        )
        XCTAssertEqual(admission.recordCancellation(), .removeRegisteredClient(8))
    }

    // MARK: - Listener lifecycle

    func testStartTransitionsToListening() async throws {
        let port = try await server.startPlaintext(port: 0, bindToLoopback: true)
        XCTAssertGreaterThan(port, 0)
        XCTAssertEqual(server.listeningPort, port)
    }

    func testDualStackLoopbackAcceptsIPv4AndIPv6Clients() async throws {
        let connected = expectation(description: "clients connected")
        connected.expectedFulfillmentCount = 2
        let callbacks = SocketServerCallbacks(
            onClientConnected: { _, _ in connected.fulfill() }
        )
        server = SimpleSocketServer(callbacks: callbacks)

        let port = try await server.startPlaintext(
            port: 0,
            bindToLoopback: true,
            addressFamily: .dualStack
        )
        let ipv4Client = ButtonHeistNetworkTestClient.plaintext(
            port: port,
            host: .ipv4(.loopback)
        )
        let ipv6Client = ButtonHeistNetworkTestClient.plaintext(
            port: port,
            host: .ipv6(.loopback)
        )
        defer {
            ipv4Client.cancel()
            ipv6Client.cancel()
        }

        try await ipv4Client.connect()
        try await ipv6Client.connect()

        await fulfillment(of: [connected], timeout: 5.0)
    }

    func testDualStackAnyInterfaceAcceptsIPv4AndIPv6Clients() async throws {
        let connected = expectation(description: "clients connected")
        connected.expectedFulfillmentCount = 2
        let callbacks = SocketServerCallbacks(
            onClientConnected: { _, _ in connected.fulfill() }
        )
        server = SimpleSocketServer(callbacks: callbacks)

        let port = try await server.startPlaintext(
            port: 0,
            bindToLoopback: false,
            addressFamily: .dualStack
        )
        let ipv4Client = ButtonHeistNetworkTestClient.plaintext(
            port: port,
            host: .ipv4(.loopback)
        )
        let ipv6Client = ButtonHeistNetworkTestClient.plaintext(
            port: port,
            host: .ipv6(.loopback)
        )
        defer {
            ipv4Client.cancel()
            ipv6Client.cancel()
        }

        try await ipv4Client.connect()
        try await ipv6Client.connect()

        await fulfillment(of: [connected], timeout: 5.0)
    }

    func testDoubleStartThrowsAlreadyRunning() async throws {
        _ = try await server.startPlaintext(port: 0, bindToLoopback: true)

        do {
            _ = try await server.startPlaintext(port: 0, bindToLoopback: true)
            XCTFail("Expected alreadyRunning error on double start")
        } catch let error as SimpleSocketServer.StartupError {
            XCTAssertEqual(error, .alreadyRunning)
        }
    }

    func testStopFromListeningResetsPort() async throws {
        _ = try await server.startPlaintext(port: 0, bindToLoopback: true)
        XCTAssertGreaterThan(server.listeningPort, 0)

        await server.stop()
        XCTAssertEqual(server.listeningPort, 0)
    }

    func testStopFromStoppedIsNoOp() async throws {
        await server.stop()
        XCTAssertEqual(server.listeningPort, 0)
    }

    func testSendToMissingClientFailsTyped() async throws {
        _ = try await server.startPlaintext(port: 0, bindToLoopback: true)
        let outcome = await server.send(Data("late-response".utf8), to: 404)

        guard case .failed(.clientNotFound(404)) = outcome else {
            return XCTFail("Expected clientNotFound failure, got \(outcome)")
        }
    }

    func testCanRestartAfterStop() async throws {
        let firstPort = try await server.startPlaintext(port: 0, bindToLoopback: true)
        XCTAssertGreaterThan(firstPort, 0)

        await server.stop()

        let secondPort = try await server.startPlaintext(port: 0, bindToLoopback: true)
        XCTAssertGreaterThan(secondPort, 0)
    }

    // MARK: - Client lifecycle

    func testNewClientRoutesFramedDataToRawDataCallback() async throws {
        let capturedClientId = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let capturedData = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let clientConnected = expectation(description: "client connected")
        let dataReceived = expectation(description: "data received")

        let callbacks = SocketServerCallbacks(
            onClientConnected: { clientId, _ in
                capturedClientId.withLock { $0 = clientId }
                clientConnected.fulfill()
            },
            onDataReceived: { _, data, _ in
                capturedData.withLock { $0 = data }
                dataReceived.fulfill()
            }
        )
        server = SimpleSocketServer(callbacks: callbacks)
        let port = try await server.startPlaintext(port: 0, bindToLoopback: true)

        let client = ButtonHeistNetworkTestClient.plaintext(port: port)
        defer { client.cancel() }

        try await client.connect()
        await fulfillment(of: [clientConnected], timeout: 5.0)

        let clientId = try XCTUnwrap(capturedClientId.withLock { $0 })
        try await client.sendLine("raw-frame")

        await fulfillment(of: [dataReceived], timeout: 5.0)
        XCTAssertEqual(capturedData.withLock { $0 }, Data("raw-frame".utf8))
        XCTAssertGreaterThan(clientId, 0)
    }

    func testTransportDeliversFramesBeyondMessageRateLimit() async throws {
        let capturedFrames = OSAllocatedUnfairLock<[String]>(initialState: [])
        let clientConnected = expectation(description: "client connected")
        let dataReceived = expectation(description: "data received")
        dataReceived.expectedFulfillmentCount = ClientAdmission.RateLimiter.defaultMaxMessagesPerSecond + 1

        let callbacks = SocketServerCallbacks(
            onClientConnected: { _, _ in
                clientConnected.fulfill()
            },
            onDataReceived: { _, data, _ in
                let frame = String(data: data, encoding: .utf8) ?? ""
                capturedFrames.withLock { $0.append(frame) }
                dataReceived.fulfill()
            }
        )
        server = SimpleSocketServer(callbacks: callbacks)
        let port = try await server.startPlaintext(port: 0, bindToLoopback: true)

        let client = ButtonHeistNetworkTestClient.plaintext(port: port)
        defer { client.cancel() }

        try await client.connect()
        await fulfillment(of: [clientConnected], timeout: 5.0)

        let payload = (0...ClientAdmission.RateLimiter.defaultMaxMessagesPerSecond)
            .map { "raw-frame-\($0)\n" }
            .joined()
        try await client.send(Data(payload.utf8))

        await fulfillment(of: [dataReceived], timeout: 5.0)
        XCTAssertEqual(
            capturedFrames.withLock { $0.count },
            ClientAdmission.RateLimiter.defaultMaxMessagesPerSecond + 1
        )
        XCTAssertEqual(capturedFrames.withLock { $0.first }, "raw-frame-0")
        XCTAssertEqual(
            capturedFrames.withLock { $0.last },
            "raw-frame-\(ClientAdmission.RateLimiter.defaultMaxMessagesPerSecond)"
        )
    }

    func testDisconnectRemovesClient() async throws {
        let capturedClientId = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let clientConnected = expectation(description: "client connected")
        let clientDisconnected = expectation(description: "client disconnected")

        let callbacks = SocketServerCallbacks(
            onClientConnected: { clientId, _ in
                capturedClientId.withLock { $0 = clientId }
                clientConnected.fulfill()
            },
            onClientDisconnected: { _ in
                clientDisconnected.fulfill()
            }
        )
        server = SimpleSocketServer(callbacks: callbacks)
        let port = try await server.startPlaintext(port: 0, bindToLoopback: true)

        let client = ButtonHeistNetworkTestClient.plaintext(port: port)
        defer { client.cancel() }

        try await client.connect()
        await fulfillment(of: [clientConnected], timeout: 5.0)

        let clientId = try XCTUnwrap(capturedClientId.withLock { $0 })
        await server.removeClient(clientId)

        await fulfillment(of: [clientDisconnected], timeout: 5.0)
        let outcome = await server.send(Data("after-disconnect".utf8), to: clientId)
        XCTAssertEqual(outcome, .failed(.clientNotFound(clientId)))
    }

    func testScopeRejectionSendsServerErrorBeforeDisconnect() async throws {
        await server.stop()
        let clientConnected = expectation(description: "scope-rejected client must not be accepted")
        clientConnected.isInverted = true
        let callbacks = SocketServerCallbacks(
            onClientConnected: { _, _ in clientConnected.fulfill() }
        )
        server = SimpleSocketServer(allowedScopes: [.usb], callbacks: callbacks)

        let port = try await server.startPlaintext(port: 0, bindToLoopback: true)
        let client = ButtonHeistNetworkTestClient.plaintext(port: port)
        defer { client.cancel() }

        try await client.connect()

        let response = try await client.receiveLine()
        let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: response)
        guard case .error(let error) = envelope.message else {
            return XCTFail("Expected server error before scope rejection teardown, got \(envelope.message)")
        }
        XCTAssertEqual(error.kind, ServerError.Kind.general)
        XCTAssertEqual(error.message, "Connection rejected: simulator connections are not allowed by this server.")
        await fulfillment(of: [clientConnected], timeout: 0.2)
    }
}
