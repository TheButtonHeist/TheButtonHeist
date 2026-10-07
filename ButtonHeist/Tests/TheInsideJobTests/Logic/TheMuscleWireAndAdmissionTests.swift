#if canImport(UIKit)
import ButtonHeistTestSupport
import XCTest
import TheScore
@testable import TheInsideJob

@MainActor
final class TheMuscleWireTests: TheMuscleTestCase {
    func testServerHelloDeliveryRejectsStaleGenerationAndAdmitsCurrentGeneration() async {
        let staleGeneration = deliveryGeneration
        await installCallbacks()
        let currentGeneration = deliveryGeneration
        let initialSendCount = sentMessages.count

        let staleOutcome = await muscle.sendServerHello(
            clientId: 7,
            generation: staleGeneration
        )
        XCTAssertEqual(staleOutcome, .transportUnavailable(clientId: nil))
        XCTAssertEqual(sentMessages.count, initialSendCount)

        let currentOutcome = await muscle.sendServerHello(
            clientId: 7,
            generation: currentGeneration
        )
        XCTAssertEqual(currentOutcome, .delivered)
        XCTAssertEqual(sentMessages.count, initialSendCount + 1)
    }

    func testExplicitErrorEnvelopeStillEncodes() async throws {
        let requestID: RequestID = "explicit-error"
        let result = ResponseEnvelopeDelivery.encodeEnvelope(
            .error(ServerError(kind: .general, message: "Explicit failure")),
            requestId: requestID
        )
        guard case .success(let data) = result else {
            return XCTFail("Expected explicit error envelope to encode, got \(result)")
        }

        let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        XCTAssertEqual(envelope.requestId, requestID)
        guard case .error(let error) = envelope.message else {
            return XCTFail("Expected explicit error response, got \(envelope.message)")
        }
        XCTAssertEqual(error.kind, .general)
        XCTAssertEqual(error.message, "Explicit failure")
    }

    func testServerHelloResponseEnvelopeKeepsStableWireShape() async throws {
        let outcome = await muscle.sendServerHello(clientId: 7, generation: deliveryGeneration)

        XCTAssertEqual(outcome, .delivered)
        let sent = try XCTUnwrap(sentMessages.first)
        XCTAssertEqual(sent.clientId, 7)
        let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: sent.data)
        XCTAssertNil(envelope.requestId)
        guard case .serverHello = envelope.message else {
            return XCTFail("Expected serverHello envelope, got \(envelope.message)")
        }
        let object = try JSONProbe(data: sent.data)
        XCTAssertEqual(try object.string("type"), ServerWireMessageType.serverHello.rawValue)
        try object.assertMissing("payload")
        XCTAssertEqual(try object.string("buttonHeistVersion"), buttonHeistVersion.description)
    }

    func testAdmissionFailureResponseEnvelopeKeepsStableWireShape() async throws {
        let (respond, responses) = collectResponses()
        let data = try JSONEncoder().encode(RequestEnvelope(requestId: "unauth-ping", message: .ping))

        _ = await muscle.admitClientMessage(
            1,
            data: data,
            respond: respond,
            generation: deliveryGeneration
        )

        let response = try XCTUnwrap(responses().first)
        let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: response)
        XCTAssertEqual(envelope.requestId, "unauth-ping")
        guard case .error(let error) = envelope.message else {
            return XCTFail("Expected error envelope, got \(envelope.message)")
        }
        XCTAssertEqual(error.kind, .authFailure)
        XCTAssertEqual(error.message, "Authentication required before ping.")
        let object = try JSONProbe(data: response)
        XCTAssertEqual(try object.string("type"), ServerWireMessageType.error.rawValue)
        try object.assertPresent("payload")
        XCTAssertEqual(try object.string("buttonHeistVersion"), buttonHeistVersion.description)
    }
}

