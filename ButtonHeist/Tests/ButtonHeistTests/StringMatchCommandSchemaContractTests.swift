import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
@_spi(ButtonHeistInternals) import ThePlans
@_spi(ButtonHeistInternals) import TheScore

final class StringMatchCommandSchemaContractTests: XCTestCase {

    @ButtonHeistActor
    func testAccessibilityTargetAcceptsContainsStringMatchObject() async throws {
        guard let target = try decodedAccessibilityTarget(target: accessibilityTargetValue([
            "checks": .array([
                predicateCheckValue(kind: "label", match: stringMatchValue(mode: "contains", value: "Pay")),
            ]),
        ])),
              case .predicate(let matcher, _) = target else {
            return XCTFail("Expected .matcher")
        }

        XCTAssertEqual(matcher.checks, [.label(.contains("Pay"))])
    }

    @ButtonHeistActor
    func testAccessibilityTargetAcceptsIsEmptyStringMatchObject() async throws {
        guard let target = try decodedAccessibilityTarget(target: accessibilityTargetValue([
            "checks": .array([
                predicateCheckValue(kind: "value", match: stringMatchIsEmptyValue()),
            ]),
        ])),
              case .predicate(let matcher, _) = target else {
            return XCTFail("Expected .matcher")
        }

        XCTAssertEqual(matcher.checks, [.value(.isEmpty)])
    }

    @ButtonHeistActor
    func testAccessibilityTargetAcceptsExactStringMatchObject() async throws {
        guard let target = try decodedAccessibilityTarget(target: accessibilityTargetValue([
            "checks": .array([
                predicateCheckValue(kind: "label", match: stringMatchValue(mode: "exact", value: "Pay")),
            ]),
        ])),
              case .predicate(let matcher, _) = target else {
            return XCTFail("Expected .matcher")
        }

        XCTAssertEqual(matcher.checks, [.label(.exact("Pay"))])
    }

    @ButtonHeistActor
    func testAccessibilityTargetAcceptsRepeatedStringChecks() async throws {
        guard let target = try decodedAccessibilityTarget(target: accessibilityTargetValue([
            "checks": .array([
                predicateCheckValue(kind: "label", match: stringMatchValue(mode: "prefix", value: "foo")),
                predicateCheckValue(kind: "label", match: stringMatchValue(mode: "contains", value: "bar")),
                predicateCheckValue(kind: "label", match: stringMatchValue(mode: "suffix", value: "baz")),
            ]),
        ])),
              case .predicate(let matcher, _) = target else {
            return XCTFail("Expected .matcher")
        }

        XCTAssertEqual(matcher.checks, [
            .label(.prefix("foo")),
            .label(.contains("bar")),
            .label(.suffix("baz")),
        ])
    }

    @ButtonHeistActor
    func testAccessibilityTargetAcceptsOrderedChecks() async throws {
        guard let target = try decodedAccessibilityTarget(target: accessibilityTargetValue([
            "checks": .array([
                predicateCheckValue(kind: "label", match: stringMatchValue(mode: "prefix", value: "foo")),
                predicateCheckValue(kind: "label", match: stringMatchValue(mode: "contains", value: "bar")),
                predicateCheckValue(kind: "traits", values: [.string("button")]),
                predicateCheckValue(
                    kind: "exclude",
                    check: predicateCheckValue(kind: "traits", values: [.string("notEnabled")])
                ),
            ]),
        ])),
              case .predicate(let matcher, _) = target else {
            return XCTFail("Expected .matcher")
        }

        XCTAssertEqual(matcher.checks, [
            .label(.prefix("foo")),
            .label(.contains("bar")),
            .traits([.button]),
            .exclude(.traits([.notEnabled])),
        ])
    }

    @ButtonHeistActor
    func testAccessibilityTargetRejectsFlatMatcherFields() async throws {
        let cases: [(String, HeistValue)] = [
            ("object", stringMatchValue(mode: "exact", value: "Pay")),
            ("array", .array([stringMatchValue(mode: "exact", value: "Pay")])),
            ("raw", .string("Pay")),
        ]
        for (name, value) in cases {
            XCTAssertThrowsError(try decodedAccessibilityTarget(target: accessibilityTargetValue([
                "label": value,
            ])), name) { error in
                XCTAssertTrue(String(describing: error).contains("label"), "Unexpected error: \(error)")
            }
        }
    }

    @ButtonHeistActor
    func testGetInterfaceRejectsFlatMatcherFields() async throws {
        let (fence, _) = makeConnectedFence()

        let cases: [(String, HeistValue)] = [
            ("object", stringMatchValue(mode: "exact", value: "Pay")),
            ("array", .array([stringMatchValue(mode: "exact", value: "Pay")])),
            ("raw", .string("Pay")),
        ]
        for (_, value) in cases {
            let response = try await fence.execute(command: .getInterface, values: ["label": value])
            assertError(response, contains: "valid get_interface parameter")
        }
    }

