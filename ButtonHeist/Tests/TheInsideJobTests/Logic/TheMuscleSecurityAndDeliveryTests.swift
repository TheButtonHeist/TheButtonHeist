#if canImport(UIKit)
import XCTest
import TheScore
@testable import TheInsideJob

@MainActor
final class TheMuscleBruteForceProtectionTests: TheMuscleTestCase {
    func testLockoutAfterMaxFailedAttempts() async throws {
        for clientID in 1...5 {
            try await authenticate(
                clientId: clientID,
                token: "wrong-token",
                address: "192.168.1.100",
                respond: respondSink()
            )
            await muscle.handleClientDisconnected(clientID, generation: deliveryGeneration)
        }

        let (respond, responses) = collectResponses()
        try await authenticate(
            clientId: 6,
            token: "wrong-token",
            address: "192.168.1.100",
            respond: respond
        )

        let hasLockout = responses().compactMap { decodeServerMessage($0) }.contains { message in
            if case .error(let error) = message, error.kind == .authFailure {
                return error.message.description.contains("Too many")
            }
            return false
        }
        XCTAssertTrue(hasLockout, "Should receive lockout message after exceeding max failed attempts across reconnections")
    }

    func testLockoutDoesNotAffectOtherAddresses() async throws {
        for clientID in 1...5 {
            try await authenticate(
                clientId: clientID,
                token: "wrong-token",
                address: "192.168.1.100",
                respond: respondSink()
            )
            await muscle.handleClientDisconnected(clientID, generation: deliveryGeneration)
        }

        let (respond, _) = collectResponses()
        try await authenticate(
            clientId: 10,
            token: "test-token",
            address: "192.168.1.200",
            respond: respond
        )

        let connections = await muscle.activeSessionConnections
        XCTAssertTrue(connections.contains(10), "Clients from other addresses should not be affected by lockout")
    }

    func testSuccessfulAuthClearsFailedAttempts() async throws {
        let address: ClientNetworkAddress = "192.168.1.100"

        for clientID in 1...3 {
            try await authenticate(
                clientId: clientID,
                token: "wrong-token",
                address: address,
                respond: respondSink()
            )
            await muscle.handleClientDisconnected(clientID, generation: deliveryGeneration)
        }

        try await authenticate(
            clientId: 4,
            token: "test-token",
            address: address,
            respond: respondSink()
        )
        let connections = await muscle.activeSessionConnections
        XCTAssertTrue(connections.contains(4), "Should authenticate after failed attempts below threshold")

        await muscle.handleClientDisconnected(4, generation: deliveryGeneration)

        for clientID in 5...9 {
            try await authenticate(
                clientId: clientID,
                token: "wrong-token",
                address: address,
                respond: respondSink()
            )
            await muscle.handleClientDisconnected(clientID, generation: deliveryGeneration)
        }

        let (respond, responses) = collectResponses()
        try await authenticate(
            clientId: 10,
            token: "wrong-token",
            address: address,
            respond: respond
        )

        let hasLockout = responses().compactMap { decodeServerMessage($0) }.contains { message in
            if case .error(let error) = message, error.kind == .authFailure {
                return error.message.description.contains("Too many")
            }
            return false
        }
        XCTAssertTrue(hasLockout, "Should lock out again after counter reset and 5 more failures")
    }
}

@MainActor
final class TheMuscleDeliveryTests: TheMuscleTestCase {
    func testSendDataAfterClientDisconnectFailsWithoutCallingTransport() async throws {
        try await authenticate(clientId: 1, token: "test-token", respond: respondSink())
        let sentBeforeDisconnect = sentMessages.count

        await muscle.handleClientDisconnected(1, generation: deliveryGeneration)

        let outcome = await muscle.sendData(Data("late-response".utf8), toClient: 1)

        guard case .failed(.clientNotFound(1)) = outcome else {
            return XCTFail("Expected clientNotFound failure, got \(outcome)")
        }
        XCTAssertEqual(
            sentMessages.count,
            sentBeforeDisconnect,
            "Closed-client sends must fail before invoking the transport closure"
        )
    }
}

#endif // canImport(UIKit)
