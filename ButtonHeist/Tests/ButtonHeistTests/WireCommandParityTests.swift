import XCTest
import ThePlans
@_spi(ButtonHeistTooling) @testable import ButtonHeist
@_spi(ButtonHeistInternals) import TheScore

final class WireCommandParityTests: XCTestCase {

    func testCommandRawValuesPreserveCanonicalWireSpellings() {
        XCTAssertEqual(TheFence.Command.allCases.map(\.rawValue), [
            "ping", "list_devices", "get_interface", "get_screen", "get_notifications", "wait",
            "one_finger_tap", "long_press", "swipe", "drag", "scroll", "scroll_to_visible",
            "scroll_to_edge", "activate", "rotor", "type_text", "edit_action", "set_pasteboard",
            "get_pasteboard", "dismiss_keyboard", "perform", "run_heist", "validate_heist",
            "list_heists", "describe_heist", "get_session_state", "connect", "list_targets",
        ])
    }

    func testCommandFamilyMembership() {
        XCTAssertEqual(TheFence.Command.ping.descriptor.family, .session)
        XCTAssertEqual(TheFence.Command.getInterface.descriptor.family, .observation)
        XCTAssertEqual(TheFence.Command.wait.descriptor.family, .assertion)
        XCTAssertEqual(TheFence.Command.activate.descriptor.family, .semanticAction)
        XCTAssertEqual(TheFence.Command.oneFingerTap.descriptor.family, .spatialAction)
        XCTAssertEqual(TheFence.Command.scroll.descriptor.family, .viewportDebug)
        XCTAssertEqual(TheFence.Command.scrollToVisible.descriptor.family, .viewportDebug)
        XCTAssertEqual(TheFence.Command.scrollToEdge.descriptor.family, .viewportDebug)
        XCTAssertEqual(TheFence.Command.perform.descriptor.family, .heistRuntime)
        XCTAssertEqual(TheFence.Command.runHeist.descriptor.family, .heistRuntime)
        XCTAssertEqual(TheFence.Command.validateHeist.descriptor.family, .heistRuntime)
        XCTAssertEqual(TheFence.Command.listHeists.descriptor.family, .heistRuntime)
        XCTAssertEqual(TheFence.Command.describeHeist.descriptor.family, .heistRuntime)

        XCTAssertEqual(TheFence.Command.wait.descriptor.command, .wait)
    }

    func testDescriptorBackedCLIHelpDisplaysFamilyGrouping() {
        let help = TheFence.Command.cliJSONLinesHelp

        XCTAssertTrue(help.contains("wait"), help)
        XCTAssertTrue(help.contains("[assertion]"), help)
        XCTAssertTrue(help.contains("scroll"), help)
        XCTAssertTrue(help.contains("[viewportDebug]"), help)
        XCTAssertFalse(help.contains("Recordable"), help)
        XCTAssertFalse(help.contains("Durable"), help)
    }

    func testRunHeistDescriptorDoesNotAdvertiseRawJSONIRFields() {
        let descriptor = TheFence.Command.runHeist.descriptor
        let keys = Set(descriptor.parameters.map(\.key))

        XCTAssertTrue(keys.isSuperset(of: Set([
            FenceParameterKey.path,
            .plan,
            .argument,
        ].map(\.rawValue))))
        XCTAssertTrue(keys.isDisjoint(with: Set([
            FenceParameterKey.version,
            .name,
            .parameter,
            .definitions,
            .body,
        ].map(\.rawValue))))
    }

    func testValidateHeistDescriptorIsOfflineAndUsesCanonicalPlanSources() {
        let descriptor = TheFence.Command.validateHeist.descriptor
        let keys = Set(descriptor.parameters.map(\.key))

        XCTAssertFalse(descriptor.requiresConnectionBeforeDispatch)
        XCTAssertTrue(keys.isSuperset(of: Set([
            FenceParameterKey.path,
            .plan,
            .argument,
            .lint,
        ].map(\.rawValue))))
        XCTAssertFalse(keys.contains(FenceParameterKey.body.rawValue))
        XCTAssertEqual(
            descriptor.defaultValue(for: FenceParameters.heistValidationLint),
            .compositionQuality
        )
    }

