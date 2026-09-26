import ButtonHeistTestSupport
import XCTest
import TheScore

final class AuthMessageTests: XCTestCase {

    // MARK: - authRequired

    func testAuthRequiredEncodeDecode() throws {
        let message = ServerMessage.authRequired
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: data)

        if case .authRequired = decoded {
        } else {
            XCTFail("Expected authRequired, got \(decoded)")
        }
    }

    func testAuthRequiredJSON() throws {
        let message = ServerMessage.authRequired
        let data = try JSONEncoder().encode(message)
        let json = try JSONProbe(data: data)

        XCTAssertEqual(try json.string("type"), "authRequired")
        try json.assertMissing("payload")
    }

    // MARK: - error(ServerError) — authFailure

    func testAuthFailedEncodeDecode() throws {
        let message = ServerMessage.error(ServerError(
            kind: .authFailure,
            message: "Invalid token",
            recoveryHint: "Retry with the configured token."
        ))
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: data)

        if case .error(let serverError) = decoded {
            XCTAssertEqual(serverError.kind, .authFailure)
            XCTAssertEqual(serverError.message, "Invalid token")
            XCTAssertEqual(serverError.recoveryHint, "Retry with the configured token.")
        } else {
            XCTFail("Expected error, got \(decoded)")
        }
    }

    func testAuthFailedRejectsEmptyReason() throws {
        let json = #"{"type":"error","payload":{"kind":"authFailure","message":""}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8)))
    }

    // MARK: - authenticate (ClientMessage)

    func testAuthenticateEncodeDecode() throws {
        let payload = AuthenticatePayload(token: "secret-token-123")
        let message = ClientMessage.authenticate(payload)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)

        if case .authenticate(let decodedPayload) = decoded {
            XCTAssertEqual(decodedPayload.token, "secret-token-123")
        } else {
            XCTFail("Expected authenticate, got \(decoded)")
        }
    }

    func testAuthenticateEmptyToken() throws {
        let data = Data(#"{"type":"authenticate","payload":{"token":""}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ClientMessage.self, from: data))
    }

    func testAuthenticateJSON() throws {
        let payload = AuthenticatePayload(token: "my-token")
        let message = ClientMessage.authenticate(payload)
        let data = try JSONEncoder().encode(message)
        let json = try JSONProbe(data: data)

        XCTAssertEqual(try json.string("type"), "authenticate")
        XCTAssertEqual(try json.object("payload").string("token"), "my-token")
    }

    // MARK: - ServerInfo with instanceIdentifier

    func testServerInfoWithInstanceIdentifier() throws {
        let info = ServerInfo(
            appName: "TestApp",
            bundleIdentifier: "com.test.app",
            deviceName: "iPhone",
            systemVersion: "18.0",
            screenWidth: 393,
            screenHeight: 852,
            instanceId: "session-1",
            instanceIdentifier: "my-instance",
            listeningPort: 49152,
            tlsActive: true
        )

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ServerInfo.self, from: data)

        XCTAssertEqual(decoded.instanceIdentifier, "my-instance")
    }

    func testServerInfoWithoutInstanceIdentifierFails() throws {
        let json = """
        {
            "appName": "TestApp",
            "bundleIdentifier": "com.test",
            "deviceName": "iPhone",
            "systemVersion": "18.0",
            "screenWidth": 393,
            "screenHeight": 852
        }
        """
        let data = Data(json.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ServerInfo.self, from: data))
    }

    // MARK: - Wire format contract

    func testAuthRequiredFromRawJSON() throws {
        let json = """
        {"type":"authRequired"}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: data)
        if case .authRequired = decoded {} else {
            XCTFail("Expected authRequired from raw JSON")
        }
    }

    func testAuthFailedFromRawJSON() throws {
        let json = """
        {"type":"error","payload":{"kind":"authFailure","message":"Bad token"}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: data)
        if case .error(let serverError) = decoded {
            XCTAssertEqual(serverError.kind, .authFailure)
            XCTAssertEqual(serverError.message, "Bad token")
        } else {
            XCTFail("Expected error(authFailure) from raw JSON")
        }
    }

    func testAuthenticateFromRawJSON() throws {
        let json = """
        {"type":"authenticate","payload":{"token":"abc123"}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)
        if case .authenticate(let payload) = decoded {
            XCTAssertEqual(payload.token, "abc123")
        } else {
            XCTFail("Expected authenticate from raw JSON")
        }
    }

    // MARK: - Session Locking

    func testSessionLockedEncodeDecode() throws {
        let payload = SessionLockedPayload(
            message: "Session is locked by another driver.",
            activeConnections: 1
        )
        let message = ServerMessage.sessionLocked(payload)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: data)

        if case .sessionLocked(let decodedPayload) = decoded {
            XCTAssertEqual(
                decodedPayload.message,
                "Session is locked by another driver."
            )
            XCTAssertEqual(decodedPayload.activeConnections, 1)
        } else {
            XCTFail("Expected sessionLocked, got \(decoded)")
        }
    }

    func testSessionLockedFromRawJSON() throws {
        let json = """
        {"type":"sessionLocked","payload":{"message":"Locked by driver","activeConnections":1}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: data)
        if case .sessionLocked(let payload) = decoded {
            XCTAssertEqual(payload.message, "Locked by driver")
            XCTAssertEqual(payload.activeConnections, 1)
        } else {
            XCTFail("Expected sessionLocked from raw JSON")
        }
    }

    // MARK: - Driver ID

    func testAuthenticateWithDriverId() throws {
        let payload = AuthenticatePayload(token: "my-token", driverId: "agent-1")
        let message = ClientMessage.authenticate(payload)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)

        if case .authenticate(let decodedPayload) = decoded {
            XCTAssertEqual(decodedPayload.token, "my-token")
            XCTAssertEqual(decodedPayload.driverId, "agent-1")
        } else {
            XCTFail("Expected authenticate with driverId")
        }
    }

    func testAuthenticateNilDriverIdOmittedFromJSON() throws {
        let payload = AuthenticatePayload(token: "test")
        let data = try JSONEncoder().encode(payload)
        let json = try JSONProbe(data: data)

        XCTAssertEqual(try json.string("token"), "test")
        try json.assertMissing("driverId")
    }
}
