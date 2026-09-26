import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

final class ElementActionRequestContractTests: XCTestCase {

    func testAccessibilityTargetFenceSchemaUsesCanonicalFields() throws {
        let targetSpec = try XCTUnwrap(
            TheFence.Command.activate.descriptor.parameters.first { $0.key == FenceParameterKey.target.rawValue }
        )
        let specsByKey = Dictionary(uniqueKeysWithValues: targetSpec.objectProperties.map { ($0.key, $0) })
        XCTAssertEqual(targetSpec.objectProperties.map(\.key), AccessibilityTarget.inlineFieldNames)
        assertPredicateChecksSchema(try XCTUnwrap(specsByKey["checks"]), file: #filePath, line: #line)
        XCTAssertEqual(try XCTUnwrap(specsByKey["ref"]).type, .string)
        XCTAssertEqual(try XCTUnwrap(specsByKey["ordinal"]).type, .integer)
        XCTAssertEqual(projectedJSONSchemaProperty("minimum", in: try XCTUnwrap(specsByKey["ordinal"])), .int(0))
        assertContainerPredicateSchema(try XCTUnwrap(specsByKey["container"]), file: #filePath, line: #line)
        XCTAssertEqual(try XCTUnwrap(specsByKey["target"]).type, .object)
    }

    func testAccessibilityTargetFenceSchemaExpandsToPublicInputDepthLimit() throws {
        let targetSpec = try XCTUnwrap(
            TheFence.Command.activate.descriptor.parameters.first { $0.key == FenceParameterKey.target.rawValue }
        )
        let terminalFieldNames = AccessibilityTarget.inlineFieldNames.filter {
            $0 != FenceParameterKey.target.rawValue
        }
        let terminalSpec = try (1..<accessibilityTargetSchemaMaximumNestingDepth).reduce(targetSpec) { currentSpec, depth in
            XCTAssertEqual(
                currentSpec.objectProperties.map(\.key),
                AccessibilityTarget.inlineFieldNames,
                "depth \(depth)"
            )
            return try XCTUnwrap(
                currentSpec.objectProperties.first { $0.key == FenceParameterKey.target.rawValue },
                "depth \(depth)"
            )
        }

        XCTAssertEqual(terminalSpec.objectProperties.map(\.key), terminalFieldNames)
        XCTAssertFalse(terminalSpec.objectProperties.contains { $0.key == FenceParameterKey.target.rawValue })
    }

    func testRotorAndScrollSchemasNestCanonicalAccessibilityTarget() throws {
        for command in [
            TheFence.Command.rotor,
            .scroll,
            .scrollToVisible,
            .scrollToEdge,
        ] {
            let target = try XCTUnwrap(
                command.descriptor.parameters.first { $0.key == FenceParameterKey.target.rawValue },
                command.rawValue
            )
            XCTAssertEqual(target.objectProperties.map(\.key), AccessibilityTarget.inlineFieldNames, command.rawValue)
            XCTAssertFalse(
                command.descriptor.parameters.contains { $0.key == FenceParameterKey.checks.rawValue },
                command.rawValue
            )
        }
    }

    @ButtonHeistActor
    func testRotorAndScrollCommandsRejectFlatTargetFields() async {
        for command in [
            TheFence.Command.rotor,
            .scroll,
            .scrollToVisible,
            .scrollToEdge,
        ] {
            await assertExecutionError(
                command: command,
                arguments: [
                    "checks": .array([
                        .object([
                            "kind": .string("identifier"),
                            "match": .object([
                                "mode": .string("exact"),
                                "value": .string("scroll_target"),
                            ]),
                        ]),
                    ]),
                ],
                contains: "valid \(command.rawValue) parameter"
            )
        }
    }

    func testAccessibilityPredicateFenceSchemaUsesCanonicalDiscriminators() throws {
        let waitDescriptor = TheFence.Command.wait.descriptor
        let predicateSpec = try XCTUnwrap(waitDescriptor.parameters.first { $0.key == FenceParameterKey.predicate.rawValue })
        let predicateType = try XCTUnwrap(predicateSpec.objectProperties.first { $0.key == FenceParameterKey.type.rawValue })
        XCTAssertEqual(predicateType.enumValues, ["exists", "missing", "notification", "changed"])
        XCTAssertEqual(
            predicateSpec.objectProperties.map(\.key),
            ["type", "target", "text", "element", "match", "scope", "assertions"]
        )
        let text = try XCTUnwrap(
            predicateSpec.objectProperties.first { $0.key == FenceParameterKey.text.rawValue }
        )
        assertStringMatchObjectSchema(text)
        let element = try XCTUnwrap(
            predicateSpec.objectProperties.first { $0.key == FenceParameterKey.element.rawValue }
        )
        XCTAssertEqual(element.objectProperties.map(\.key), ["checks"])
        let scope = try XCTUnwrap(predicateSpec.objectProperties.first { $0.key == FenceParameterKey.scope.rawValue })
        XCTAssertEqual(scope.enumValues, ["screen", "elements"])
        let assertionProperties = try arrayItemProperties(
            named: .assertions,
            in: predicateSpec,
            file: #filePath,
            line: #line
        )
        let assertionType = try XCTUnwrap(assertionProperties.first { $0.key == FenceParameterKey.type.rawValue })
        XCTAssertEqual(assertionType.enumValues, ["exists", "missing", "appeared", "disappeared", "updated"])
    }

    func testHeistValuePayloadEncoderBridgesEncodableContracts() throws {
        let value = try TheFence.HeistValuePayloadEncoder.encode(AccessibilityPredicate.exists(.label("Pay")))

        guard case .object(let object) = value else {
            return XCTFail("Expected object bridge output")
        }
        XCTAssertEqual(object["type"], .string("exists"))
        XCTAssertNotNil(object["target"])
    }

    @ButtonHeistActor
    func testActivateRejectsContainerNameAsSemanticTarget() async {
        await assertExecutionError(
            command: .activate,
            arguments: ["target": .object(["containerName": .string("main_scroll")])],
            contains: "Unknown accessibility target field \"containerName\""
        )
    }

    @ButtonHeistActor
    func testSwipeRejectsNestedObjectMissingRequiredCoordinateThroughTypedSchema() async {
        await assertExecutionError(
            command: .swipe,
            arguments: [
                "pointToPoint": .object([
                    "start": .object(["x": .double(0.1)]),
                    "end": .object([
                        "x": .double(0.8),
                        "y": .double(0.9),
                    ]),
                ]),
            ],
            contains: "schema validation failed for pointToPoint.start.y: observed missing; expected number"
        )
    }

    @ButtonHeistActor
    func testGetInterfaceRejectsLegacyTopLevelChecks() async {
        await assertExecutionError(
            command: .getInterface,
            arguments: [
                "checks": .array([
                    .object([
                        "kind": .string("label"),
                        "match": .object([
                            "mode": .string("exact"),
                            "value": .string("Pay"),
                        ]),
                    ]),
                ]),
            ],
            contains: "schema validation failed for checks"
        )
    }

    @ButtonHeistActor
    private func assertExecutionError(
        command: TheFence.Command,
        arguments: [String: HeistValue] = [:],
        contains expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let (fence, _) = makeConnectedFence()
        do {
            let response = try await fence.execute(
                command: command,
                values: arguments
            )
            guard case .error(let failure) = response else {
                return XCTFail("Expected error response", file: file, line: line)
            }
            XCTAssertTrue(
                failure.message.contains(expected),
                "Expected error containing '\(expected)', got: \(failure.message)",
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected throw: \(error)", file: file, line: line)
        }
    }
}

private func projectedJSONSchemaProperty(_ key: String, in spec: FenceParameterSpec) -> HeistValue? {
    guard case .object(let schema) = spec.schema.heistValue else { return nil }
    return schema[key]
}

private func assertStringMatchObjectSchema(
    _ spec: FenceParameterSpec,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .object(let schema) = spec.schema.heistValue
    else {
        return XCTFail("Expected StringMatch object schema", file: file, line: line)
    }

    XCTAssertEqual(schema["type"], .string("object"), file: file, line: line)
    XCTAssertEqual(schema["additionalProperties"], .bool(false), file: file, line: line)
    XCTAssertEqual(schema["required"], .array([.string("mode")]), file: file, line: line)

    guard case .object(let properties)? = schema["properties"] else {
        return XCTFail("Expected StringMatch properties", file: file, line: line)
    }
    XCTAssertEqual(properties["mode"], .object([
        "type": .string("string"),
        "enum": .array(StringMatch.Mode.allCases.map { .string($0.rawValue) }),
    ]), file: file, line: line)
    XCTAssertEqual(properties["value"], .object(["type": .string("string")]), file: file, line: line)
}

private func assertPredicateChecksSchema(
    _ spec: FenceParameterSpec,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .object(let schema) = spec.schema.heistValue else {
        return XCTFail("Expected predicate checks array schema", file: file, line: line)
    }
    XCTAssertEqual(schema["type"], .string("array"), file: file, line: line)

    guard case .object(let items)? = schema["items"] else {
        return XCTFail("Expected predicate check item schema", file: file, line: line)
    }
    XCTAssertEqual(items["type"], .string("object"), file: file, line: line)
    XCTAssertEqual(items["additionalProperties"], .bool(false), file: file, line: line)
    XCTAssertEqual(items["required"], .array([.string("kind")]), file: file, line: line)

    guard case .object(let properties)? = items["properties"] else {
        return XCTFail("Expected predicate check item properties", file: file, line: line)
    }
    XCTAssertEqual(properties["kind"], .object([
        "type": .string("string"),
        "enum": .array(ElementPredicateCheck.Kind.allCases.map { .string($0.rawValue) }),
    ]), file: file, line: line)

    guard case .object? = properties["match"] else {
        return XCTFail("Expected match StringMatch object schema", file: file, line: line)
    }
    guard case .object(let values)? = properties["values"] else {
        return XCTFail("Expected values string array schema", file: file, line: line)
    }
    XCTAssertEqual(values["type"], .string("array"), file: file, line: line)
    guard case .object? = properties["check"] else {
        return XCTFail("Expected nested check object schema", file: file, line: line)
    }
}

private func assertContainerPredicateSchema(
    _ spec: FenceParameterSpec,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .object(let schema) = spec.schema.heistValue else {
        return XCTFail("Expected container predicate object schema", file: file, line: line)
    }
    XCTAssertEqual(schema["type"], .string("object"), file: file, line: line)
    XCTAssertEqual(schema["required"], .array([.string("checks")]), file: file, line: line)
    guard case .object(let properties)? = schema["properties"] else {
        return XCTFail("Expected container predicate properties", file: file, line: line)
    }
    guard case .object(let checksSchema)? = properties["checks"] else {
        return XCTFail("Expected container checks array schema", file: file, line: line)
    }
    XCTAssertEqual(checksSchema["type"], .string("array"), file: file, line: line)
    XCTAssertEqual(checksSchema["minItems"], .int(1), file: file, line: line)
    guard case .object(let items)? = checksSchema["items"] else {
        return XCTFail("Expected container check item schema", file: file, line: line)
    }
    XCTAssertEqual(items["additionalProperties"], .bool(false), file: file, line: line)
    guard case .object(let checkProperties)? = items["properties"] else {
        return XCTFail("Expected container check item properties", file: file, line: line)
    }
    XCTAssertEqual(checkProperties["kind"], .object([
        "type": .string("string"),
        "enum": .array(ContainerPredicateCheck.wireKindValues.map { .string($0) }),
    ]), file: file, line: line)
    XCTAssertEqual(checkProperties["type"], .object([
        "type": .string("string"),
        "enum": .array(AccessibilityContainerKind.allCases.map { .string($0.rawValue) }),
    ]), file: file, line: line)
    guard case .object? = checkProperties["match"] else {
        return XCTFail("Expected container identifier StringMatch schema", file: file, line: line)
    }
    guard case .object(let semantic)? = checkProperties["semantic"],
          case .object(let semanticProperties)? = semantic["properties"] else {
        return XCTFail("Expected semantic container predicate schema", file: file, line: line)
    }
    XCTAssertEqual(semantic["required"], .array([.string("kind"), .string("match")]), file: file, line: line)
    XCTAssertEqual(semanticProperties["kind"], .object([
        "type": .string("string"),
        "enum": .array(canonicalSemanticContainerPredicateKindValues().map { .string($0) }),
    ]), file: file, line: line)
    guard case .object? = semanticProperties["match"] else {
        return XCTFail("Expected semantic match StringMatch object schema", file: file, line: line)
    }
    guard case .object? = checkProperties["values"] else {
        return XCTFail("Expected container check values array schema", file: file, line: line)
    }
    XCTAssertEqual(checkProperties["values"], .object([
        "type": .string("array"),
        "items": .object([:]),
        "minItems": .int(1),
    ]), file: file, line: line)
    XCTAssertNotNil(checkProperties["value"], file: file, line: line)
}

private func arrayItemProperties(
    named key: FenceParameterKey,
    in spec: FenceParameterSpec,
    file: StaticString,
    line: UInt
) throws -> [FenceParameterSpec] {
    let child = try XCTUnwrap(
        spec.objectProperties.first { $0.key == key.rawValue },
        file: file,
        line: line
    )
    return child.arrayItemProperties
}

private func canonicalSemanticContainerPredicateKindValues() -> [String] {
    [
        SemanticContainerPredicate.label("sample"),
        SemanticContainerPredicate.value("sample"),
    ].map(\.wireKindValue)
}

private func assertArraySchema(
    _ spec: FenceParameterSpec,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .object(let schema) = spec.schema.heistValue else {
        return XCTFail("Expected array schema", file: file, line: line)
    }
    XCTAssertEqual(schema["type"], .string("array"), file: file, line: line)
}