    func testDescriptorLookupFindsEquivalentNestedParameters() {
        let direction = TheFence.Command.swipe.descriptor.parameter(named: .direction)

        XCTAssertEqual(direction?.enumValues, fenceEnumValues(SwipeDirection.self))
    }

    func testDescriptorDefaultsOwnCommandDefaultValues() {
        XCTAssertEqual(
            TheFence.Command.scroll.descriptor.defaultValue(for: FenceParameters.scrollDirection),
            .down
        )
        XCTAssertEqual(
            TheFence.Command.scrollToEdge.descriptor.defaultValue(for: FenceParameters.scrollEdge),
            .top
        )
        XCTAssertEqual(
            TheFence.Command.rotor.descriptor.defaultValue(for: FenceParameters.rotorDirection),
            .next
        )
        XCTAssertEqual(
            TheFence.Command.listHeists.descriptor.defaultValue(for: FenceParameters.heistCatalogDetail),
            .summary
        )
    }

    func testDescriptorTimeoutSemanticsOwnCommandTimeouts() {
        XCTAssertEqual(TheFence.Command.ping.descriptor.timeout, .fixed(.health))
        XCTAssertEqual(TheFence.Command.getInterface.descriptor.timeout, .fixed(.explore))
        XCTAssertEqual(TheFence.Command.getScreen.descriptor.timeout, .fixed(.screenCapture))
        XCTAssertEqual(TheFence.Command.runHeist.descriptor.timeout, .heist)
        XCTAssertEqual(TheFence.Command.wait.descriptor.timeout, .wait)
        XCTAssertEqual(TheFence.Command.activate.descriptor.timeout, .singleStepAction(base: .standardAction))
        XCTAssertEqual(TheFence.Command.typeText.descriptor.timeout, .singleStepAction(base: .longAction))
        XCTAssertEqual(TheFence.Command.perform.descriptor.timeout, .performStep)
    }

    @ButtonHeistActor
    func testActionCommandDescriptorsUseCanonicalFixedTimeoutPolicy() async {
        let actionFamilies: Set<FenceCommandFamily> = [
            .semanticAction,
            .spatialAction,
            .viewportDebug,
        ]
        for descriptor in TheFence.Command.descriptors {
            let expected = TheFence.HeistExecutionBudget.fixedActionTimeoutClass(
                for: descriptor.command
            )
            guard actionFamilies.contains(descriptor.family) else {
                XCTAssertNil(expected, descriptor.command.rawValue)
                continue
            }
            guard let expected else {
                XCTFail("Missing action timeout policy for \(descriptor.command.rawValue)")
                continue
            }
            let actual: FenceCommandFixedTimeout?
            switch descriptor.timeout {
            case .fixed(let timeout), .singleStepAction(let timeout):
                actual = timeout
            case .none, .wait, .performStep, .heist:
                actual = nil
            }
            guard let actual else {
                XCTFail("Expected action timeout for \(descriptor.command.rawValue)")
                continue
            }
            XCTAssertEqual(actual, expected, descriptor.command.rawValue)
        }
    }

    func testRunHeistDescriptorOwnsUnboundedTypedTimeoutDefault() {
        let descriptor = TheFence.Command.runHeist.descriptor
        let timeout = descriptor.parameter(named: .timeout)

        XCTAssertEqual(timeout?.required, false)
        XCTAssertEqual(
            descriptor.requiredDefaultValue(for: FenceParameters.heistTimeout),
            .default
        )
        XCTAssertEqual(
            timeout?.maximum,
            nil
        )
    }

