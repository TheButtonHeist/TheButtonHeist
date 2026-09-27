import Foundation
import XCTest

@testable import ButtonHeistTesting
import TheScore
@testable import TheInsideJob

/// Integration tests for token-derived Network.framework TLS-PSK transport.
final class TLSIntegrationTests: XCTestCase {

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

    func testDataExchangeOverTLSPreSharedKey() async throws {
        let token = "shared-token"
        let echoReceived = expectation(description: "server received message")
        let callbacks = SocketServerCallbacks(
            onDataReceived: { _, data, respond in
                Task {
                    _ = await respond(data)
                    echoReceived.fulfill()
                }
            }
        )
        server = SimpleSocketServer(callbacks: callbacks)
        let port = try await server.startAsync(
            port: 0,
            bindToLoopback: true,
            tlsParameters: ButtonHeistTLSPreSharedKey.networkParameters(from: token)
        )
        let client = ButtonHeistNetworkTestClient.tls(port: port, token: token)
        defer { client.cancel() }
        try await client.connect()

        try await client.sendLine("hello-tls")

        await fulfillment(of: [echoReceived], timeout: 5.0)
        let received = String(data: try await client.receiveLine(), encoding: .utf8)
        XCTAssertEqual(received, "hello-tls")
    }

    func testWrongPreSharedKeyRejectsConnection() async throws {
        let port = try await server.startAsync(
            port: 0,
            bindToLoopback: true,
            tlsParameters: ButtonHeistTLSPreSharedKey.networkParameters(from: "server-token")
        )
        let client = ButtonHeistNetworkTestClient.tls(port: port, token: "client-token")
        defer { client.cancel() }

        try await client.connectExpectingRejection()
    }

    func testPassiveReachabilityDoesNotSendUnauthenticatedStatusOverTLS() async throws {
        let token = "probe-token"
        let clientConnected = expectation(description: "client connected")
        let unexpectedPreAuthData = expectation(description: "no unauthenticated status probe")
        unexpectedPreAuthData.isInverted = true
        let callbacks = SocketServerCallbacks(
            onClientConnected: { _, _ in
                clientConnected.fulfill()
            },
            onDataReceived: { _, _, _ in
                unexpectedPreAuthData.fulfill()
            }
        )
        server = SimpleSocketServer(callbacks: callbacks)
        let port = try await server.startAsync(
            port: 0,
            bindToLoopback: true,
            tlsParameters: ButtonHeistTLSPreSharedKey.networkParameters(from: token)
        )
        let client = ButtonHeistNetworkTestClient.tls(port: port, token: token)
        defer { client.cancel() }

        try await client.connect()

        await fulfillment(of: [clientConnected], timeout: 5.0)
        await fulfillment(of: [unexpectedPreAuthData], timeout: 0.2)
    }
}

#if canImport(UIKit)
final class JoinHeistIntegrationTests: XCTestCase {

    func testWithJoinedHeistSessionExposesSessionAndStopsOnScopeExit() throws {
        let token = "scoped-join-heist-\(UUID().uuidString)"
        var listeningPort: UInt16?
        var readyMessage: String?

        withJoinedHeistSession(
            token: token,
            port: 0,
            allowedScopes: [.simulator],
            file: #filePath,
            line: #line
        ) { session in
            XCTAssertEqual(session.token, token)
            XCTAssertGreaterThan(session.listeningPort, 0)
            XCTAssertEqual(session.addressFamily, .dualStack)
            XCTAssertEqual(session.endpoint, "127.0.0.1:\(session.listeningPort)")
            XCTAssertTrue(session.readyMessage.contains("endpoint=127.0.0.1:\(session.listeningPort)"))
            XCTAssertTrue(session.readyMessage.contains("token=\(token)"))
            XCTAssertTrue(session.readyMessage.contains("simulator loopback only"))
            listeningPort = session.listeningPort
            readyMessage = session.readyMessage
        }

        let port = try XCTUnwrap(listeningPort)
        XCTAssertNotNil(readyMessage)

        let client = ButtonHeistNetworkTestClient.tls(port: port, token: token)
        defer { client.cancel() }

        runHeistSyncOperation(file: #filePath, line: #line) {
            try await client.connectExpectingRejection()
        }
    }

    func testJoinHeistSessionAcceptsWireClientAndReturnsInterface() throws {
        let token = "join-heist-\(UUID().uuidString)"
        withJoinedHeistSession(
            token: token,
            port: 0,
            allowedScopes: [.simulator],
            file: #filePath,
            line: #line
        ) { session in
            let client = ButtonHeistWireTestClient(
                token: token,
                port: session.listeningPort,
                host: .ipv4(.loopback)
            )
            defer { client.cancel() }

            guard let probe = runHeistSyncOperation(file: #filePath, line: #line, {
                try await client.connect()
                let info = try await client.authenticate(driverId: "join-heist-integration-test")
                let interface = try await client.requestInterface()
                return JoinHeistProbe(
                    reportedPort: info.listeningPort,
                    labels: interface.projectedElements.compactMap(\.semantics.assertable.label)
                )
            }) else {
                return
            }

            XCTAssertEqual(probe.reportedPort, session.listeningPort)
            XCTAssertTrue(
                probe.labels.contains("ButtonHeist Demo"),
                "Expected joined session to return the live demo app interface, got labels: \(probe.labels)"
            )
        }
    }

    func testWithJoinedHeistSessionReportsIPv6EndpointWhenConfigured() throws {
        let token = "scoped-join-heist-ipv6-\(UUID().uuidString)"

        withJoinedHeistSession(
            token: token,
            port: 0,
            addressFamily: .ipv6,
            allowedScopes: [.simulator],
            file: #filePath,
            line: #line
        ) { session in
            XCTAssertEqual(session.addressFamily, .ipv6)
            XCTAssertEqual(session.endpoint, "[::1]:\(session.listeningPort)")
            XCTAssertTrue(session.readyMessage.contains("endpoint=[::1]:\(session.listeningPort)"))
        }
    }
}

private struct JoinHeistProbe: Sendable {
    let reportedPort: UInt16
    let labels: [String]
}
#endif
