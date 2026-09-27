import ButtonHeistTestSupport
import ThePlans
import XCTest
@testable import TheScore

extension AccessibilityPredicateTests {
    func testUpdatedRejectsBeforeAfterWithoutProperty() {
        assertDecodeFails(
            """
            {
              "type": "changed",
              "scope": "elements",
              "assertions": [{
                "type": "updated",
                "target": {
                  "checks": [{
                    "kind": "label",
                    "match": {"mode": "exact", "value": "Card"}
                  }]
                },
                "after": {"x": 1}
              }]
            }
            """,
            contains: "before/after require property"
        )
    }

    func testUpdatedRejectsStringChecksForTypedSetProperties() {
        let cases = [
            ("traits", "Unknown trait set match field"),
            ("actions", "Unknown action set match field"),
            ("customContent", "Unknown custom content match field"),
            ("rotors", "Unknown rotor set match field"),
        ]

        for (property, message) in cases {
            assertDecodeFails(
                """
                {
                  "type": "changed",
                  "scope": "elements",
                  "assertions": [{
                    "type": "updated",
                    "target": {
                      "checks": [{
                        "kind": "label",
                        "match": {"mode": "exact", "value": "Subject"}
                      }]
                    },
                    "property": "\(property)",
                    "after": {"mode": "exact", "value": "activate"}
                  }]
                }
                """,
                contains: message
            )
        }
    }

    func testUpdatedRejectsUnknownNestedCheckerKeys() {
        assertDecodeFails(
            """
            {
              "type": "changed",
              "scope": "elements",
              "assertions": [{
                "type": "updated",
                "target": {
                  "checks": [{
                    "kind": "label",
                    "match": {"mode": "exact", "value": "Card"}
                  }]
                },
                "property": "customContent",
                "after": {
                  "label": {"mode": "exact", "value": "Total"},
                  "unexpected": true
                }
              }]
            }
            """,
            contains: #"Unknown custom content match field "unexpected""#
        )
    }

    func testUpdatedRejectsGeometryProperties() {
        for property in ["frame", "activationPoint"] {
            assertDecodeFails(
                """
                {
                  "type": "changed",
                  "scope": "elements",
                  "assertions": [{
                    "type": "updated",
                    "target": {
                      "checks": [{
                        "kind": "label",
                        "match": {"mode": "exact", "value": "Card"}
                      }]
                    },
                    "property": "\(property)",
                    "after": {"x": 1}
                  }]
                }
                """,
                contains: "geometry, which predicates cannot reason about"
            )
        }
    }

    func testAllAuthoredPredicateCasesRoundTrip() throws {
        let predicates: [AccessibilityPredicate] = [
            .exists(.label("Done")),
            .missing(.label("Loading")),
            .notification(
                text: .contains("saved"),
                element: ElementPredicate(label: "Save")
            ),
            .screenChanged("Settings"),
            .elementsChanged,
            .elementsChanged([
                .appeared(.label("Ready")),
                .disappeared(.label("Loading")),
                .updated(
                    .label("Counter"),
                    .value(before: "A", after: "B")
                ),
            ]),
        ]

        for predicate in predicates {
            let data = try JSONEncoder().encode(predicate)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    AccessibilityPredicate.self,
                    from: data
                ),
                predicate
            )
        }
    }

    func testDecodeRejectsUnknownOrMissingRootType() {
        for json in [#"{"type":"rainbow"}"#, #"{}"#] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    AccessibilityPredicate.self,
                    from: Data(json.utf8)
                )
            )
        }
    }

    private func assertDecodeFails(
        _ json: String,
        contains expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AccessibilityPredicate.self,
                from: Data(json.utf8)
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertTrue(
                decodingMessage(error).contains(expectedMessage),
                "Expected \(expectedMessage), got \(decodingMessage(error))",
                file: file,
                line: line
            )
        }
    }

    private func decodingMessage(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context),
             DecodingError.keyNotFound(_, let context),
             DecodingError.typeMismatch(_, let context),
             DecodingError.valueNotFound(_, let context):
            return context.debugDescription
        default:
            return String(describing: error)
        }
    }
}
