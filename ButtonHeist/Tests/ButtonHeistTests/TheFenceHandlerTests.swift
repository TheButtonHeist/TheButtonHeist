import ButtonHeistTestSupport
import XCTest
import Network
import ButtonHeistSupport
@_spi(ButtonHeistTooling) @testable import ButtonHeist
@_spi(ButtonHeistInternals) import ThePlans
@_spi(ButtonHeistInternals) import TheScore

func invocationPath(_ dottedName: String) -> HeistInvocationPath {
    do {
        return try HeistInvocationPath(validating: dottedName)
    } catch {
        preconditionFailure("invalid fence fixture path \(dottedName): \(error)")
    }
}

func existsLabel(_ label: String) -> AccessibilityPredicate {
    .exists(.label(label))
}

struct FailureClassificationExpectation {
    let kind: DiagnosticFailureKind
    let phase: FailurePhase
    let retryable: Bool
    let hint: String?

    init(
        _ kind: DiagnosticFailureKind,
        _ phase: FailurePhase,
        retryable: Bool,
        hint: String?
    ) {
        self.kind = kind
        self.phase = phase
        self.retryable = retryable
        self.hint = hint
    }
}

// MARK: - TheFence Handler Dispatch & Validation Tests
//
// These tests exercise the command dispatch router and the argument-validation
// paths inside TheFence+Handlers using mock DeviceConnecting/DeviceDiscovering
// implementations injected via TheHandoff closures (see Mocks.swift).

final class TheFenceHandlerTests: XCTestCase {

    // MARK: - Helpers

    static let pureRuntimeHeistSource = """
    HeistPlan("agentFlow") {
        HeistDef<String>("Cart.addItem", parameter: "item") { item in
            Activate(.label(item))
        }

        Warn("start")
        Activate(.label("Pay"))

        ForEach("Milk", "Bread") { item in
            RunHeist("Cart.addItem", item)
        }
    }
    """

    static let nativeSwiftRuntimeSource = """
    HeistPlan {
        let label = "Pay"
        Activate(.label(label))
    }
    """

    static let knownFailureCodeClassificationExpectations: [KnownFailureCode: FailureClassificationExpectation] = [
        .requestInvalid: .init(.request, .request, retryable: false, hint: "Fix the request shape or arguments before retrying."),
        .requestMissingTarget: .init(.request, .request, retryable: false, hint: "get_interface()"),
        .requestAccessibilityTreeUnavailable: .init(
            .request,
            .request,
            retryable: true,
            hint: "Wait for a traversable app window, then refresh the interface or retry the command."
        ),
        .requestElementNotFound: .init(
            .request,
            .request,
            retryable: false,
            hint: "Refresh the interface and verify the target's accessibility properties."
        ),
        .requestTimeout: .init(.request, .request, retryable: true, hint: FenceError.actionTimeoutRecoveryHint),
        .requestValidationError: .init(
            .request,
            .request,
            retryable: false,
            hint: "Fix the request so it satisfies the server-side validation rules."
        ),
        .requestActionFailed: .init(.request, .request, retryable: false, hint: nil),
        .discoveryNoDeviceFound: .init(
            .discovery,
            .discovery,
            retryable: true,
            hint: "Start the app and confirm it advertises a session for The Button Heist."
        ),
        .discoveryNoMatchingDevice: .init(
            .discovery,
            .discovery,
            retryable: false,
            hint: "Check the device filter or target name against 'buttonheist list_devices'."
        ),
        .discoveryAmbiguousDeviceTarget: .init(
            .discovery,
            .discovery,
            retryable: false,
            hint: "Narrow the device target using a unique app name, device name, instance ID, installation ID, "
                + "simulator UDID, or direct host:port."
        ),
        .setupTimeout: .init(
            .connection,
            .setup,
            retryable: true,
            hint: "Is the app running? Check 'buttonheist list_devices' to see available devices."
        ),
        .connectionFailed: .init(
            .connection,
            .transport,
            retryable: true,
            hint: "Check that the app is running and reachable, then retry."
        ),
        .connectionNotConnected: .init(
            .connection,
            .request,
            retryable: true,
            hint: "Check that the app is running, then retry the command. Use 'buttonheist list_devices' to see available devices."
        ),
        .connectionEndpointUnreachable: .init(
            .connection,
            .transport,
            retryable: true,
            hint: "Check that the app is running at the configured endpoint, then retry the command."
        ),
        .transportNetworkError: .init(
            .connection,
            .transport,
            retryable: true,
            hint: "Check that the app is still running and reachable, then retry."
        ),
        .transportBufferOverflow: .init(
            .connection,
            .transport,
            retryable: false,
            hint: "Request a smaller payload or narrow the interface query before retrying."
        ),
        .transportEventBacklogOverflow: .init(
            .connection,
            .transport,
            retryable: true,
            hint: "Reconnect and retry after reducing event volume or response size."
        ),
        .transportServerClosed: .init(
            .connection,
            .transport,
            retryable: true,
            hint: "Check that the app is still running and reachable, then retry."
        ),
        .authFailed: .init(.authentication, .authentication, retryable: false, hint: nil),
        .sessionLocked: .init(
            .session,
            .session,
            retryable: true,
            hint: "Wait for the current driver to disconnect or for the session to time out. If this is your own stale session, "
                + "retry with the same BUTTONHEIST_DRIVER_ID or restart the app."
        ),
        .protocolMismatch: .init(
            .connection,
            .protocolNegotiation,
            retryable: false,
            hint: "Rebuild or reinstall so the CLI, MCP server, and iOS app use the same Button Heist version."
        ),
        .tlsMissingToken: .init(.connection, .tls, retryable: false, hint: "Set BUTTONHEIST_TOKEN, pass --token, or configure a target token."),
        .clientLocalDisconnect: .init(.client, .client, retryable: false, hint: nil),
        .clientUnknown: .init(.unknown, .client, retryable: false, hint: nil),
        .serverGeneral: .init(.server, .server, retryable: false, hint: nil),
        .configReadFailed: .init(
            .configuration,
            .setup,
            retryable: false,
            hint: "Verify the config path points to a readable JSON file matching the Button Heist config schema."
        ),
        .configDecodeFailed: .init(
            .configuration,
            .setup,
            retryable: false,
            hint: "Verify the config path points to a readable JSON file matching the Button Heist config schema."
        ),
        .formattingJSONEncodingFailed: .init(
            .client,
            .client,
            retryable: false,
            hint: "Report this diagnostic with the command that produced it."
        ),
        .screenInlinePayloadTooLarge: .init(
            .client,
            .client,
            retryable: false,
            hint: "Omit inlineData or pass output to receive a screenshot artifact path."
        ),
    ]

