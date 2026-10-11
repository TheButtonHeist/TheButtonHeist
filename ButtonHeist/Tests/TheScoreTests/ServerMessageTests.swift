import ButtonHeistTestSupport
import XCTest
import ThePlans
import TheScore

final class ServerMessageTests: XCTestCase {

    func testInfoEncodeDecode() throws {
        let info = ServerInfo(
            appName: "TestApp",
            bundleIdentifier: "com.test.app",
            deviceName: "iPhone",
            systemVersion: "17.0",
            screenWidth: 390,
            screenHeight: 844,
            instanceId: "test-session",
            instanceIdentifier: "test",
            listeningPort: 49152,
            tlsActive: true
        )
        let message = ServerMessage.info(info)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: data)

        if case .info(let decodedInfo) = decoded {
            XCTAssertEqual(decodedInfo.appName, "TestApp")
            XCTAssertEqual(decodedInfo.bundleIdentifier, "com.test.app")
        } else {
            XCTFail("Expected info, got \(decoded)")
        }
    }

    func testStatusEncodeDecode() throws {
        let payload = StatusPayload(
            identity: StatusIdentity(
                appName: "ReachableApp",
                bundleIdentifier: "com.test.reachable",
                appBuild: "42",
                deviceName: "iPhone",
                systemVersion: "18.0",
                buttonHeistVersion: "5.0.0"
            ),
            session: StatusSession(
                active: true,
                watchersAllowed: false,
                activeConnections: 1
            )
        )
        let message = ServerMessage.status(payload)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: data)

        if case .status(let decodedPayload) = decoded {
            XCTAssertEqual(decodedPayload.identity.appName, "ReachableApp")
            XCTAssertEqual(decodedPayload.identity.bundleIdentifier, "com.test.reachable")
            XCTAssertEqual(decodedPayload.session.active, true)
            XCTAssertEqual(decodedPayload.session.activeConnections, 1)
        } else {
            XCTFail("Expected status, got \(decoded)")
        }
    }

    func testInterfaceEncodeDecode() throws {
        let element = makeTestHeistElement(
            description: "Button",
            label: "Submit",
            identifier: "submit_btn",
            frameX: 10, frameY: 20, frameWidth: 100, frameHeight: 44,
            actions: [.activate]
        )
        let payload = makeTestInterface(elements: [element], timestamp: Date())
        let message = ServerMessage.interface(payload)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ServerMessage.self, from: data)

        if case .interface(let decodedPayload) = decoded {
            XCTAssertEqual(decodedPayload.projectedElements.count, 1)
            XCTAssertEqual(decodedPayload.projectedElements[0].semantics.assertable.label, "Submit")
        } else {
            XCTFail("Expected interface, got \(decoded)")
        }
    }

    func testPongEncodeDecode() throws {
        let payload = PongPayload(
            buttonHeistVersion: "2026.5.22",
            appName: "TestApp",
            bundleIdentifier: "com.test.app",
            appVersion: "1.2.3",
            appBuild: "456",
            serverInstanceIdentifier: "server-1",
            serverTimestampMs: 1_700_000_000_000
        )
        let message = ServerMessage.pong(payload)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: data)

        if case .pong(let decodedPayload) = decoded {
            XCTAssertEqual(decodedPayload, payload)
        } else {
            XCTFail("Expected pong, got \(decoded)")
        }
    }

    func testPongRejectsMissingPayload() throws {
        let data = Data(#"{"type":"pong"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ServerMessage.self, from: data))
    }

    func testServerMessageRejectsUnknownTopLevelField() throws {
        let data = Data(#"{"type":"serverHello","staleField":"value"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ServerMessage.self, from: data)) { error in
            XCTAssertTrue("\(error)".contains("staleField"), "\(error)")
        }
    }

    func testNoPayloadServerMessageRejectsStrayPayload() throws {
        let data = Data(#"{"type":"serverHello","payload":{"junk":true}}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ServerMessage.self, from: data)) { error in
            XCTAssertTrue("\(error)".contains("serverHello must not include a payload"), "\(error)")
        }
    }

    func testNoPayloadResponseEnvelopeRejectsStrayPayload() throws {
        let data = Data("""
        {"buttonHeistVersion":"\(TheScore.buttonHeistVersion)","type":"serverHello","payload":{"junk":true}}
        """.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ResponseEnvelope.self, from: data)) { error in
            XCTAssertTrue("\(error)".contains("serverHello must not include a payload"), "\(error)")
        }
    }

    func testResponseEnvelopeRejectsMissingPongPayload() throws {
        let data = Data("""
        {"buttonHeistVersion":"\(TheScore.buttonHeistVersion)","requestId":"00000000-0000-4000-8000-000000000001","type":"pong"}
        """.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ResponseEnvelope.self, from: data))
    }

    func testResponseEnvelopeRejectsClientOnlyMessageTypeAtTypedBoundary() {
        let data = Data("""
        {"buttonHeistVersion":"\(TheScore.buttonHeistVersion)","type":"clientHello"}
        """.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ResponseEnvelope.self, from: data)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
            XCTAssertEqual(context.debugDescription, "Unsupported server wire message type: clientHello")
        }
    }

    func testErrorEncodeDecode() throws {
        let message = ServerMessage.error(ServerError(kind: .general, message: "Connection failed"))
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: data)

        if case .error(let serverError) = decoded {
            XCTAssertEqual(serverError.kind, .general)
            XCTAssertEqual(serverError.message, "Connection failed")
        } else {
            XCTFail("Expected error, got \(decoded)")
        }
    }

    func testErrorWireShape() throws {
        let message = ServerMessage.error(ServerError(kind: .general, message: "disk full"))
        let data = try JSONEncoder().encode(message)
        let json = try JSONProbe(data: data)
        XCTAssertEqual(try json.string("type"), "error")
        let payload = try json.object("payload")
        XCTAssertEqual(try payload.string("kind"), "general")
        XCTAssertEqual(try payload.string("message"), "disk full")
    }

    func testErrorDecodesFromExplicitJSON() throws {
        let json = """
        {"type":"error","payload":{"kind":"general","message":"oops"}}
        """
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
        guard case .error(let serverError) = decoded else {
            XCTFail("Expected error message, got \(decoded)")
            return
        }
        XCTAssertEqual(serverError.kind, .general)
        XCTAssertEqual(serverError.message, "oops")
    }

    func testHeistResultEncodeDecode() throws {
        let result = try HeistResult(steps: [], durationMs: 42)
        let data = try JSONEncoder().encode(ServerMessage.heistResult(result))
        let json = try JSONProbe(data: data)

        XCTAssertEqual(try json.string("type"), "heistResult")
        XCTAssertEqual(try json.object("payload").int("durationMs"), 42)
        guard case .heistResult(let decoded) = try JSONDecoder().decode(
            ServerMessage.self,
            from: data
        ) else {
            return XCTFail("Expected heistResult")
        }
        XCTAssertEqual(decoded, result)
    }

    func testScreenEncodeDecode() throws {
        let element = makeTestHeistElement(
            description: "Pay",
            label: "Pay",
            identifier: "pay_button",
            traits: [.button],
            frameX: 20,
            frameY: 700,
            frameWidth: 160,
            frameHeight: 48,
            activationPointEvidence: .explicit(ScreenPoint(x: 100, y: 724)),
            actions: [.activate]
        )
        let payload = ScreenPayload(
            pngData: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
            width: 390,
            height: 844,
            interface: makeTestInterface(elements: [element], timestamp: Date(timeIntervalSince1970: 42))
        )
        let message = ServerMessage.screen(payload)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ServerMessage.self, from: data)

        if case .screen(let decodedPayload) = decoded {
            XCTAssertEqual(decodedPayload.pngData, payload.pngData)
            XCTAssertEqual(decodedPayload.width, 390)
            XCTAssertEqual(decodedPayload.height, 844)
            XCTAssertEqual(decodedPayload.interface?.projectedElements, [element])
            let decodedElement = try XCTUnwrap(decodedPayload.interface?.projectedElements.first)
            guard case .onscreen(let frame, let activationPoint) = decodedElement.geometry.screen else {
                return XCTFail("Expected onscreen geometry")
            }
            XCTAssertEqual(frame.rect?.x.value, 20)
            XCTAssertEqual(activationPoint.point?.x, 100)
        } else {
            XCTFail("Expected screen, got \(decoded)")
        }
    }
}
