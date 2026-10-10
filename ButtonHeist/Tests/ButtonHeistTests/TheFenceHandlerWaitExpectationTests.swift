import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
@_spi(ButtonHeistInternals) import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension TheFenceHandlerTests {

    @ButtonHeistActor
    func testParseExpectationNilWhenAbsent() async throws {
        XCTAssertNil(try parseTypedExpectation(nil))
    }

    @ButtonHeistActor
    func testParseExpectationScreenChangedObject() async throws {
        let result = try parseTypedExpectation(.object([
            "type": .string("changed"),
            "scope": .string("screen"),
            "match": stringMatchValue(mode: "exact", value: "Receipt"),
        ]))

        XCTAssertEqual(result, .screenChanged("Receipt"))
    }

    @ButtonHeistActor
    func testParseExpectationRejectsGenericChangedPredicate() async {
        XCTAssertThrowsError(try parseTypedExpectation(.object([
            "type": .string("changed"),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("scope"))
        }
    }

    func testToolRoutingUsesTypedThrows() throws {
        XCTAssertEqual(try TheFence.Command.routeToolCall(named: "perform"), .perform)

        for removedTool in ["activate", "type_text", "wait", "swipe", "scroll"] {
            XCTAssertThrowsError(try TheFence.Command.routeToolCall(named: removedTool)) { error in
                XCTAssertEqual((error as? FenceOperationRoutingError)?.message, "Unknown tool: \(removedTool)")
            }
        }
    }

    @ButtonHeistActor
    func testParseExpectationElementUpdated() async throws {
        let result = try parseTypedExpectation(.object([
            "type": .string("changed"),
            "scope": .string("elements"),
            "assertions": .array([.object([
                "type": .string("updated"),
                "target": elementPredicateValue(identifier: "slider"),
                "before": stringMatchValue(mode: "exact", value: "0"),
                "after": stringMatchValue(mode: "exact", value: "50"),
                "property": .string("value"),
            ])]),
        ]))

        XCTAssertEqual(result, .elementsChanged([
            .updated(.identifier("slider"), .value(before: "0", after: "50")),
        ]))
    }

    @ButtonHeistActor
    func testParseExpectationReportsInvalidElementPropertyAtExactField() async {
        XCTAssertThrowsError(try parseTypedExpectation(.object([
            "type": .string("changed"),
            "scope": .string("elements"),
            "assertions": .array([.object([
                "type": .string("updated"),
                "target": elementPredicateValue(identifier: "slider"),
                "property": .string("bogus"),
            ])]),
        ]))) { error in
            guard let error = error as? SchemaValidationError else {
                return XCTFail("Expected SchemaValidationError, got \(error)")
            }
            XCTAssertEqual(error.field, "expect.assertions[0].property")
            XCTAssertEqual(error.observed, "string \"bogus\"")
            XCTAssertTrue(error.expected.contains("ElementProperty"))
        }
    }

    @ButtonHeistActor
    func testParseExpectationPreservesCanonicalTargets() async throws {
        let item: HeistReferenceName = "item"
        let cases: [(HeistValue, AccessibilityPredicate)] = [
            (
                .object([
                    "type": .string("exists"),
                    "target": elementPredicateValue(label: "Cart", identifier: "cart.button"),
                ]),
                .exists(.predicate(ElementPredicate(label: "Cart", identifier: "cart.button")))
            ),
            (
                .object([
                    "type": .string("exists"),
                    "target": .object(["ref": .string("item")]),
                ]),
                .exists(.ref(item))
            ),
            (
                .object([
                    "type": .string("exists"),
                    "target": .object([
                        "container": .object([
                            "checks": .array([.object([
                                "kind": .string("scrollable"),
                                "value": .bool(true),
                            ])]),
                        ]),
                    ]),
                ]),
                .exists(.container(.matching(.scrollable(true))))
            ),
        ]

        for (value, expected) in cases {
            XCTAssertEqual(try parseTypedExpectation(value), expected)
        }
    }

    @ButtonHeistActor
    func testParseExpectationAcceptsNotificationFields() async throws {
        XCTAssertEqual(
            try parseTypedExpectation(.object([
                "type": .string("notification"),
                "text": stringMatchValue(mode: "contains", value: "Payment complete"),
                "element": elementPredicateValue(label: "Receipt"),
            ])),
            .notification(
                text: .contains("Payment complete"),
                element: ElementPredicate(label: "Receipt")
            )
        )
    }

    @ButtonHeistActor
    func testExpectationDecoderRejectsInvalidNestedShapes() async {
        let invalidValues: [HeistValue] = [
            .object([
                "type": .string("changed"),
                "scope": .string("elements"),
                "assertions": .array([.object(["type": .string("notification")])]),
            ]),
            .object([
                "type": .string("exists"),
                "target": .object([
                    "checks": .array([
                        predicateCheckValue(
                            kind: "label",
                            match: stringMatchValue(mode: "exact", value: "Done")
                        ),
                    ]),
                    "unknown": .string("never ignored"),
                ]),
            ]),
        ]

        for value in invalidValues {
            XCTAssertThrowsError(try parseTypedExpectation(value))
        }
    }
}