    @ButtonHeistActor
    func testGetInterfaceAcceptsObjectStringMatchInSubtreeElement() async throws {
        let (fence, mockConn) = makeConnectedFence()

        _ = try await fence.execute(command: .getInterface, values: [
            "subtree": accessibilityTargetValue([
                "checks": .array([
                    predicateCheckValue(kind: "label", match: stringMatchValue(mode: "contains", value: "Pay")),
                ]),
            ]),
        ])

        guard let (message, _) = mockConn.sent.last,
              case .requestInterface(let query) = message,
              case .predicate(let matcher, nil) = query.subtree else {
            return XCTFail("Expected subtree element query, got \(String(describing: mockConn.sent.last))")
        }

        XCTAssertEqual(matcher.checks, [.label(.contains("Pay"))])
    }

    @ButtonHeistActor
    func testGetInterfaceRejectsRawStringMatchInSubtreeElement() async throws {
        let (fence, _) = makeConnectedFence()

        let response = try await fence.execute(command: .getInterface, values: [
            "subtree": accessibilityTargetValue([
                "label": .string("Pay"),
            ]),
        ])

        guard case .error(let failure) = response else {
            return XCTFail("Expected error response")
        }
        let message = failure.message
        XCTAssertTrue(message.contains("subtree.label"), message)
        XCTAssertTrue(message.contains("label"), message)
    }

    func testPredicateAcceptsStringMatchObjectInTarget() throws {
        let predicate = try TheFence.ExpectationPayload.parseRequiredPredicate(.object([
            "type": .string("exists"),
            "target": accessibilityTargetValue([
                "checks": .array([
                    predicateCheckValue(kind: "label", match: stringMatchValue(mode: "contains", value: "Pay")),
                ]),
            ]),
        ]))

        XCTAssertEqual(predicate, .exists(.predicate(ElementPredicate(label: .contains("Pay")))))
    }

    func testPredicateAcceptsRepeatedStringChecksInTarget() throws {
        let predicate = try TheFence.ExpectationPayload.parseRequiredPredicate(.object([
            "type": .string("exists"),
            "target": accessibilityTargetValue([
                "checks": .array([
                    predicateCheckValue(kind: "label", match: stringMatchValue(mode: "prefix", value: "foo")),
                    predicateCheckValue(kind: "label", match: stringMatchValue(mode: "contains", value: "bar")),
                    predicateCheckValue(kind: "label", match: stringMatchValue(mode: "suffix", value: "baz")),
                ]),
            ]),
        ]))

        XCTAssertEqual(predicate, .exists(.element(
            .label(.prefix("foo")),
            .label(.contains("bar")),
            .label(.suffix("baz"))
        )))
    }

    func testPredicateAcceptsOrderedChecksInTarget() throws {
        let predicate = try TheFence.ExpectationPayload.parseRequiredPredicate(.object([
            "type": .string("exists"),
            "target": accessibilityTargetValue([
                "checks": .array([
                    predicateCheckValue(kind: "label", match: stringMatchValue(mode: "prefix", value: "foo")),
                    predicateCheckValue(kind: "label", match: stringMatchValue(mode: "contains", value: "bar")),
                    predicateCheckValue(kind: "traits", values: [.string("button")]),
                ]),
            ]),
        ]))

        XCTAssertEqual(predicate, .exists(.element(
            .label(.prefix("foo")),
            .label(.contains("bar")),
            .traits([.button])
        )))
    }

    func testPredicateSchemaLeavesPropertySpecificUpdateMatchesToCanonicalDecoder() throws {
        let predicateSpec = try XCTUnwrap(TheFence.Command.action.descriptor.parameter(named: "expect"))
        let assertions = try XCTUnwrap(
            predicateSpec.objectProperties.first { $0.key == "assertions" }
        )
        let specsByKey = Dictionary(uniqueKeysWithValues: assertions.arrayItemProperties.map { ($0.key, $0) })

        XCTAssertEqual(specsByKey["before"]?.type, .object)
        XCTAssertEqual(specsByKey["after"]?.type, .object)
        XCTAssertEqual(specsByKey["before"]?.objectProperties, [])
        XCTAssertEqual(specsByKey["after"]?.objectProperties, [])
    }

    func testPredicateSchemaUsesCanonicalRootTypesAndExposesAnnouncementMatch() throws {
        let specsByKey = Dictionary(
            uniqueKeysWithValues: FenceParameterBlocks.expect.objectProperties.map { ($0.key, $0) }
        )

        XCTAssertEqual(specsByKey["type"]?.enumValues, AccessibilityPredicate.wireTypeValues)
        XCTAssertEqual(specsByKey["match"]?.type, .stringMatch)
        XCTAssertEqual(specsByKey["match"]?.required, false)
    }

    @ButtonHeistActor
    private func decodedAccessibilityTarget(target: HeistValue) throws -> AccessibilityTarget? {
        try TheFence.HeistValuePayloadDecoder.decode(
            target,
            field: "target",
            as: AccessibilityTarget.self
        )
    }
}

private func assertError(
    _ response: FenceResponse,
    contains expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .error(let failure) = response else {
        return XCTFail("Expected error response", file: file, line: line)
    }
    XCTAssertTrue(
        failure.message.contains(expected),
        "Expected error containing '\(expected)', got: \(failure.message)",
        file: file,
        line: line
    )
}

private func stringMatchIsEmptyValue() -> HeistValue {
    .object([
        "mode": .string("isEmpty"),
    ])
}