    @ButtonHeistActor
    func testTransientSingleStepDirectActionsUseDescriptorDispatchTimeout() async throws {
        let (fence, _) = makeConnectedFence()
        let request = try fence.parseRequest(command: .rotor, values: [
            FenceParameterKey.target.rawValue: targetArgumentValue(identifier: "target"),
            FenceParameterKey.rotorIndex.rawValue: .int(0),
        ])

        guard case .directAction(let directAction) = request.execution else {
            return XCTFail("Indexed rotor should decode as transient direct action")
        }
        XCTAssertNotNil(directAction.action.durableHeistActionFailure)
        XCTAssertEqual(directAction.timeout, FenceCommandFixedTimeout.standardAction.seconds)
    }

    func testCommandHelpKeepsAccessibilitySemanticAndSpatialBoundaries() {
        let activate = TheFence.Command.activate.descriptor.description
        let tap = TheFence.Command.oneFingerTap.descriptor.description
        let scroll = TheFence.Command.scroll.descriptor.description
        let scrollToVisible = TheFence.Command.scrollToVisible.descriptor.description
        let scrollToEdge = TheFence.Command.scrollToEdge.descriptor.description

        XCTAssertTrue(activate.localizedCaseInsensitiveContains("primary accessibility activation"), activate)
        XCTAssertTrue(activate.localizedCaseInsensitiveContains("semantic UI element"), activate)
        XCTAssertFalse(activate.localizedCaseInsensitiveContains("tap"), activate)

        XCTAssertTrue(tap.localizedCaseInsensitiveContains("explicit spatial oneFingerTap action"), tap)
        XCTAssertTrue(tap.localizedCaseInsensitiveContains("use activate for ordinary accessible controls"), tap)

        XCTAssertTrue(scroll.localizedCaseInsensitiveContains("explicit viewport/debug operation"), scroll)
        XCTAssertTrue(scrollToVisible.localizedCaseInsensitiveContains("explicit viewport/debug operation"), scrollToVisible)
        XCTAssertTrue(scrollToEdge.localizedCaseInsensitiveContains("explicit viewport/debug operation"), scrollToEdge)
    }

    @ButtonHeistActor
    func testCLIAndMCPAdaptersPreserveRepresentativeAdmissionFailures() async throws {
        let (fence, _) = makeConnectedFence()
        let missingStep = try TheFence.Command.routeToolRequest(
            named: TheFence.Command.perform.rawValue,
            arguments: .init(values: [:])
        ).get()
        XCTAssertThrowsError(try fence.admit(missingStep)) { error in
            XCTAssertEqual((error as? SchemaValidationError)?.field, FenceParameterKey.step.rawValue)
        }

        let malformedDirection = try TheFence.Command.routeCLICommandEnvelope(
            .init(values: [
                FenceParameterKey.command.rawValue: .string(TheFence.Command.scroll.rawValue),
                FenceParameterKey.direction.rawValue: .string("sideways"),
            ]),
            context: "test"
        ).get()
        XCTAssertThrowsError(try fence.admit(malformedDirection)) { error in
            XCTAssertEqual((error as? SchemaValidationError)?.field, FenceParameterKey.direction.rawValue)
        }

        let unknownKey = "__unknown_parameter__"
        let unknownParameter = try TheFence.Command.routeCLICommandEnvelope(
            .init(values: [
                FenceParameterKey.command.rawValue: .string(TheFence.Command.ping.rawValue),
                unknownKey: .bool(true),
            ]),
            context: "test"
        ).get()
        XCTAssertThrowsError(try fence.admit(unknownParameter)) { error in
            XCTAssertEqual((error as? SchemaValidationError)?.field, unknownKey)
        }
    }

    @ButtonHeistActor
    func testAdmissionRejectsMissingSemanticRequirements() async throws {
        let (fence, _) = makeConnectedFence()

        XCTAssertThrowsError(try fence.admit(FenceCommandInput(
            command: .activate,
            arguments: .init(values: [:])
        ))) { error in
            XCTAssertEqual((error as? TheFence.MissingAccessibilityTarget)?.command, .activate)
        }
    }