    static var expectedDiagnosticFailures: [ExpectedDiagnosticFailure] {
        let validationError = SchemaValidationError(
            field: "target",
            observed: "string",
            expected: "object"
        )
        return [
            ExpectedDiagnosticFailure(
                name: "server",
                response: FenceResponse.failure(FenceError.serverError(ServerError(
                    kind: .general,
                    message: "server crashed"
                ))),
                code: .serverGeneral,
                kind: .server,
                phase: .server,
                message: "Action failed: server crashed",
                retryable: false
            ),
            ExpectedDiagnosticFailure(
                name: "routing",
                response: FenceResponse.failure(FenceOperationRoutingError(message: "Unknown tool: warp")),
                code: .requestInvalid,
                kind: .request,
                phase: .request,
                message: "Unknown tool: warp",
                retryable: false
            ),
            ExpectedDiagnosticFailure(
                name: "validation",
                response: FenceResponse.failure(validationError),
                code: .requestValidationError,
                kind: .request,
                phase: .request,
                message: validationError.message,
                retryable: false
            ),
            ExpectedDiagnosticFailure(
                name: "action",
                response: FenceResponse.failure(FenceError.actionFailed("could not activate target")),
                code: .requestActionFailed,
                kind: .request,
                phase: .request,
                message: "Action failed: could not activate target",
                retryable: false
            ),
            ExpectedDiagnosticFailure(
                name: "discovery",
                response: FenceResponse.failure(FenceError(HandoffConnectionError.noDeviceFound)),
                code: .discoveryNoDeviceFound,
                kind: .discovery,
                phase: .discovery,
                message: "No devices found within timeout. Is the app running?",
                retryable: true
            ),
            ExpectedDiagnosticFailure(
                name: "transport",
                response: FenceResponse.failure(FenceError.diagnostic(DiagnosticFailure(
                    message: "network down",
                    details: FailureDetails(code: .transportNetworkError, hint: "retry")
                ))),
                code: .transportNetworkError,
                kind: .connection,
                phase: .transport,
                message: "network down",
                retryable: true
            ),
            ExpectedDiagnosticFailure(
                name: "known-fence",
                response: FenceResponse.failure(FenceError.notConnected),
                code: .connectionNotConnected,
                kind: .connection,
                phase: .request,
                message: "Not connected to device.",
                retryable: true
            ),
            ExpectedDiagnosticFailure(
                name: "connection-domain",
                response: FenceResponse.failure(HandoffConnectionError.timeout),
                code: .setupTimeout,
                kind: .connection,
                phase: .setup,
                message: "Connection timed out",
                retryable: true
            ),
        ]
    }

