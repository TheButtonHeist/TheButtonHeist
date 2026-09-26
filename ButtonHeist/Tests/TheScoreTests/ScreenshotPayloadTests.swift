import XCTest
import ButtonHeistTestSupport
import ThePlans
import TheScore

final class ScreenshotPayloadTests: XCTestCase {

    func testDefaultTimestamp() {
        let before = Date()
        let payload = ScreenPayload(
            pngData: "data",
            width: 100,
            height: 200,
            interface: Interface(timestamp: Date(), tree: [])
        )
        let after = Date()

        XCTAssertGreaterThanOrEqual(payload.timestamp, before)
        XCTAssertLessThanOrEqual(payload.timestamp, after)
    }

    func testEncodingRoundTripWithInterfaceEvidence() throws {
        let element = makeTestHeistElement(
            description: "Total $12.34",
            label: "Total",
            value: "$12.34",
            identifier: "total",
            traits: [.staticText],
            frameX: 12,
            frameY: 680,
            frameWidth: 240,
            frameHeight: 32,
            activationPointEvidence: .explicit(ScreenPoint(x: 132, y: 696)),
            actions: []
        )
        let payload = ScreenPayload(
            pngData: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
            width: 1206,
            height: 2622,
            interface: makeTestInterface(elements: [element], timestamp: Date(timeIntervalSince1970: 123))
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScreenPayload.self, from: data)

        XCTAssertEqual(payload.pngData, decoded.pngData)
        XCTAssertEqual(payload.width, decoded.width)
        XCTAssertEqual(payload.height, decoded.height)
        XCTAssertEqual(decoded.interface?.projectedElements, [element])
        let decodedElement = try XCTUnwrap(decoded.interface?.projectedElements.first)
        guard case .onscreen(let frame, let activationPoint) = decodedElement.geometry.screen else {
            return XCTFail("Expected onscreen geometry")
        }
        XCTAssertEqual(frame.rect?.y.value, 680)
        XCTAssertEqual(activationPoint.point?.y, 696)
    }

    func testEncodingRoundTripWithoutInterfaceEvidence() throws {
        let payload = ScreenPayload(
            pngData: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
            width: 1206,
            height: 2622
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScreenPayload.self, from: data)

        XCTAssertEqual(payload.pngData, decoded.pngData)
        XCTAssertEqual(payload.width, decoded.width)
        XCTAssertEqual(payload.height, decoded.height)
        XCTAssertNil(decoded.interface)
    }

    func testAdmissionRejectsInvalidDimensions() {
        for dimensions in [(0.0, 1.0), (-1, 1), (.nan, 1), (1, 0), (1, .infinity)] {
            XCTAssertNil(ScreenPayload.admit(pngData: "data", width: dimensions.0, height: dimensions.1))
        }
    }

    func testDecodingRejectsInvalidDimensions() {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        let invalidDimensions = [
            ("0", "1"),
            ("-1", "1"),
            (#""NaN""#, "1"),
            ("1", #""Infinity""#),
        ]

        for dimensions in invalidDimensions {
            let json = """
            {
              "pngData":"data",
              "width":\(dimensions.0),
              "height":\(dimensions.1),
              "timestamp":0
            }
            """
            XCTAssertThrowsError(try decoder.decode(ScreenPayload.self, from: Data(json.utf8)))
        }
    }
}