@MainActor
final class ClientAdmissionRateLimitTests: XCTestCase {
    func testExactVersionMismatchIsRejectedBeforeHelloAdmission() throws {
        var admission = try admissionReducer()
        admission.registerClientAddress(1, address: "127.0.0.1")
        let oldVersion: ButtonHeistVersion = "0.6.31"
        let data = try JSONEncoder().encode(RequestEnvelope(
            buttonHeistVersion: oldVersion,
            message: .clientHello
        ))

        guard case .handled(let effects) = admission.admit(
            1,
            data: data,
            respond: { _ in .delivered }
        ) else {
            return XCTFail("Expected mismatched client version to be rejected")
        }
        guard effects.count == 3,
              case .log(.versionMismatch(
                  let clientId,
                  let serverVersion,
                  let clientVersion
              )) = effects[0],
              case .sendResponse(.protocolMismatch(let payload), nil, _) = effects[1],
              case .delayedDisconnect(let disconnectedClientId) = effects[2] else {
            return XCTFail("Expected exact mismatch log, response, and disconnect")
        }
        XCTAssertEqual(clientId, 1)
        XCTAssertEqual(disconnectedClientId, 1)
        XCTAssertEqual(serverVersion, buttonHeistVersion)
        XCTAssertEqual(clientVersion, oldVersion)
        XCTAssertEqual(payload.serverButtonHeistVersion, buttonHeistVersion)
        XCTAssertEqual(payload.clientButtonHeistVersion, oldVersion)
    }

    func testMessageRateAdmissionReturnsGeneralErrorForFirstOverLimitFrame() throws {
        var admission = try admissionReducer()
        let data = try JSONEncoder().encode(RequestEnvelope(message: .ping))
        let now = Date()

        for _ in 0..<ClientAdmission.RateLimiter.defaultMaxMessagesPerSecond {
            _ = admission.admit(1, data: data, respond: { _ in .delivered }, at: now)
        }

        guard case .handled(let effects) = admission.admit(
            1,
            data: data,
            respond: { _ in .delivered },
            at: now
        ) else {
            return XCTFail("Expected over-limit frame to be handled by admission")
        }

        XCTAssertEqual(effects.count, 2)
        guard case .log(.rateLimited(let clientId)) = effects[0] else {
            return XCTFail("Expected rate-limit log first, got \(effects[0])")
        }
        XCTAssertEqual(clientId, 1)
        guard case .sendResponse(.error(let error), let requestId, _) = effects[1] else {
            return XCTFail("Expected rate-limit response second, got \(effects[1])")
        }
        XCTAssertNil(requestId)
        XCTAssertEqual(error.kind, .general)
        XCTAssertEqual(error.message, "Rate limited: max 30 messages per second")
    }

    func testMessageRateAdmissionNotifiesOnlyOncePerWindow() throws {
        var admission = try admissionReducer()
        let data = try JSONEncoder().encode(RequestEnvelope(message: .ping))
        let now = Date()

        for _ in 0..<ClientAdmission.RateLimiter.defaultMaxMessagesPerSecond {
            _ = admission.admit(1, data: data, respond: { _ in .delivered }, at: now)
        }

        guard case .handled(let firstLimit) = admission.admit(
            1,
            data: data,
            respond: { _ in .delivered },
            at: now
        ) else {
            return XCTFail("Expected first over-limit frame to be handled")
        }
        XCTAssertEqual(firstLimit.count, 2)
        guard case .log(.rateLimited(let firstLimitClientId)) = firstLimit[0] else {
            return XCTFail("Expected first over-limit effect to log rate limiting")
        }
        XCTAssertEqual(firstLimitClientId, 1)
        guard case .sendResponse = firstLimit[1] else {
            return XCTFail("Expected first over-limit notification to send a response")
        }

        guard case .handled(let repeatedLimit) = admission.admit(
            1,
            data: data,
            respond: { _ in .delivered },
            at: now
        ) else {
            return XCTFail("Expected repeated over-limit frame to be handled")
        }
        XCTAssertEqual(repeatedLimit.count, 1)
        guard case .log(.rateLimited(let repeatedLimitClientId)) = repeatedLimit[0] else {
            return XCTFail("Expected repeated over-limit frame to only log rate limiting")
        }
        XCTAssertEqual(repeatedLimitClientId, 1)

        guard case .handled(let nextWindow) = admission.admit(
            1,
            data: data,
            respond: { _ in .delivered },
            at: now.addingTimeInterval(1.1)
        ) else {
            return XCTFail("Expected next-window frame to continue through normal admission")
        }
        XCTAssertEqual(nextWindow.count, 3)
        guard case .log(.unauthenticatedMessage(let clientId, let message)) = nextWindow[0] else {
            return XCTFail("Expected unauthenticated-message log first, got \(nextWindow[0])")
        }
        XCTAssertEqual(clientId, 1)
        XCTAssertEqual(message, "Authentication required before ping.")
        guard case .sendResponse(.error(let error), _, _) = nextWindow[1] else {
            return XCTFail("Expected normal pre-auth rejection after window reset")
        }
        guard case .delayedDisconnect(let disconnectClientId) = nextWindow[2] else {
            return XCTFail("Expected disconnect after response, got \(nextWindow[2])")
        }
        XCTAssertEqual(disconnectClientId, 1)
        XCTAssertEqual(error.kind, .authFailure)
        XCTAssertEqual(error.message, "Authentication required before ping.")
    }

