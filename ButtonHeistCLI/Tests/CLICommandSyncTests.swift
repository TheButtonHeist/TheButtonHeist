import XCTest
@_spi(ButtonHeistTooling) import ButtonHeist
import Foundation
import ThePlans
import TheScore
@testable import ButtonHeistCLIExe

final class CLICommandSyncTests: XCTestCase {

    func testTopLevelSubcommandsMatchFenceCLIExposure() {
        let descriptorNames = TheFence.Command.cliDirectCommandDescriptors.map(\.command.rawValue)
        let expected = (descriptorNames + ["adversarial_catalog", "json_lines"]).sorted()

        XCTAssertEqual(topLevelCommandNames().sorted(), expected)
    }

    @ButtonHeistActor
    func testNotificationsCommandUsesCanonicalFenceDescriptor() async throws {
        let descriptor = try await GetNotificationsCommand.parse([]).runnerDescriptor()

        XCTAssertEqual(descriptor.fenceDescriptor.command, .getNotifications)
        XCTAssertEqual(GetNotificationsCommand.configuration.commandName, "get_notifications")
    }

    @ButtonHeistActor
    func testOneShotDescriptorsOwnConnectedAndLocalLifecycleModes() async throws {
        let connected = try await PingCommand.parse([]).runnerDescriptor()
        let local = try await ListDevicesCommand.parse([]).runnerDescriptor()

        XCTAssertEqual(connected.fenceDescriptor.command, .ping)
        XCTAssertEqual(connected.executionMode, .connected)
        XCTAssertEqual(local.fenceDescriptor.command, .listDevices)
        XCTAssertEqual(local.executionMode, .direct)
    }

    func testJSONLinesDefaultOutputIsCanonicalJSON() {
        XCTAssertEqual(JSONLinesDefaults.outputFormat, .json)
    }

    func testGetInterfaceAcceptsDiscoveryLimitOptions() throws {
        let command = try GetInterfaceCommand.parse([
            "--max-scrolls-per-container", "25",
            "--max-scrolls-per-discovery", "40",
        ])

        XCTAssertEqual(command.discoveryLimits.maxScrollsPerContainer, 25)
        XCTAssertEqual(command.discoveryLimits.maxScrollsPerDiscovery, 40)
        let arguments = try command.requestArguments()
        XCTAssertEqual(arguments.value(for: "maxScrollsPerContainer"), .int(25))
        XCTAssertEqual(arguments.value(for: "maxScrollsPerDiscovery"), .int(40))
    }

    func testGetInterfaceEncodesCanonicalTargetUnderSubtree() throws {
        let command = try GetInterfaceCommand.parse([
            "--label", "Checkout",
            "--traits", "button",
            "--ordinal", "1",
            "--max-scrolls-per-container", "25",
        ])
        let target = try XCTUnwrap(command.subtree.parsedTarget())
        let arguments = try command.requestArguments()

        XCTAssertEqual(
            arguments.value(for: "subtree"),
            try TheFence.HeistValuePayloadEncoder.encode(target)
        )
        XCTAssertEqual(arguments.value(for: "maxScrollsPerContainer"), .int(25))
        XCTAssertNil(arguments.value(for: "target"))
        XCTAssertNil(arguments.value(for: "checks"))
    }

    func testGetInterfaceRejectsSubtreePrefixedAlias() {
        XCTAssertThrowsError(try GetInterfaceCommand.parse(["--subtree-label", "Checkout"]))
    }

    func testActionCommandEncodesCanonicalActionAndExpectationJSON() throws {
        let command = try ActionCommand.parse([
            #"{"type":"activate","payload":{"target":{"checks":[{"kind":"label","match":{"mode":"exact","value":"Pay"}}]}}}"#,
            "--expect", #"{"type":"changed","scope":"screen"}"#,
            "--timeout", "2",
        ])
        let arguments = try command.requestArguments()

        guard case .object(let action)? = arguments.value(for: "action") else {
            return XCTFail("Expected canonical action object")
        }
        XCTAssertEqual(action["type"], .string("activate"))
        XCTAssertEqual(arguments.value(for: "timeout"), .double(2))
        XCTAssertEqual(arguments.value(for: "expect"), .object([
            "type": .string("changed"),
            "scope": .string("screen"),
        ]))
    }

