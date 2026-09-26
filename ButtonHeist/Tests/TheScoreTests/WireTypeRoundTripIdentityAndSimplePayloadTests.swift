import ButtonHeistTestSupport
import XCTest
import ThePlans
import AccessibilitySnapshotModel
@_spi(ButtonHeistInternals) @testable import TheScore

final class WireTypeRoundTripTests: XCTestCase {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    // MARK: - ButtonHeistVersion

    func testButtonHeistVersionRoundTripsAsWireString() throws {
        let version: ButtonHeistVersion = "1.2.3"

        let data = try encoder.encode(version)

        XCTAssertEqual(String(bytes: data, encoding: .utf8), #""1.2.3""#)
        XCTAssertEqual(try decoder.decode(ButtonHeistVersion.self, from: data), version)
    }

    func testCurrentProductVersionRoundTripsExactly() throws {
        let expected: ButtonHeistVersion = buttonHeistVersion
        let envelope = RequestEnvelope(message: .ping)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(RequestEnvelope.self, from: data)

        XCTAssertEqual(decoded.buttonHeistVersion, expected)
        XCTAssertEqual(decoded.message, .ping)
    }

    func testRequestEnvelopeRejectsInvalidButtonHeistVersion() throws {
        let data = Data("""
        {"buttonHeistVersion":"1.0","type":"ping"}
        """.utf8)

        XCTAssertThrowsError(try decoder.decode(RequestEnvelope.self, from: data)) { error in
            assertDecodingError(error, contains: ["Button Heist version must be a MAJOR.MINOR.PATCH semantic version"])
        }
    }

    // MARK: - RequestID

    func testRequestIDRoundTripsAsWireString() throws {
        let requestID: RequestID = "request-1"

        let data = try encoder.encode(requestID)

        XCTAssertEqual(String(bytes: data, encoding: .utf8), #""request-1""#)
        XCTAssertEqual(try decoder.decode(RequestID.self, from: data), requestID)
    }

    func testRequestEnvelopeRejectsBlankRequestID() throws {
        for requestID in ["", " \n\t"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "buttonHeistVersion": buttonHeistVersion.description,
                "requestId": requestID,
                "type": "ping",
            ])

            XCTAssertThrowsError(try decoder.decode(RequestEnvelope.self, from: data)) { error in
                assertDecodingError(error, contains: ["value must not be blank"])
            }
        }
    }

    // MARK: - AccessibilityPredicate

    func testAccessibilityPredicateWireContractValuesStayStable() {
        XCTAssertEqual(
            AccessibilityPredicate.wireTypeValues,
            ["exists", "missing", "notification", "changed"]
        )
    }

    // MARK: - ScrollEdge

    func testScrollEdgeRawValues() {
        XCTAssertEqual(ScrollEdge.top.rawValue, "top")
        XCTAssertEqual(ScrollEdge.bottom.rawValue, "bottom")
        XCTAssertEqual(ScrollEdge.left.rawValue, "left")
        XCTAssertEqual(ScrollEdge.right.rawValue, "right")
    }

    // MARK: - ScrollDirection

    func testScrollDirectionRawValues() {
        XCTAssertEqual(ScrollDirection.up.rawValue, "up")
        XCTAssertEqual(ScrollDirection.down.rawValue, "down")
        XCTAssertEqual(ScrollDirection.left.rawValue, "left")
        XCTAssertEqual(ScrollDirection.right.rawValue, "right")
    }

    // MARK: - EditActionTarget

    func testEditActionTargetRoundTrip() throws {
        for action in EditAction.allCases {
            let target = EditActionTarget(action: action)
            let data = try encoder.encode(target)
            let decoded = try decoder.decode(EditActionTarget.self, from: data)
            XCTAssertEqual(decoded.action, action)
        }
    }

    func testEditActionTargetRejectsUnknownPayloadKey() throws {
        let data = Data(#"{"action":"paste","foo":"bar"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(EditActionTarget.self, from: data)) { error in
            assertDecodingError(error, contains: [#"Unknown edit action target field "foo""#])
        }
    }

    // MARK: - Simple Command Payloads

    func testTypeTextTargetRejectsUnknownPayloadKey() throws {
        let data = Data(#"{"text":"hello","mode":"append","foo":"bar"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(TypeTextTarget.self, from: data)) { error in
            assertDecodingError(error, contains: [#"Unknown type text target field "foo""#])
        }
    }

    func testTypeTextStringRefLoweringRejectsEmptyResolvedText() throws {
        let command = HeistActionCommand.typeText(
            reference: "item",
            target: .predicate(ElementPredicate(label: "Add item"))
        )

        XCTAssertThrowsError(try command.resolve(in: HeistExecutionEnvironment(strings: ["item": ""]))) { error in
            XCTAssertEqual(error as? TextInputTextError, .emptyAppend)
        }
    }

    func testTypeTextStringRefLoweringAllowsEmptyResolvedTextWhenReplacingExisting() throws {
        let command = HeistActionCommand.typeText(
            reference: "item",
            target: .predicate(ElementPredicate(label: "Add item")),
            mode: .replace
        )

        let message = try command.resolve(in: HeistExecutionEnvironment(strings: ["item": ""]))

        guard case .typeText(let payload) = message.payload else {
            return XCTFail("Expected typeText runtime message, got \(message)")
        }
        XCTAssertEqual(payload.text, .replacing(""))
    }

    func testSetPasteboardTargetRejectsUnknownPayloadKey() throws {
        let data = Data(#"{"text":"hello","foo":"bar"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(SetPasteboardTarget.self, from: data)) { error in
            assertDecodingError(error, contains: [#"Unknown pasteboard target field "foo""#])
        }
    }

    func testSetPasteboardTargetRejectsEmptyText() throws {
        let data = Data(#"{"text":""}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(SetPasteboardTarget.self, from: data)) { error in
            assertDecodingError(error, contains: ["pasteboard text must be non-empty"])
        }
    }

    func testAuthenticatePayloadRejectsUnknownPayloadKey() throws {
        let data = Data(#"{"token":"secret","foo":"bar"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(AuthenticatePayload.self, from: data)) { error in
            assertDecodingError(error, contains: [#"Unknown authenticate payload field "foo""#])
        }
    }

    func assertDecodingError(
        _ error: Error,
        contains fragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case DecodingError.dataCorrupted(let context) = error else {
            XCTFail("Expected DecodingError.dataCorrupted, got \(error)", file: file, line: line)
            return
        }
        for fragment in fragments {
            XCTAssertTrue(
                context.debugDescription.contains(fragment),
                context.debugDescription,
                file: file,
                line: line
            )
        }
    }
}