    func testMessageRateAdmissionLimitsAuthenticatedMessagesBeforeDispatch() throws {
        var admission = try admissionReducer()
        let respond: SocketResponseHandler = { _ in .delivered }
        let now = Date()

        admission.registerClientAddress(1, address: "127.0.0.1")
        let helloData = try JSONEncoder().encode(RequestEnvelope(message: .clientHello))
        guard case .handled = admission.admit(1, data: helloData, respond: respond, at: now) else {
            return XCTFail("Expected client hello to be handled")
        }

        guard case .sessionAdmission(let sessionAdmission) = admission.admit(
            1,
            data: try encodeAuth(token: "good-token"),
            respond: respond,
            at: now
        ) else {
            return XCTFail("Expected valid token to request session admission")
        }
        _ = admission.completeAuthentication(sessionAdmission)

        let pingData = try JSONEncoder().encode(RequestEnvelope(message: .ping))
        let nextWindow = now.addingTimeInterval(1.1)
        for _ in 0..<ClientAdmission.RateLimiter.defaultMaxMessagesPerSecond {
            guard case .admitted = admission.admit(
                1,
                data: pingData,
                respond: respond,
                at: nextWindow
            ) else {
                return XCTFail("Expected authenticated message to reach dispatch before rate limit")
            }
        }

        guard case .handled(let effects) = admission.admit(
            1,
            data: pingData,
            respond: respond,
            at: nextWindow
        ) else {
            return XCTFail("Expected over-limit authenticated message to be handled by admission")
        }
        XCTAssertEqual(effects.count, 2)
        guard case .log(.rateLimited(let clientId)) = effects[0] else {
            return XCTFail("Expected rate-limit log first, got \(effects[0])")
        }
        XCTAssertEqual(clientId, 1)
        guard case .sendResponse(.error(let error), let requestId, _) = effects[1] else {
            return XCTFail("Expected rate-limit response second, got \(effects[1])")
        }
        XCTAssertNil(requestId)
        XCTAssertEqual(error.kind, .general)
        XCTAssertEqual(error.message, "Rate limited: max 30 messages per second")
    }

    private func admissionReducer() throws -> ClientAdmission.Reducer {
        ClientAdmission.Reducer(
            sessionToken: "good-token",
            authenticationPolicy: try XCTUnwrap(.init(maximumFailedAttempts: 2, lockoutDuration: 30))
        )
    }

    private func encodeAuth(token: SessionAuthToken) throws -> Data {
        try JSONEncoder().encode(
            RequestEnvelope(message: .authenticate(AuthenticatePayload(token: token, driverId: nil)))
        )
    }
}

#endif // canImport(UIKit)