    @ButtonHeistActor
    func assertValidationFailure(
        command: TheFence.Command,
        arguments: [String: HeistValue] = [:],
        file: StaticString = #filePath,
        line: UInt = #line,
        verify: (DiagnosticFailure) -> Void
    ) async {
        let (fence, _) = makeConnectedFence()
        do {
            let response = try await fence.execute(command: command, values: arguments)
            guard case .error(let failure) = response else {
                return XCTFail("Expected .error response, got: \(response)", file: file, line: line)
            }
            verify(failure)
        } catch {
            XCTFail("Unexpected throw: \(error)", file: file, line: line)
        }
    }

    @ButtonHeistActor
    func assertValidationError(
        command: TheFence.Command,
        arguments: [String: HeistValue] = [:],
        contains substring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await assertValidationFailure(
            command: command,
            arguments: arguments,
            file: file,
            line: line
        ) { failure in
            XCTAssertTrue(
                failure.message.contains(substring),
                "Expected error containing '\(substring)', got: \(failure.message)",
                file: file,
                line: line
            )
        }
    }

    @ButtonHeistActor
    func assertValidationError(
        command: TheFence.Command,
        arguments: [String: HeistValue] = [:],
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await assertValidationFailure(
            command: command,
            arguments: arguments,
            file: file,
            line: line
        ) { failure in
            XCTAssertEqual(failure.message, expected, file: file, line: line)
        }
    }

    @ButtonHeistActor
    func assertDirectCommandHeistExecution(
        _ response: FenceResponse,
        command: TheFence.Command,
        stepKind: HeistExecutionStepKind,
        reportCommandName: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .heistExecution(_, let report) = response else {
            return XCTFail("Expected .heistExecution response, got \(response)", file: file, line: line)
        }
        XCTAssertEqual(report.nodes.map(\.kind), [stepKind], file: file, line: line)
        if stepKind == .action {
            XCTAssertEqual(report.nodes.first?.command?.rawValue, reportCommandName ?? command.rawValue, file: file, line: line)
        }
    }

    /// Assert that executing a typed operation passes validation (returns a non-error response).
    @ButtonHeistActor
    func assertPassesValidation(
        command: TheFence.Command,
        arguments: [String: HeistValue] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let (fence, _) = makeConnectedFence()
        do {
            let response = try await fence.execute(command: command, values: arguments)
            if case .error(let failure) = response {
                XCTFail("Got validation error: \(failure.message)", file: file, line: line)
            }
        } catch {
            XCTFail("Unexpected throw: \(error)", file: file, line: line)
        }
    }

    func selectionTestInterface(includeDuplicateGroup: Bool = false) -> Interface {
        let header = makeTestHeistElement(label: "Menu", traits: [.header])
        let submit = makeTestHeistElement(label: "Submit", traits: [.button])
        let cancel = makeTestHeistElement(label: "Cancel", traits: [.button])
        let footer = makeTestHeistElement(label: "Footer", traits: [])
        var nodes: [TestInterfaceNode] = [
            .element(header),
            .container(
                makeTestSemanticContainer(
                    label: "Actions",
                    identifier: "actions",
                    frameX: 0,
                    frameY: 40,
                    frameWidth: 200,
                    frameHeight: 100
                ),
                containerName: "semantic_actions__actions",
                children: [.element(submit), .element(cancel)]
            ),
            .element(footer),
        ]
        if includeDuplicateGroup {
            let archive = makeTestHeistElement(label: "Archive", traits: [.button])
            nodes.insert(
                .container(
                    makeTestSemanticContainer(
                        label: "Actions",
                        identifier: "secondary_actions",
                        frameX: 0,
                        frameY: 160,
                        frameWidth: 200,
                        frameHeight: 60
                    ),
                    containerName: "semantic_actions__secondary_actions",
                    children: [.element(archive)]
                ),
                at: 2
            )
        }
        return makeTestInterface(nodes: nodes)
    }

    func setEnvironment(_ key: String, _ value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }

    /// Build a lower-level run_heist argument envelope from the canonical JSON
    /// object fields. This is intentionally not the public MCP authoring shape.
    static func inlineArguments(for plan: HeistPlan) throws -> TheFence.CommandArgumentEnvelope {
        let data = try JSONEncoder().encode(plan)
        let value = try JSONDecoder().decode(HeistValue.self, from: data)
        let fields: [String: HeistValue] = try XCTUnwrap(
            { () -> [String: HeistValue]? in
                guard case .object(let fields) = value else { return nil }
                return fields
            }(),
            "Expected the plan to encode as a JSON object"
        )
        return TheFence.CommandArgumentEnvelope(values: fields)
    }

