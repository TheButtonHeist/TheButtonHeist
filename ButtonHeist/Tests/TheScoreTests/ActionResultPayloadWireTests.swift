import ButtonHeistTestSupport
import XCTest
import TheScore

final class ActionResultPayloadWireTests: XCTestCase {
    func testActionResultValuePayloadWireShape() throws {
        let result = ActionResult.success(payload: .typeText("Hi"))
        let data = try JSONEncoder().encode(result)
        let json = try JSONProbe(data: data)
        XCTAssertEqual(try json.string("payload"), "Hi")
    }

    func testActionResultScreenshotPayloadWireShape() throws {
        let screen = ScreenPayload(
            pngData: "png",
            width: 390,
            height: 844,
            timestamp: Date(timeIntervalSince1970: 0),
            interface: makeTestInterface(elements: [], timestamp: Date(timeIntervalSince1970: 0))
        )
        let result = ActionResult.success(payload: .screenshot(screen))

        let data = try JSONEncoder().encode(result)
        let json = try JSONProbe(data: data)
        let payload = try json.object("payload")
        XCTAssertEqual(try payload.string("pngData"), "png")
        XCTAssertEqual(try payload.double("width"), 390)
        XCTAssertEqual(try payload.double("height"), 844)
        _ = try payload.object("interface")

        let decoded = try JSONDecoder().decode(ActionResult.self, from: data)
        XCTAssertEqual(decoded.payload, .screenshot(screen))
    }

    func testActionResultRejectsDisplacedHeistPayloadContract() {
        let data = Data("""
        {
          "outcome": { "kind": "success" },
          "method": "heistPlan",
          "payload": { "steps": [], "durationMs": 42 },
          "evidence": { "observation": { "kind": "none" } }
        }
        """.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ActionResult.self, from: data))
    }

    func testActionResultRotorPayloadWireShape() throws {
        let rotor = RotorResult(
            rotor: "Errors",
            direction: .next,
            foundElement: HeistElement(
                semantics: HeistElement.Semantics(
                    spokenDescription: "Email",
                    assertable: HeistElement.Semantics.AssertableProperties(
                        label: "Email",
                        value: nil,
                        identifier: nil
                    ),
                    respondsToUserInteraction: true
                ),
                geometry: HeistElement.Geometry(
                    screen: .onscreen(
                        frame: .available(ScreenRect(x: 0, y: 0, width: 0, height: 0)),
                        activationPoint: .unavailable
                    ),
                    view: .available(.init(
                        ownerPath: .root,
                        frame: ViewRect(x: 0, y: 0, width: 0, height: 0),
                        activationPoint: ViewPoint(x: 0, y: 0)
                    ))
                )
            ),
            textRange: RotorTextRange(text: "@maria", startOffset: 10, endOffset: 16, rangeDescription: "[10..<16]")
        )
        let result = ActionResult.success(payload: .rotor(rotor))
        let data = try JSONEncoder().encode(result)
        let json = try JSONProbe(data: data)
        let payload = try json.object("payload")
        XCTAssertEqual(try payload.string("rotor"), "Errors")
        XCTAssertEqual(try payload.string("direction"), "next")
        let foundElement = try payload.object("foundElement")
        let semantics = try foundElement.object("semantics")
        let assertable = try semantics.object("assertable")
        XCTAssertEqual(try assertable.string("label"), "Email")
        let geometry = try foundElement.object("geometry")
        let view = try geometry.object("view")
        XCTAssertEqual(try view.string("availability"), "available")
        _ = try view.object("frame")
        _ = try view.object("activationPoint")
        XCTAssertNoThrow(try foundElement.assertMissing("heistId"), "heistId must never appear on the wire")
        let textRange = try payload.object("textRange")
        XCTAssertEqual(try textRange.string("text"), "@maria")
        XCTAssertEqual(try textRange.int("startOffset"), 10)
        XCTAssertEqual(try textRange.int("endOffset"), 16)
        XCTAssertEqual(try textRange.string("rangeDescription"), "[10..<16]")
    }

    func testActionResultPayloadDecodesFromExplicitJSON() throws {
        let json = """
        {
          "type": "actionResult",
          "payload": {
            "outcome": { "kind": "success" },
            "method": "typeText",
            "payload": "Hello",
            "evidence": { "observation": { "kind": "none" } }
          }
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: data)
        guard case .actionResult(let result) = decoded,
              case .typeText(let string?) = result.payload else {
            XCTFail("Expected actionResult with .typeText payload, got \(decoded)")
            return
        }
        XCTAssertEqual(result.method, .typeText)
        XCTAssertEqual(string, "Hello")
    }

    func testActionResultWithoutOptionalFieldsFromExplicitJSON() throws {
        let json = """
        {"type":"actionResult","payload":{"outcome":{"kind":"success"},"method":"oneFingerTap","evidence":{"observation":{"kind":"none"}}}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: data)

        if case .actionResult(let result) = decoded {
            XCTAssertTrue(result.outcome.isSuccess)
            XCTAssertEqual(result.method, .oneFingerTap)
            XCTAssertEqual(result.payload, .oneFingerTap)
            XCTAssertNil(result.message)
        } else {
            XCTFail("Expected actionResult, got \(decoded)")
        }
    }
}
