import ButtonHeistTestSupport
import XCTest
import Network
import ButtonHeistSupport
@_spi(ButtonHeistTooling) @testable import ButtonHeist
@_spi(ButtonHeistInternals) import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension TheFenceHandlerTests {
    // MARK: - Run Heist Input Loading

    @ButtonHeistActor
    func testValidateHeistAdmitsCanonicalPlanWithoutConnection() async throws {
        let fence = TheFence(configuration: .init())

        let response = try await fence.execute(command: .validateHeist, values: [
            "plan": .string("HeistPlan { Warn(\"Check\") }"),
        ])

        guard case .heistValidation(let report) = response else {
            return XCTFail("Expected heistValidation response, got \(response)")
        }
        XCTAssertTrue(report.admissible)
        XCTAssertTrue(report.commandPassed)
        XCTAssertFalse(response.isFailure)
        XCTAssertEqual(report.invocation, .evaluated(.valid(.init(argumentProvided: false))))
        XCTAssertEqual(report.lint.mode, .compositionQuality)
        XCTAssertNotNil(report.canonicalPlan)
        XCTAssertFalse(fence.handoff.connectionLifecycle.isConnected)

        let json = try publicJSONProbe(response).object()
        XCTAssertTrue(try json.bool("admissible"))
        XCTAssertTrue(try json.object("plan").bool("valid"))
        XCTAssertEqual(try json.object("invocation").string("status"), "valid")
        XCTAssertEqual(try json.object("lint").string("status"), "passed")
    }

    @ButtonHeistActor
    func testValidateHeistClassifiesInvalidPlanAsFailure() async throws {
        let fence = TheFence(configuration: .init())

        let response = try await fence.execute(command: .validateHeist, values: [
            "plan": .string("HeistPlan { Activate( }"),
        ])

        guard case .heistValidation(let report) = response else {
            return XCTFail("Expected heistValidation response, got \(response)")
        }
        XCTAssertTrue(response.isFailure)
        XCTAssertFalse(report.admissible)
        XCTAssertFalse(report.commandPassed)
        XCTAssertFalse(report.plan.diagnostics.isEmpty)
        XCTAssertEqual(report.invocation, .notEvaluated)
        XCTAssertEqual(report.lint, .notEvaluated(mode: .compositionQuality))
        XCTAssertNil(report.canonicalPlan)

        let json = try publicJSONProbe(response).object()
        XCTAssertEqual(try json.object("invocation").string("status"), "not_evaluated")
        XCTAssertEqual(try json.array("buildDiagnostics").count, report.plan.diagnostics.count)
    }

    @ButtonHeistActor
    func testValidateHeistReportsMissingParameterizedRootArgument() async throws {
        let fence = TheFence(configuration: .init())
        let response = try await fence.execute(command: .validateHeist, values: [
            "plan": .string("HeistPlan(\"search\", parameter: \"query\") { query in Warn(\"Check\") }"),
        ])

        guard case .heistValidation(let report) = response else {
            return XCTFail("Expected heistValidation response, got \(response)")
        }
        XCTAssertTrue(report.plan.isValid)
        XCTAssertFalse(report.argumentProvided)
        XCTAssertFalse(report.invocation.diagnostics.isEmpty)
        XCTAssertFalse(report.admissible)
        XCTAssertTrue(response.isFailure)

        let invocation = try publicJSONProbe(response).object().object("invocation")
        XCTAssertEqual(try invocation.string("status"), "invalid")
        XCTAssertFalse(try invocation.bool("argumentProvided"))
        XCTAssertEqual(try invocation.array("diagnostics").count, report.invocation.diagnostics.count)
    }

    @ButtonHeistActor
    func testValidateHeistStrictLintCanFailOtherwiseAdmissiblePlan() async throws {
        let fence = TheFence(configuration: .init())
        let response = try await fence.execute(command: .validateHeist, values: [
            "plan": .string("HeistPlan { Activate(.label(\"Save\")) }"),
            "lint": .string("strict_test"),
        ])

        guard case .heistValidation(let report) = response else {
            return XCTFail("Expected heistValidation response, got \(response)")
        }
        XCTAssertTrue(report.admissible)
        XCTAssertFalse(report.commandPassed)
        XCTAssertTrue(response.isFailure)
        XCTAssertTrue(report.lint.hasErrors)
        XCTAssertEqual(report.lint.findings.map(\.message), ["Semantic action has no expectation"])
        XCTAssertEqual(report.lint, .findings(mode: .strictTest, values: report.lint.findings))
    }

    @ButtonHeistActor
    func testRunHeistReadsPlanFromArtifactPathIntoSwiftObjects() async throws {
        let fence = TheFence(configuration: .init())
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fence-runheist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // A hyphenated file name is NOT a valid Swift-style identifier. The fence
        // must run the plan exactly as authored — stamping the file name into the
        // plan's `name` would fail runtime safety and silently reduce the run
        // to zero steps (the run_heist replay no-op regression).
        let heistURL = temp.appendingPathComponent("bh-demo-smoke.heist")
        let plan = try HeistPlan(name: "demoSmoke", body: [.warn(WarnStep(message: "from artifact"))])
        try HeistArtifactCodec.writePlan(plan, to: heistURL)

        let request = try fence.decodeRunHeistRequest(
            TheFence.CommandArgumentEnvelope(values: ["path": .string(heistURL.path)])
        )

        // The fence reads the file into a HeistPlan directly — no parameter
        // round-trip — and does not invent a name from the file.
        XCTAssertEqual(request.plan.body, plan.body)
        XCTAssertEqual(request.plan.name, "demoSmoke")
    }

    @ButtonHeistActor
    func testRunHeistDescriptorRejectsUnknownWireKeyBeforePlanAdmission() async {
        let fence = TheFence(configuration: .init())
        let input = FenceCommandInput(
            command: .runHeist,
            arguments: .init(values: [
                "plan": .string("HeistPlan { Warn(\"Check\") }"),
                "body": .array([]),
            ])
        )

        XCTAssertThrowsError(try fence.admit(input)) { error in
            XCTAssertEqual((error as? SchemaValidationError)?.field, "body")
        }
    }

    @ButtonHeistActor
    func testRunHeistDecodesHeistPlanSourceThroughThePlans() async throws {
        let fence = TheFence(configuration: .init())
        let request = try fence.decodeRunHeistRequest(
            TheFence.CommandArgumentEnvelope(values: [
                "plan": .string("""
                HeistPlan {
                    Activate(.label("Pay")).expect(.screenChanged)
                }
                """),
            ])
        )

        XCTAssertEqual(request.plan.body, [
            .action(ActionStep(
                command: .activate(.predicate(.label("Pay"))),
                expectationPolicy: .expect(ActionExpectation(
                    predicate: .screenChanged
                )))),
        ])
    }

    @ButtonHeistActor
    func testPerformExecutesOnePrimitiveStepThroughValidatedPlan() async throws {
        let (fence, mockConn) = makeConnectedFence()
        fence.handoff.connect(to: TheFenceFixtures.testDevice)

        let response = try await fence.execute(command: .perform, values: [
            "step": .string(#"Activate(.label("Pay"))"#),
        ])

        guard case .heistExecution(let report) = response else {
            return XCTFail("Expected heistExecution response, got \(response)")
        }
        XCTAssertEqual(mockConn.sent.sentHeistPlan?.body, [
            .action(ActionStep(command: .activate(.predicate(.label("Pay"))))),
        ])
        XCTAssertEqual(report.nodes.map(\.kind), [.action])
        XCTAssertNil(report.failure)

        let json = try publicJSONProbe(response).object()
        try json.assertMissing("method")
        let firstNode = try XCTUnwrap(try json.object("report").array("nodes").first)
        XCTAssertEqual(try firstNode.string("kind"), "action")
        try firstNode.assertMissing("action")
        try firstNode.object("evidence").assertPresent("action")
    }

    @ButtonHeistActor
    func testPerformDecodesSimpleWaitStepThroughThePlans() async throws {
        let fence = TheFence(configuration: .init())

        let request = try fence.decodePerformRequest(TheFence.CommandArgumentEnvelope(values: [
            "step": .string(#"WaitFor(.exists(.label("Pay")), timeout: 5)"#),
        ]))

        XCTAssertEqual(request.plan.body, [
            .wait(WaitStep(predicate: .exists(.label("Pay")), timeout: 5)),
        ])
    }

    @ButtonHeistActor
    func testPerformRejectsWaitForElseBranch() async {
        let fence = TheFence(configuration: .init())

        XCTAssertThrowsError(try fence.decodePerformRequest(TheFence.CommandArgumentEnvelope(values: [
            "step": .string("""
            WaitFor(.exists(.label("Receipt")), timeout: 5).else {
                Warn("fallback")
            }
            """),
        ]))) { error in
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("perform accepts one action statement or one simple WaitFor statement"),
                message
            )
        }
    }

    @ButtonHeistActor
    func testPerformUnsupportedStepDiagnosticBranchUsesCodeNotMessage() async {
        let fence = TheFence(configuration: .init())
        let guidance = "perform accepts one action statement or one simple WaitFor statement"

        let codeSelectedError = fence.performStepSourceLoadError(for: [
            HeistBuildDiagnostic(
                code: .sourceWaitForGate,
                phase: .sourceCompilation,
                message: "compiler wording can change"
            ),
        ])
        let codeSelectedMessage = String(describing: codeSelectedError)
        XCTAssertTrue(codeSelectedMessage.contains(guidance), codeSelectedMessage)
        XCTAssertFalse(codeSelectedMessage.contains("compiler wording can change"), codeSelectedMessage)

        let messageOnlyError = fence.performStepSourceLoadError(for: [
            HeistBuildDiagnostic(
                code: .sourceInvalidSyntax,
                phase: .sourceCompilation,
                message: "WaitFor is a gate"
            ),
        ])
        let messageOnlyMessage = String(describing: messageOnlyError)
        XCTAssertTrue(messageOnlyMessage.contains("WaitFor is a gate"), messageOnlyMessage)
        XCTAssertFalse(messageOnlyMessage.contains(guidance), messageOnlyMessage)
    }

    @ButtonHeistActor
    func testPerformRejectsProgramShapedSource() async throws {
        let fence = TheFence(configuration: .init())
        let invalidSteps = [
            """
            Activate(.label("Pay"))
            Activate(.label("Confirm"))
            """,
            """
            HeistDef<Void>("helper") {
                Activate(.label("Pay"))
            }
            Activate(.label("Pay"))
            """,
            """
            If(.exists(.label("Pay"))) {
                Activate(.label("Pay"))
            }
            """,
            """
            WaitFor(.exists(.label("Receipt")), timeout: 5) {
                Activate(.label("Done"))
            }
            """,
            """
            ForEach("Milk") { item in
                TypeText(item)
            }
            """,
            #"Warn("ready")"#,
            #"Fail("stop")"#,
        ]

        for step in invalidSteps {
            XCTAssertThrowsError(try fence.decodePerformRequest(TheFence.CommandArgumentEnvelope(values: [
                "step": .string(step),
            ])), step) { error in
                let message = String(describing: error)
                XCTAssertTrue(
                    message.contains("perform accepts one action statement or one simple WaitFor statement")
                        || message.contains("expected an identifier"),
                    message
                )
            }
        }
    }

    @ButtonHeistActor
    func testPerformRejectsNativeSwiftAtRuntimeBoundary() async {
        await assertValidationError(
            command: .perform,
            arguments: [
                "step": .string("""
                let label = "Pay"
                Activate(.label(label))
                """),
            ],
            contains: "let declarations are not supported inside ButtonHeist DSL bodies"
        )
    }

}
