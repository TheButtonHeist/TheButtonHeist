import XCTest
import ThePlans
@_spi(ButtonHeistTooling) @testable import ButtonHeist
@_spi(ButtonHeistInternals) import TheScore

final class WireCommandParityTests: XCTestCase {

    func testCommandRawValuesPreserveCanonicalWireSpellings() {
        XCTAssertEqual(TheFence.Command.allCases.map(\.rawValue), [
            "ping", "list_devices", "get_interface", "get_screen", "get_notifications", "action",
            "get_pasteboard", "perform", "run_heist", "validate_heist", "list_heists",
            "describe_heist", "get_session_state", "connect", "list_targets",
        ])
    }

    func testCommandFamiliesHaveOneActionOwner() {
        XCTAssertEqual(TheFence.Command.ping.descriptor.family, .session)
        XCTAssertEqual(TheFence.Command.getInterface.descriptor.family, .observation)
        XCTAssertEqual(TheFence.Command.action.descriptor.family, .action)
        XCTAssertEqual(TheFence.Command.perform.descriptor.family, .heistRuntime)
        XCTAssertEqual(TheFence.Command.runHeist.descriptor.family, .heistRuntime)
    }

    func testDescriptorBackedCLIHelpExposesOnlyCanonicalActionPaths() {
        let help = TheFence.Command.cliJSONLinesHelp

        XCTAssertTrue(help.contains("action"), help)
        XCTAssertTrue(help.contains("perform"), help)
        XCTAssertTrue(help.contains("[action]"), help)
        XCTAssertFalse(help.contains("one_finger_tap"), help)
        XCTAssertFalse(help.contains("scroll_to_visible"), help)
    }

    func testRunHeistDescriptorDoesNotAdvertiseRawJSONIRFields() {
        let keys = TheFence.Command.runHeist.descriptor.topLevelParameterKeys

        XCTAssertTrue(keys.isSuperset(of: ["path", "plan", "argument"]))
        XCTAssertTrue(keys.isDisjoint(with: ["version", "name", "parameter", "definitions", "body"]))
    }

    func testValidateHeistDescriptorIsOfflineAndUsesCanonicalPlanSources() {
        let descriptor = TheFence.Command.validateHeist.descriptor

        XCTAssertFalse(descriptor.requiresConnectionBeforeDispatch)
        XCTAssertTrue(descriptor.topLevelParameterKeys.isSuperset(of: ["path", "plan", "argument", "lint"]))
        XCTAssertFalse(descriptor.topLevelParameterKeys.contains("body"))
        XCTAssertEqual(descriptor.defaultValue(for: FenceParameters.heistValidationLint), .compositionQuality)
    }

    func testDescriptorDefaultsOwnCommandDefaultValues() {
        XCTAssertEqual(
            TheFence.Command.listHeists.descriptor.defaultValue(for: FenceParameters.heistCatalogDetail),
            .summary
        )
    }

    func testDescriptorTimeoutSemanticsOwnCommandTimeouts() {
        XCTAssertEqual(TheFence.Command.ping.descriptor.timeout, .fixed(.health))
        XCTAssertEqual(TheFence.Command.getInterface.descriptor.timeout, .fixed(.explore))
        XCTAssertEqual(TheFence.Command.getScreen.descriptor.timeout, .fixed(.screenCapture))
        XCTAssertEqual(TheFence.Command.action.descriptor.timeout, .action)
        XCTAssertEqual(TheFence.Command.perform.descriptor.timeout, .performStep)
        XCTAssertEqual(TheFence.Command.runHeist.descriptor.timeout, .heist)
    }

    func testRunHeistDescriptorOwnsUnboundedTypedTimeoutDefault() {
        let descriptor = TheFence.Command.runHeist.descriptor
        let timeout = descriptor.parameter(named: "timeout")

        XCTAssertEqual(timeout?.required, false)
        XCTAssertEqual(descriptor.requiredDefaultValue(for: FenceParameters.heistTimeout), .default)
        XCTAssertNil(timeout?.maximum)
    }

    @ButtonHeistActor
    func testActionAdmissionDerivesDirectDispatchTimeoutFromActionType() async throws {
        let (fence, _) = makeConnectedFence()
        let input = try actionInput(.scroll(ScrollTarget(direction: .down)))
        let admitted = try fence.admit(input)

        guard case .directAction(let directAction) = admitted.execution else {
            return XCTFail("Scroll should decode as a transient direct action")
        }
        XCTAssertEqual(directAction.action.wireType, .scroll)
        XCTAssertEqual(
            directAction.timeout,
            TheFence.HeistExecutionBudget.fixedActionTimeoutClass(for: .scroll).seconds
        )
    }

