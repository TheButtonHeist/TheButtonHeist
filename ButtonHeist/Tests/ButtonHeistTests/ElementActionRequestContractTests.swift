import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import ThePlans
import TheScore

final class ElementActionRequestContractTests: XCTestCase {

    func testActionIsTheOnlyStructuredActionContract() throws {
        let descriptor = TheFence.Command.action.descriptor

        XCTAssertEqual(descriptor.parameters.map(\.key), ["action", "expect", "timeout"])
        XCTAssertEqual(descriptor.family, .action)
        XCTAssertEqual(descriptor.timeout, .action)
        XCTAssertEqual(descriptor.parameters.first?.schema.heistValue, .object(["type": .string("object")]))
    }

    func testCommandSchemaDefinesOneRecursiveAccessibilityTarget() throws {
        guard case .object(let schema) = TheFence.Command.action.descriptor.inputJSONSchema,
              case .object(let definitions)? = schema["$defs"],
              case .object(let target)? = definitions["AccessibilityTarget"],
              case .object(let properties)? = target["properties"] else {
            return XCTFail("Expected the canonical AccessibilityTarget definition")
        }

        XCTAssertEqual(properties["target"], .object([
            "$ref": .string("#/$defs/AccessibilityTarget"),
        ]))
    }

    @ButtonHeistActor
    func testActionAdmissionClassifiesDurableAndDirectActions() async throws {
        let (fence, _) = makeConnectedFence()

        let durable = try fence.admit(actionInput([
            "type": .string("dismiss"),
        ]))
        guard case .durableAction = durable.execution else {
            return XCTFail("Expected dismiss to enter the canonical heist pipeline")
        }

        let direct = try fence.admit(actionInput([
            "type": .string("scroll"),
            "payload": .object(["direction": .string("down")]),
        ]))
        guard case .directAction = direct.execution else {
            return XCTFail("Expected transient scroll to dispatch directly")
        }
    }

    @ButtonHeistActor
    func testActionAdmissionRejectsLegacyTopLevelActionFields() async throws {
        let (fence, _) = makeConnectedFence()

        XCTAssertThrowsError(try fence.admit(FenceCommandInput(
            command: .action,
            arguments: TheFence.CommandArgumentEnvelope(values: [
                "target": .object(["ref": .string("button")]),
            ])
        ))) { error in
            XCTAssertTrue(String(describing: error).contains("valid action parameter"))
        }
    }

    @ButtonHeistActor
    func testActionDecoderRejectsUnknownNestedFields() async throws {
        let (fence, _) = makeConnectedFence()
        let arguments = TheFence.CommandArgumentEnvelope(values: [
            "action": .object([
                "type": .string("dismiss"),
                "legacy": .bool(true),
            ]),
        ])

        XCTAssertThrowsError(try fence.decodeAction(arguments)) { error in
            XCTAssertTrue(String(describing: error).contains("legacy"))
        }
    }

    func testHeistValuePayloadEncoderBridgesCanonicalActionContracts() throws {
        let value = try TheFence.HeistValuePayloadEncoder.encode(HeistActionCommand.dismiss)

        XCTAssertEqual(value, .object(["type": .string("dismiss")]))
    }

    @ButtonHeistActor
    func testGetInterfaceRejectsLegacyTopLevelChecks() async {
        let (fence, _) = makeConnectedFence()

        do {
            let response = try await fence.execute(
                command: .getInterface,
                values: ["checks": .array([])]
            )
            guard case .error(let failure) = response else {
                return XCTFail("Expected error response")
            }
            XCTAssertTrue(failure.message.contains("schema validation failed for checks"))
        } catch {
            XCTFail("Unexpected throw: \(error)")
        }
    }

    private func actionInput(_ action: [String: HeistValue]) -> FenceCommandInput {
        FenceCommandInput(
            command: .action,
            arguments: TheFence.CommandArgumentEnvelope(values: ["action": .object(action)])
        )
    }
}