    @ButtonHeistActor
    func testViewportDebugCommandsAreCLIDirectOnlyAndDoNotRouteThroughSingleStepPlan() async throws {
        let (fence, _) = makeConnectedFence()

        let cases: [(TheFence.Command, [String: HeistValue])] = [
            (.scroll, [FenceParameterKey.direction.rawValue: .string(ScrollDirection.down.rawValue)]),
            (.scrollToVisible, [FenceParameterKey.target.rawValue: targetArgumentValue(identifier: "target")]),
            (.scrollToEdge, [FenceParameterKey.edge.rawValue: .string(ScrollEdge.bottom.rawValue)]),
        ]
        for (command, arguments) in cases {
            let descriptor = command.descriptor
            XCTAssertEqual(descriptor.family, .viewportDebug, command.rawValue)
            XCTAssertEqual(descriptor.cliExposure, .directCommand, command.rawValue)
            XCTAssertEqual(descriptor.mcpExposure, .notExposed, command.rawValue)

            let request = try fence.parseRequest(command: command, values: arguments)
            guard case .directAction(let directAction) = request.execution else {
                return XCTFail("\(command.rawValue) should decode as direct action")
            }
            XCTAssertNotNil(directAction.action.durableHeistActionFailure, command.rawValue)
        }
    }

    @ButtonHeistActor
    func testDurableRuntimeActionCommandsRouteThroughSingleStepPlan() async throws {
        let (fence, _) = makeConnectedFence()

        let cases: [(TheFence.Command, [String: HeistValue])] = [
            (.activate, [FenceParameterKey.target.rawValue: targetArgumentValue(identifier: "target")]),
            (.oneFingerTap, [
                FenceParameterKey.point.rawValue: .object([
                    FenceParameterKey.x.rawValue: .double(12),
                    FenceParameterKey.y.rawValue: .double(34),
                ]),
            ]),
            (.typeText, [FenceParameterKey.text.rawValue: .string("hello")]),
            (.setPasteboard, [FenceParameterKey.text.rawValue: .string("clipboard")]),
        ]
        for (command, arguments) in cases {
            let request = try fence.parseRequest(command: command, values: arguments)
            guard case .singleStepHeist(let heistRequest) = request.execution,
                  case .action(let action, _) = heistRequest else {
                return XCTFail("\(command.rawValue) should decode as single-step action command")
            }
            let plan = try fence.singleStepHeistPlan(for: heistRequest)
            let heistCommands = plan.body.flatMap(actionCommands(for:))

            XCTAssertEqual(heistCommands.count, 1, command.rawValue)
            XCTAssertEqual(heistCommands.first, action.action, command.rawValue)
        }
    }

    func testNotificationsUseCanonicalDirectWireContract() throws {
        let notification = try XCTUnwrap(Observation.Notification(
            text: "Checkout ready",
            element: nil
        ))

        XCTAssertEqual(TheFence.Command.getNotifications.rawValue, "get_notifications")
        XCTAssertEqual(
            try encodedWireType(for: .getNotifications),
            .getNotifications
        )

        let data = try JSONEncoder().encode(ServerMessage.notifications([notification]))
        let encoded = try JSONDecoder().decode(EncodedNotificationResponse.self, from: data)

        XCTAssertEqual(encoded.type, .notifications)
        XCTAssertEqual(encoded.payload, [notification])
    }

    func testEveryPublicTypedClientMessageOwnsItsWireIdentity() throws {
        let samples = try sampleClientMessages()
        XCTAssertEqual(
            Set(samples.map(\.wireType)),
            Set(ClientWireMessageType.allCases)
        )

        for message in samples {
            XCTAssertEqual(try encodedWireType(for: message), message.wireType, "\(message)")
        }
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

    private func actionCommands(for step: HeistStep) -> [HeistActionCommand] {
        switch step {
        case .action(let action):
            return [action.command]
        case .wait, .conditional, .forEachElement, .forEachString, .repeatUntil, .warn, .fail, .heist, .invoke:
            return []
        }
    }
}

private struct EncodedClientType: Decodable {
    let type: ClientWireMessageType
}

private struct EncodedNotificationResponse: Decodable {
    let type: ServerWireMessageType
    let payload: [Observation.Notification]
}