    static func planSourceArguments(for plan: HeistPlan) throws -> TheFence.CommandArgumentEnvelope {
        TheFence.CommandArgumentEnvelope(values: [
            "plan": .string(try plan.canonicalSwiftDSL()),
        ])
    }

}

struct ExpectedDiagnosticFailure {
    let name: String
    let response: FenceResponse
    let code: KnownFailureCode
    let kind: DiagnosticFailureKind
    let phase: FailurePhase
    let message: String
    let retryable: Bool
}

func legacyHeistIdTargetValue(_ legacyHeistId: String) -> HeistValue {
    accessibilityTargetValue(["heistId": .string(legacyHeistId)])
}

func targetValue(
    label: String? = nil,
    identifier: String? = nil,
    value: String? = nil,
    traits: [String]? = nil,
    ordinal: Int? = nil
) -> HeistValue {
    var checks: [HeistValue] = []
    if let label {
        checks.append(predicateCheckValue(kind: "label", match: stringMatchValue(mode: "exact", value: label)))
    }
    if let identifier {
        checks.append(predicateCheckValue(kind: "identifier", match: stringMatchValue(mode: "exact", value: identifier)))
    }
    if let value {
        checks.append(predicateCheckValue(kind: "value", match: stringMatchValue(mode: "exact", value: value)))
    }
    if let traits {
        checks.append(predicateCheckValue(kind: "traits", values: traits.map { .string($0) }))
    }
    var target: [String: HeistValue] = ["checks": .array(checks)]
    if let ordinal { target["ordinal"] = .int(ordinal) }
    return accessibilityTargetValue(target)
}

func elementPredicateValue(
    label: String? = nil,
    identifier: String? = nil,
    value: String? = nil,
    traits: [String]? = nil
) -> HeistValue {
    var checks: [HeistValue] = []
    if let label {
        checks.append(predicateCheckValue(kind: "label", match: stringMatchValue(mode: "exact", value: label)))
    }
    if let identifier {
        checks.append(predicateCheckValue(kind: "identifier", match: stringMatchValue(mode: "exact", value: identifier)))
    }
    if let value {
        checks.append(predicateCheckValue(kind: "value", match: stringMatchValue(mode: "exact", value: value)))
    }
    if let traits {
        checks.append(predicateCheckValue(kind: "traits", values: traits.map { .string($0) }))
    }
    return accessibilityTargetValue(["checks": .array(checks)])
}

func stringMatchValue(mode: String, value: String) -> HeistValue {
    .object([
        "mode": .string(mode),
        "value": .string(value),
    ])
}

func accessibilityTargetValue(_ fields: [String: HeistValue]) -> HeistValue {
    .object(fields)
}

func predicateCheckValue(
    kind: String,
    match: HeistValue? = nil,
    values: [HeistValue]? = nil,
    check: HeistValue? = nil
) -> HeistValue {
    var object: [String: HeistValue] = ["kind": .string(kind)]
    if let match { object["match"] = match }
    if let values { object["values"] = .array(values) }
    if let check { object["check"] = check }
    return .object(object)
}

func containerPredicateCheckValue(
    kind: String,
    match: HeistValue? = nil,
    type: String? = nil,
    value: HeistValue? = nil
) -> HeistValue {
    var object: [String: HeistValue] = ["kind": .string(kind)]
    if let match { object["match"] = match }
    if let type { object["type"] = .string(type) }
    if let value { object["value"] = value }
    return .object(object)
}

func assertCompactHeistSummary(
    _ response: FenceResponse,
    stepLine: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let lines = response.compactFormatted().split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 2, file: file, line: line)
    XCTAssertTrue(
        lines.first?.hasPrefix("heist: 1 top-level steps in ") == true,
        lines.first ?? "<missing>",
        file: file,
        line: line
    )
    XCTAssertTrue(
        lines.first?.hasSuffix("ms [expectations: 1/1]") == true,
        lines.first ?? "<missing>",
        file: file,
        line: line
    )
    XCTAssertEqual(lines.last, stepLine, file: file, line: line)
}

func parseTypedExpectation(_ expectation: HeistValue?) throws -> AccessibilityPredicate? {
    var values: [String: HeistValue] = [:]
    if let expectation {
        values["expect"] = expectation
    }
    return try TheFence.ExpectationPayload(
        arguments: TheFence.CommandArgumentEnvelope(values: values)
    ).expectation
}
