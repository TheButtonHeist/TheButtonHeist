import XCTest
import ButtonHeistTestSupport
import TheScore

final class SnapshotTests: XCTestCase {

    func testEmptyPayload() throws {
        let payload = makeTestInterface(elements: [], timestamp: Date())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Interface.self, from: data)

        XCTAssertTrue(decoded.projectedElements.isEmpty)
    }

    func testPayloadWithMultipleElements() throws {
        let elements = (0..<10).map { i in
            makeTestHeistElement(
                description: "Element \(i)",
                label: "Label \(i)",
                value: nil,
                identifier: "id_\(i)",
                frameX: Double(i * 10), frameY: 0,
                frameWidth: 100, frameHeight: 44,
                actions: []
            )
        }

        let payload = makeTestInterface(elements: elements, timestamp: Date())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Interface.self, from: data)

        XCTAssertEqual(decoded.projectedElements.count, 10)
        for i in 0..<10 {
            XCTAssertEqual(
                decoded.projectedElements[i].semantics.assertable.label,
                "Label \(i)"
            )
        }
    }

    func testTimestampPreservation() throws {
        let timestamp = Date(timeIntervalSince1970: 1700000000)
        let payload = makeTestInterface(elements: [], timestamp: timestamp)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Interface.self, from: data)

        // ISO8601 preserves to second precision
        XCTAssertEqual(
            Int(decoded.timestamp.timeIntervalSince1970),
            Int(timestamp.timeIntervalSince1970)
        )
    }
}