    func testActionCommandRejectsNonObjectJSON() throws {
        let command = try ActionCommand.parse([#"["dismiss"]"#])

        XCTAssertThrowsError(try command.requestArguments()) { error in
            XCTAssertTrue(String(describing: error).contains("action must be a JSON object"))
        }
    }

    func testFenceExpectationArgumentContractRejectsShorthand() {
        XCTAssertThrowsError(try TheFence.parseExpectationArgument("screen_changed")) { error in
            XCTAssertTrue(String(describing: error).contains("Expected expectation JSON object"))
        }
    }

    func testFenceExpectationArgumentContractAcceptsJsonObject() throws {
        let parsed = try TheFence.parseExpectationArgument(
            #"{"type":"changed","scope":"elements","assertions":[]}"#
        )

        guard case .object(let object) = parsed else {
            return XCTFail("expected object expectation")
        }
        XCTAssertEqual(object["type"], .string("changed"))
    }

    func testRunHeistForwardsInlineButtonHeistSource() throws {
        let source = #"HeistPlan("smoke") { Warn("Check login state") }"#
        let arguments = try RunHeistCommand.planArguments(
            inline: source
        )

        XCTAssertEqual(arguments.value(for: "plan"), .string(source))
        XCTAssertNil(arguments.value(for: "version"))
        XCTAssertNil(arguments.value(for: "body"))
    }

    func testRunHeistRejectsEmptyInlineButtonHeistSource() {
        XCTAssertThrowsError(try RunHeistCommand.planArguments(inline: "   ")) { error in
            XCTAssertTrue(String(describing: error).contains("--plan must be ButtonHeist DSL source"))
        }
    }

    func testRunHeistDoesNotExpandRawJSONIRInlinePlan() throws {
        let rawJSON = #"{"version":2,"body":[{"type":"warn","warn":{"message":"x"}}]}"#
        let arguments = try RunHeistCommand.planArguments(inline: rawJSON)

        XCTAssertEqual(arguments.value(for: "plan"), .string(rawJSON))
        XCTAssertNil(arguments.value(for: "version"))
        XCTAssertNil(arguments.value(for: "body"))
    }

    func testRunHeistRequiresExactlyOnePlanSource() {
        XCTAssertThrowsError(try RunHeistCommand.planArguments(inline: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("Must supply --path or --plan"))
        }
        XCTAssertThrowsError(try RunHeistCommand.planArguments(
            inline: #"HeistPlan { Warn("x") }"#,
            path: "Flow.heist",
            entry: nil
        )) { error in
            XCTAssertTrue(String(describing: error).contains("mutually exclusive"))
        }
    }

    func testRunHeistForwardsArtifactPathToFenceWithoutReadingIt() throws {
        // The CLI must not read or re-encode the plan — it forwards the path so
        // the fence reads it into a HeistPlan. No version/body fields are sent.
        let arguments = try RunHeistCommand.planArguments(
            inline: nil,
            path: "Flow.heist",
            entry: nil
        )

        XCTAssertEqual(arguments.value(for: "path"), .string("Flow.heist"))
        XCTAssertNil(arguments.value(for: "version"))
        XCTAssertNil(arguments.value(for: "body"))
    }

    func testRunHeistForwardsRootArgumentWithPathSource() throws {
        let arguments = try RunHeistCommand.planArguments(
            inline: nil,
            path: "Search.heist",
            entry: nil,
            argument: #"{"type":"string","value":"milk"}"#
        )

        XCTAssertEqual(arguments.value(for: "path"), .string("Search.heist"))
        XCTAssertEqual(arguments.value(for: "argument"), .object([
            "type": .string("string"),
            "value": .string("milk"),
        ]))
    }

    func testRunHeistForwardsRootArgumentWithInlineSource() throws {
        let source = """
        HeistPlan("search", parameter: .string("query")) {
            Warn("Check")
        }
        """
        let arguments = try RunHeistCommand.planArguments(
            inline: source,
            path: nil,
            entry: nil,
            argument: #"{"type":"string","value":"milk"}"#
        )

        XCTAssertEqual(arguments.value(for: "plan"), .string(source))
        XCTAssertEqual(arguments.value(for: "argument"), .object([
            "type": .string("string"),
            "value": .string("milk"),
        ]))
    }

    func testRunHeistCompilesSwiftSourceToTemporaryHeistArtifact() async throws {
        // Swift source compiles to a temp .heist the fence reads — the plan
        // crosses through the canonical codec, never a parameter round-trip.
        let plan = try HeistPlan(name: "swiftFlow", body: [.warn(WarnStep(message: "from swift"))])
        let prepared = try await RunHeistCommand.prepareInput(
            path: "Flow.swift",
            entry: "makeHeist",
            compileSwiftSource: { _, _ in plan }
        )
        defer { prepared.cleanup() }

        let artifactPath = try XCTUnwrap(prepared.path)
        XCTAssertTrue(artifactPath.hasSuffix(".heist"))
        XCTAssertNil(prepared.entry)

        // The compiled artifact round-trips losslessly through the canonical codec.
        let artifact = try HeistArtifactCodec.read(from: URL(fileURLWithPath: artifactPath))
        XCTAssertEqual(artifact.plan, plan)
        XCTAssertEqual(artifact.plan.name, "swiftFlow")

        // And it dispatches as a .heist path, not inline version/body params.
        let arguments = try RunHeistCommand.planArguments(
            inline: nil,
            path: prepared.path,
            entry: prepared.entry
        )
        XCTAssertEqual(arguments.value(for: "path"), .string(artifactPath))
        XCTAssertNil(arguments.value(for: "version"))
    }

    func testRunHeistSwiftSourceRequiresEntry() async {
        do {
            _ = try await RunHeistCommand.prepareInput(path: "Flow.swift", entry: nil)
            XCTFail("Expected missing entry to throw")
        } catch {
            XCTAssertTrue(String(describing: error).contains("--entry is required for Swift source input"))
        }
    }

    func testListHeistsUsesRunHeistPlanSourceShape() throws {
        let source = #"HeistPlan("flow") { Warn("Check") }"#
        let arguments = try RunHeistCommand.planArguments(
            inline: source,
            path: nil,
            entry: nil,
            commandName: "list_heists"
        )

        XCTAssertEqual(arguments.value(for: "plan"), .string(source))
        XCTAssertNil(arguments.value(for: "version"))
        XCTAssertNil(arguments.value(for: "path"))
    }

    func testDescribeHeistAddsSelectorWithoutDroppingInlinePlanName() throws {
        let source = #"HeistPlan("flow") { Warn("Check") }"#
        let arguments = try RunHeistCommand.planArguments(
            inline: source,
            path: nil,
            entry: nil,
            commandName: "describe_heist",
            additionalFields: [CommandArgumentFields.value("heist", "flow")]
        )

        XCTAssertEqual(arguments.value(for: "heist"), .string("flow"))
        XCTAssertEqual(arguments.value(for: "plan"), .string(source))
        XCTAssertNil(arguments.value(for: "version"))
    }

    func testValidateHeistBuildsOfflineRequestWithTypedLint() throws {
        let source = #"HeistPlan { Warn("Check") }"#
        let command = try ValidateHeistCommand.parse([
            "--plan", source,
            "--lint", "strict_test",
        ])

        let arguments = try command.requestArguments()

        XCTAssertEqual(arguments.value(for: "plan"), .string(source))
        XCTAssertEqual(arguments.value(for: "lint"), .string("strict_test"))
        XCTAssertNil(arguments.value(for: "path"))
    }

    func testRunHeistRejectsEntryWithoutPath() {
        XCTAssertThrowsError(try RunHeistCommand.planArguments(
            inline: #"HeistPlan { Warn("x") }"#,
            path: nil,
            entry: "makeHeist"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("--entry is only valid with Swift source input"))
        }
    }

    func testMachineRequestParserParsesCanonicalMachineJSON() throws {
        let parsed = try CLIMachineRequestParser.parse(
            #"{"command":"action","action":{"type":"typeText","payload":{"text":{"value":"hello","mode":"append"}}}}"#
        )

        XCTAssertEqual(parsed.command, .action)
        guard case .object(let action)? = parsed.argument("action") else {
            return XCTFail("Expected action object")
        }
        XCTAssertEqual(action["type"], .string("typeText"))
    }

    func testMachineRequestParserRejectsHumanTextInJSONLinesMode() {
        XCTAssertThrowsError(
            try CLIMachineRequestParser.parse("activate button_save")
        ) { error in
            let failure = machineRequestFailure(from: error)
            XCTAssertTrue(
                failure.message.contains("Expected JSON object input"),
                failure.message
            )
            XCTAssertEqual(failure.details.code, .requestInvalid)
        }
    }

    func testMachineRequestParserRejectsMalformedMachineJSON() {
        XCTAssertThrowsError(
            try CLIMachineRequestParser.parse(#"{"command":"ping","#)
        ) { error in
            let failure = machineRequestFailure(from: error)
            let message = failure.message
            XCTAssertTrue(message.contains("Public JSON request is not valid JSON"), message)
            XCTAssertEqual(failure.details.code, .requestInvalid)
        }
    }

    func testMachineRequestParserAcceptsCanonicalMachineJSONInJSONLinesMode() throws {
        let parsed = try CLIMachineRequestParser.parse(
            #"""
            {
              "command": "action",
              "action": {
                "type": "activate",
                "payload": {
                  "target": {
                    "checks": [{"kind": "identifier", "match": {"mode": "exact", "value": "button_save"}}]
                  }
                }
              }
            }
            """#
        )

        XCTAssertEqual(parsed.command, .action)
        guard case .object(let action)? = parsed.argument("action") else {
            return XCTFail("expected typed action object")
        }
        XCTAssertEqual(action["type"], .string("activate"))
    }

    func testMachineRequestParserDefersCommandValidationToFenceAdmission() throws {
        let parsed = try CLIMachineRequestParser.parse(
            #"{"command":"action","action":{"type":"dismiss"},"timeout":0,"unknown":true}"#
        )

        XCTAssertEqual(parsed.command, .action)
        XCTAssertEqual(parsed.argument("timeout"), .int(0))
        XCTAssertEqual(parsed.argument("unknown"), .bool(true))
    }

    func testMachineRequestParserAcceptsPerformInJSONLinesMode() throws {
        let parsed = try CLIMachineRequestParser.parse(
            #"{"command":"perform","step":"Activate(.label(\"Pay\"))"}"#
        )

        XCTAssertEqual(parsed.command, .perform)
        XCTAssertEqual(parsed.argument("step"), .string(#"Activate(.label("Pay"))"#))
    }

    func testMachineRequestParserAcceptsRunHeistInJSONLinesMode() throws {
        let parsed = try CLIMachineRequestParser.parse(
            #"{"command":"run_heist","plan":"HeistPlan(\"one\") { Warn(\"check\") }"}"#
        )

        XCTAssertEqual(parsed.command, .runHeist)
        XCTAssertEqual(parsed.argument("plan"), .string(#"HeistPlan("one") { Warn("check") }"#))
    }

    func testMachineRequestParserAcceptsValidateHeistInJSONLinesMode() throws {
        let parsed = try CLIMachineRequestParser.parse(
            #"{"command":"validate_heist","plan":"HeistPlan { Warn(\"check\") }","lint":"strict_test"}"#
        )

        XCTAssertEqual(parsed.command, .validateHeist)
        XCTAssertEqual(parsed.argument("lint"), .string("strict_test"))
    }

    func testMachineRequestParserRejectsHugeMachineJSONLineBeforeDecoding() {
        let hugeText = String(repeating: "x", count: PublicJSONInputLimits.maxRequestBytes + 1)
        let line = "{\"command\":\"action\",\"action\":{\"type\":\"setPasteboard\",\"payload\":{\"text\":\"" + hugeText + "\"}}}"

        XCTAssertThrowsError(try CLIMachineRequestParser.parse(line)) { error in
            let failure = machineRequestFailure(from: error)
            let message = failure.message
            XCTAssertTrue(
                message.contains("Public JSON request exceeds \(PublicJSONInputLimits.maxRequestBytes) bytes"),
                message
            )
            XCTAssertEqual(failure.details.code, .requestInvalid)
        }
    }

    func testMachineRequestParserRejectsDeeplyNestedMachineJSONBeforeDecoding() {
        var payload = "true"
        for index in 0..<PublicJSONInputLimits.maxNestingDepth {
            if index.isMultiple(of: 2) {
                payload = "{\"child\":\(payload)}"
            } else {
                payload = "[\(payload)]"
            }
        }
        let line = "{\"command\":\"ping\",\"payload\":\(payload)}"

        XCTAssertThrowsError(try CLIMachineRequestParser.parse(line)) { error in
            let failure = machineRequestFailure(from: error)
            let message = failure.message
            XCTAssertTrue(
                message.contains(
                    "Public JSON request nesting depth exceeds \(PublicJSONInputLimits.maxNestingDepth)"
                ),
                message
            )
            XCTAssertEqual(failure.details.code, .requestInvalid)
        }
    }

    func testMachineRequestParserRejectsExcessiveMachineJSONKeyCountBeforeDecoding() {
        var fields = ["\"command\":\"ping\""]
        for index in 0..<PublicJSONInputLimits.maxTotalObjectKeys {
            fields.append("\"\(index)\":\(index)")
        }
        let line = "{\(fields.joined(separator: ","))}"

        XCTAssertThrowsError(try CLIMachineRequestParser.parse(line)) { error in
            let failure = machineRequestFailure(from: error)
            let message = failure.message
            XCTAssertTrue(
                message.contains(
                    "Public JSON request object key count exceeds \(PublicJSONInputLimits.maxTotalObjectKeys)"
                ),
                message
            )
            XCTAssertEqual(failure.details.code, .requestInvalid)
        }
    }

    func testCommandArgumentFieldsProjectCanonicalTargetEnvelope() throws {
        let expectedTarget = AccessibilityTarget.predicate(ElementPredicate(
                [
                    .label("Rotor Host"),
                    .identifier("rotor.host"),
                    .traits([.selected, .button]),
                    .exclude(.traits([.notEnabled, .header])),
                ]
            ),
            ordinal: 1
        )
        let arguments = CommandArgumentFields(
            CommandArgumentFields.encoded("target", expectedTarget)
        ).envelope

        XCTAssertEqual(arguments.value(for: "target"), .object([
            "checks": .array([
                .object([
                    "kind": .string("label"),
                    "match": .object([
                        "mode": .string("exact"),
                        "value": .string("Rotor Host"),
                    ]),
                ]),
                .object([
                    "kind": .string("identifier"),
                    "match": .object([
                        "mode": .string("exact"),
                        "value": .string("rotor.host"),
                    ]),
                ]),
                .object([
                    "kind": .string("traits"),
                    "values": .array([.string("button"), .string("selected")]),
                ]),
                .object([
                    "kind": .string("exclude"),
                    "check": .object([
                        "kind": .string("traits"),
                        "values": .array([.string("header"), .string("notEnabled")]),
                    ]),
                ]),
            ]),
            "ordinal": .int(1),
        ]))
    }

    private func topLevelCommandNames() -> [String] {
        ButtonHeistApp.configuration.subcommands.map { commandType in
            commandType.configuration.commandName ?? String(describing: commandType)
        }
    }

    private func machineRequestFailure(
        from error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> DiagnosticFailure {
        guard let failure = error as? DiagnosticFailure else {
            XCTFail("expected DiagnosticFailure, got \(error)", file: file, line: line)
            return DiagnosticFailure(
                message: String(describing: error),
                details: FailureDetails(code: .clientUnknown)
            )
        }
        return failure
    }
}

private extension FenceCommandInput {
    func argument(_ key: String) -> HeistValue? {
        arguments.value(for: key)
    }
}