    @ButtonHeistActor
    func testActionAdmissionRoutesDurableActionsThroughHeistPipeline() async throws {
        let (fence, _) = makeConnectedFence()
        let input = try actionInput(.activate(.identifier("target")))
        let admitted = try fence.admit(input)

        guard case .durableAction(let execution) = admitted.execution else {
            return XCTFail("Activate should enter the durable action pipeline")
        }
        XCTAssertEqual(execution.action, .activate(.identifier("target")))
    }

    @ButtonHeistActor
    func testCLIAndMCPAdaptersPreserveAdmissionFailures() async throws {
        let (fence, _) = makeConnectedFence()
        let missingStep = try TheFence.Command.routeToolRequest(
            named: TheFence.Command.perform.rawValue,
            arguments: .init(values: [:])
        )
        XCTAssertThrowsError(try fence.admit(missingStep)) { error in
            XCTAssertEqual((error as? SchemaValidationError)?.field, "step")
        }

        let malformedAction = try TheFence.Command.routeCLICommandEnvelope(
            .init(values: [
                "command": .string(TheFence.Command.action.rawValue),
                "action": .object([
                    "type": .string("scroll"),
                    "payload": .object(["direction": .string("sideways")]),
                ]),
            ]),
            context: "test"
        )
        XCTAssertThrowsError(try fence.admit(malformedAction)) { error in
            XCTAssertTrue(String(describing: error).contains("sideways"))
        }

        let unknownKey = "__unknown_parameter__"
        let unknownParameter = try TheFence.Command.routeCLICommandEnvelope(
            .init(values: [
                "command": .string(TheFence.Command.ping.rawValue),
                unknownKey: .bool(true),
            ]),
            context: "test"
        )
        XCTAssertThrowsError(try fence.admit(unknownParameter)) { error in
            XCTAssertEqual((error as? SchemaValidationError)?.field, unknownKey)
        }
    }

    func testNotificationsUseCanonicalDirectWireContract() throws {
        let notification = try XCTUnwrap(Observation.Notification(text: "Checkout ready", element: nil))

        XCTAssertEqual(TheFence.Command.getNotifications.rawValue, "get_notifications")
        XCTAssertEqual(try encodedWireType(for: .getNotifications), .getNotifications)

        let data = try JSONEncoder().encode(ServerMessage.notifications([notification]))
        let encoded = try JSONDecoder().decode(EncodedNotificationResponse.self, from: data)
        XCTAssertEqual(encoded.type, .notifications)
        XCTAssertEqual(encoded.payload, [notification])
    }

    func testEveryPublicTypedClientMessageOwnsItsWireIdentity() throws {
        let samples = try sampleClientMessages()
        XCTAssertEqual(Set(samples.map(\.wireType)), Set(ClientWireMessageType.allCases))

        for message in samples {
            XCTAssertEqual(try encodedWireType(for: message), message.wireType, "\(message)")
        }
    }

    private func actionInput(_ command: HeistActionCommand) throws -> FenceCommandInput {
        FenceCommandInput(
            command: .action,
            arguments: .init(values: [
                "action": try TheFence.HeistValuePayloadEncoder.encode(command),
            ])
        )
    }

    private func sampleClientMessages() throws -> [ClientMessage] {
        let mainThreadProbe = try XCTUnwrap(MainThreadProbeRequest.admit(
            responsivenessTimeoutMilliseconds: 1_000,
            workTimeoutMilliseconds: 1_000
        ))
        return [
            .clientHello,
            .authenticate(AuthenticatePayload(token: "token")),
            .requestInterface(InterfaceQuery()),
            .ping,
            .mainThreadProbe(mainThreadProbe),
            .status,
            .getPasteboard,
            .getNotifications,
            .requestScreen(),
            .runtimeAction(.scroll(ScrollTarget(direction: .down))),
            .heistPlan(HeistPlanRun(plan: try HeistPlan(body: [
                .action(ActionStep(command: .activate(.identifier("target")))),
            ]))),
        ]
    }

    private func encodedWireType(for message: ClientMessage) throws -> ClientWireMessageType {
        let data = try JSONEncoder().encode(message)
        return try JSONDecoder().decode(EncodedClientType.self, from: data).type
    }
}

private struct EncodedClientType: Decodable {
    let type: ClientWireMessageType
}

private struct EncodedNotificationResponse: Decodable {
    let type: ServerWireMessageType
    let payload: [Observation.Notification]
}
