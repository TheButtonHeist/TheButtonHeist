#if canImport(UIKit)
import XCTest
import TheScore
@testable import TheInsideJob

@MainActor
final class TheMuscleAuthenticationTests: TheMuscleTestCase {
    func testValidTokenAuthenticates() async throws {
        let (respond, responses) = collectResponses()
        try await authenticate(clientId: 1, token: "test-token", respond: respond)

        let connections = await muscle.activeSessionConnections
        XCTAssertTrue(connections.contains(1))
        XCTAssertEqual(connections.count, 1)
        let serverMessages = responses().compactMap { decodeServerMessage($0) }
        for message in serverMessages {
            if case .error(let serverError) = message, serverError.kind == .authFailure {
                XCTFail("Should not send authFailure error for valid token")
            }
            if case .sessionLocked = message {
                XCTFail("Should not send sessionLocked for first connection")
            }
        }
    }

    func testInvalidTokenRejected() async throws {
        let (respond, responses) = collectResponses()
        try await authenticate(clientId: 1, token: "wrong-token", respond: respond)

        let connections = await muscle.activeSessionConnections
        XCTAssertFalse(connections.contains(1))
        XCTAssertEqual(connections.count, 0)

        let authFailure = responses()
            .compactMap(decodeServerMessage)
            .compactMap { message -> ServerError? in
                guard case .error(let error) = message, error.kind == .authFailure else { return nil }
                return error
            }
            .first
        XCTAssertEqual(authFailure?.message, "Invalid token. Retry with the session token.")
        XCTAssertEqual(authFailure?.recoveryHint, "Retry with the session token.")
    }

    func testNonAuthMessageReturnsAuthFailure() async throws {
        let pingData = try JSONEncoder().encode(RequestEnvelope(message: .ping))
        let (respond, responses) = collectResponses()

        _ = await muscle.admitClientMessage(
            1,
            data: pingData,
            respond: respond,
            delivery: delivery
        )

        let authFailure = responses()
            .compactMap(decodeServerMessage)
            .compactMap { message -> ServerError? in
                guard case .error(let error) = message, error.kind == .authFailure else { return nil }
                return error
            }
            .first
        XCTAssertEqual(authFailure?.message, "Authentication required before ping.")
    }

    func testMalformedPreAuthMessageSendsErrorBeforeDisconnect() async {
        let (respond, responses) = collectResponses()

        _ = await muscle.admitClientMessage(
            1,
            data: Data("not json".utf8),
            respond: respond,
            delivery: delivery
        )

        let validationError = responses()
            .compactMap(decodeServerMessage)
            .compactMap { message -> ServerError? in
                guard case .error(let error) = message, error.kind == .validationError else { return nil }
                return error
            }
            .first
        XCTAssertNotNil(validationError)
        XCTAssertTrue(
            validationError?.message.description.contains("Could not decode client message before authentication") == true
        )
        XCTAssertTrue(validationError?.message.description.contains("same Button Heist version") == true)
    }
}

#endif // canImport(UIKit)
