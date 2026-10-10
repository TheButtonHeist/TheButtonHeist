import ButtonHeistTestSupport
import XCTest
import Network
import ButtonHeistSupport
@_spi(ButtonHeistTooling) @testable import ButtonHeist
@_spi(ButtonHeistInternals) import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension TheFenceHandlerTests {

    // MARK: - Plan Execution and Discovery Commands
    @ButtonHeistActor
    func testRunHeistSendsValidatedPlanAndProjectsServerResult() async throws {
        let (fence, mockConn) = makeConnectedFence()
        let scriptedResult = HeistResultFixture.result(steps: [
            HeistResultFixture.warning(message: "server result"),
        ])
        mockConn.responseScript = { _ in scriptedHeistResponse(scriptedResult) }
        fence.handoff.connect(to: TheFenceFixtures.testDevice)

        let response = try await fence.execute(command: .runHeist, values: [
            "plan": .string(Self.pureRuntimeHeistSource),
        ])

        guard case .heistExecution(let plan, let report) = response else {
            return XCTFail("Expected heistExecution response, got \(response)")
        }
        XCTAssertEqual(plan.name, "agentFlow")
        XCTAssertEqual(mockConn.sent.sentHeistPlan, plan)
        XCTAssertEqual(mockConn.sent.sentHeistRun?.argument, HeistArgument.none)
        XCTAssertEqual(mockConn.sent.sentHeistRun?.timeout, .default)
        XCTAssertEqual(
            mockConn.sent.sentHeistRun?.actionExpectationTimeoutPolicy,
            .default
        )
        XCTAssertEqual(report, HeistReport.project(result: scriptedResult))
    }

    @ButtonHeistActor
    func testRunHeistPropagatesExplicitWholeHeistTimeout() async throws {
        let (fence, mockConn) = makeConnectedFence()
        mockConn.responseScript = { _ in scriptedHeistResponse() }
        fence.handoff.connect(to: TheFenceFixtures.testDevice)

        _ = try await fence.execute(command: .runHeist, values: [
            "plan": .string(Self.pureRuntimeHeistSource),
            "timeout": .double(120),
        ])

        XCTAssertEqual(mockConn.sent.sentHeistRun?.timeout, 120)
    }

    @ButtonHeistActor
    func testRunHeistSendsAuthoredActionExpectationAndSessionPolicy() async throws {
        let policy = ActionExpectationTimeoutPolicy(standard: 3, screenTransition: 12)
        let (fence, mockConn) = makeConnectedFence(configuration: .init(
            actionExpectationTimeoutPolicy: policy
        ))
        mockConn.responseScript = { _ in scriptedHeistResponse() }

        _ = try await fence.execute(command: .runHeist, values: [
            "plan": .string("""
            HeistPlan {
                Activate(.label("Pay")).expect(.screenChanged)
            }
            """),
        ])

        guard case .action(let action)? = mockConn.sent.sentHeistPlan?.body.first else {
            return XCTFail("Expected authored action plan")
        }
        XCTAssertEqual(action.expectationPolicy.expectedExpectation?.timeout, .sessionDefault)
        XCTAssertEqual(mockConn.sent.sentHeistRun?.actionExpectationTimeoutPolicy, policy)
    }

    @ButtonHeistActor
    func testSingleStepDefaultActionBudgetIncludesStructuralNoChangeSettlement() async throws {
        let policy = ActionExpectationTimeoutPolicy(standard: 7, screenTransition: 12)
        let (fence, mockConn) = makeConnectedFence(configuration: .init(
            actionExpectationTimeoutPolicy: policy,
            postActionExpectationTimeoutBuffer: 11
        ))

        _ = try await fence.execute(command: .action, values: [
            "action": try TheFence.HeistValuePayloadEncoder.encode(
                HeistActionCommand.activate(.label("Pay"))
            ),
        ])

        XCTAssertEqual(
            mockConn.sent.sentHeistRun?.timeout.seconds,
            FenceCommandFixedTimeout.standardAction.seconds + policy.standard.seconds
        )
    }

    @ButtonHeistActor
    func testSingleStepAuthoredActionBudgetUsesAuthoredTimeoutWithoutExtraStandardSettlement() async throws {
        let policy = ActionExpectationTimeoutPolicy(standard: 7, screenTransition: 12)
        let authoredTimeout: TimeInterval = 19
        let (fence, mockConn) = makeConnectedFence(configuration: .init(
            actionExpectationTimeoutPolicy: policy,
            postActionExpectationTimeoutBuffer: 11
        ))

        _ = try await fence.execute(command: .action, values: [
            "action": try TheFence.HeistValuePayloadEncoder.encode(
                HeistActionCommand.activate(.label("Pay"))
            ),
            "expect": .object([
                "type": .string("changed"),
                "scope": .string("screen"),
            ]),
            "timeout": .double(authoredTimeout),
        ])

        XCTAssertEqual(
            mockConn.sent.sentHeistRun?.timeout.seconds,
            FenceCommandFixedTimeout.standardAction.seconds + authoredTimeout
        )
    }

    @ButtonHeistActor
    func testPerformDefaultActionBudgetIncludesStructuralNoChangeSettlement() async throws {
        let policy = ActionExpectationTimeoutPolicy(standard: 7, screenTransition: 12)
        let (fence, mockConn) = makeConnectedFence(configuration: .init(
            actionExpectationTimeoutPolicy: policy,
            postActionExpectationTimeoutBuffer: 11
        ))

        _ = try await fence.execute(command: .perform, values: [
            "step": .string(#"Activate(.label("Pay"))"#),
        ])

        XCTAssertEqual(
            mockConn.sent.sentHeistRun?.timeout.seconds,
            FenceCommandFixedTimeout.standardAction.seconds + policy.standard.seconds
        )
    }

    @ButtonHeistActor
    func testPerformAuthoredActionBudgetUsesAuthoredTimeoutWithoutExtraStandardSettlement() async throws {
        let policy = ActionExpectationTimeoutPolicy(standard: 7, screenTransition: 12)
        let authoredTimeout: TimeInterval = 19
        let (fence, mockConn) = makeConnectedFence(configuration: .init(
            actionExpectationTimeoutPolicy: policy,
            postActionExpectationTimeoutBuffer: 11
        ))

        _ = try await fence.execute(command: .perform, values: [
            "step": .string(#"Activate(.label("Pay")).expect(.screenChanged, timeout: 19)"#),
        ])

        XCTAssertEqual(
            mockConn.sent.sentHeistRun?.timeout.seconds,
            FenceCommandFixedTimeout.standardAction.seconds + authoredTimeout
        )
    }

    @ButtonHeistActor
    func testSingleStepTimeoutWithoutExpectationExtendsActionBudget() async throws {
        let policy = ActionExpectationTimeoutPolicy(standard: 7, screenTransition: 12)
        let (fence, mockConn) = makeConnectedFence(configuration: .init(
            actionExpectationTimeoutPolicy: policy,
            postActionExpectationTimeoutBuffer: 11
        ))

        _ = try await fence.execute(command: .action, values: [
            "action": try TheFence.HeistValuePayloadEncoder.encode(
                HeistActionCommand.activate(.label("Pay"))
            ),
            "timeout": .double(19),
        ])

        XCTAssertEqual(
            mockConn.sent.sentHeistRun?.timeout.seconds,
            19 + policy.standard.seconds
        )
    }

    @ButtonHeistActor
    func testSingleStepBudgetAddsTransportHeadroomOnlyToClientDeadline() async throws {
        let policy = ActionExpectationTimeoutPolicy(standard: 7, screenTransition: 12)
        let plan = try HeistPlan(version: HeistPlan.currentVersion, body: [
            .action(ActionStep(command: .activate(.predicate(.label("Pay")))))
        ])

        let budget = try TheFence.HeistExecutionBudget.project(
            plan: plan,
            timeoutSource: .projected(actionTimeoutOverride: nil),
            configuration: .init(
                actionExpectationTimeoutPolicy: policy,
                postActionExpectationTimeoutBuffer: 11
            )
        )

        XCTAssertEqual(
            budget.serverTimeout.seconds,
            FenceCommandFixedTimeout.standardAction.seconds + policy.standard.seconds
        )
        XCTAssertEqual(budget.transportTimeout, budget.serverTimeout.seconds + 11)
    }

    @ButtonHeistActor
    func testHeistBudgetRejectsInvalidTransportHeadroom() async throws {
        let plan = try HeistPlan(body: [
            .warn(WarnStep(message: "budget probe")),
        ])

        for headroom in [-1, .infinity, .nan] {
            XCTAssertThrowsError(try TheFence.HeistExecutionBudget.project(
                plan: plan,
                timeoutSource: .requested(nil),
                configuration: .init(postActionExpectationTimeoutBuffer: headroom)
            )) { error in
                guard let error = error as? TheFence.HeistExecutionBudget.Error,
                      case .invalidTransportHeadroom = error
                else {
                    return XCTFail("Expected invalid transport headroom, got \(error)")
                }
            }
        }
    }

    @ButtonHeistActor
    func testHeistBudgetRejectsTransportDeadlineOverflow() async throws {
        let plan = try HeistPlan(body: [
            .warn(WarnStep(message: "budget probe")),
        ])
        let timeout = try HeistTimeout(validatingSeconds: .greatestFiniteMagnitude)

        XCTAssertThrowsError(try TheFence.HeistExecutionBudget.project(
            plan: plan,
            timeoutSource: .requested(timeout),
            configuration: .init(postActionExpectationTimeoutBuffer: .greatestFiniteMagnitude)
        )) { error in
            guard let error = error as? TheFence.HeistExecutionBudget.Error,
                  case .transportTimeoutOverflow = error
            else {
                return XCTFail("Expected transport timeout overflow, got \(error)")
            }
        }
    }

    @ButtonHeistActor
    func testRunHeistRecordsResultArtifactWhenEnvironmentConfigured() async throws {
        try await withResultDirectory { directory in
            let previousDirectory = EnvironmentKey.buttonheistResultsDir.value
            let previousMode = EnvironmentKey.buttonheistResultsMode.value
            setEnvironment(EnvironmentKey.buttonheistResultsDir.rawValue, directory.path)
            setEnvironment(EnvironmentKey.buttonheistResultsMode.rawValue, HeistResultRecordingMode.all.rawValue)
            defer {
                setEnvironment(EnvironmentKey.buttonheistResultsDir.rawValue, previousDirectory)
                setEnvironment(EnvironmentKey.buttonheistResultsMode.rawValue, previousMode)
            }

            let (fence, mockConn) = makeConnectedFence()
            let scriptedResult = HeistResultFixture.result(steps: [
                HeistResultFixture.warning(message: "recorded result"),
            ])
            mockConn.responseScript = { _ in scriptedHeistResponse(scriptedResult) }
            fence.handoff.connect(to: TheFenceFixtures.testDevice)

            let response = try await fence.execute(command: .runHeist, values: [
                "plan": .string(Self.pureRuntimeHeistSource),
            ])

            guard case .heistExecution(_, let report) = response else {
                return XCTFail("Expected heistExecution response, got \(response)")
            }
            XCTAssertEqual(report, HeistReport.project(result: scriptedResult))
            let resultURL = try assertSingleResultArtifactURL(in: directory)
            XCTAssertEqual(try HeistResultCodec.decode(contentsOf: resultURL).result, scriptedResult)
        }
    }

    @ButtonHeistActor
    func testRunHeistRejectsNonHeistAndEmptyInput() async {
        let fence = TheFence(configuration: .init())
        // Standalone .json is internal to the package, and plan source is an
        // inline field rather than a local file path accepted by the fence.
        for path in ["Flow.txt", "Flow.json", "Flow.plan"] {
            XCTAssertThrowsError(try fence.decodeRunHeistRequest(
                TheFence.CommandArgumentEnvelope(values: ["path": .string(path)])
            )) { error in
                XCTAssertTrue(String(describing: error).contains("generated `.heist` package artifact"), "\(path): \(error)")
            }
        }
        // Empty path fails.
        XCTAssertThrowsError(try fence.decodeRunHeistRequest(
            TheFence.CommandArgumentEnvelope(values: ["path": .string("   ")])
        )) { error in
            XCTAssertTrue(String(describing: error).contains("path must not be empty"), "\(error)")
        }
    }

    @ButtonHeistActor
    func testRunHeistDecodesComposableInlinePlan() async throws {
        let fence = TheFence(configuration: .init())
        let item: HeistReferenceName = "item"
        // Nested definitions + invoke + a string parameter all round-trip.
        let definition = try HeistPlan(
            name: "addToCart",
            parameter: .string(name: "item"),
            body: [.action(ActionStep(command: .activate(.predicate(ElementPredicate(label: .exact(item))))))]
        )
        let plan = try HeistPlan(definitions: [definition], body: [
            .invoke(HeistInvocationStep(path: "addToCart", argument: .string("Milk"))),
        ])

        let request = try fence.decodeRunHeistRequest(try Self.planSourceArguments(for: plan))
        XCTAssertEqual(request.plan, plan)
    }

    @ButtonHeistActor
    func testRunHeistDecodesInlinePlanWithAccessibilityTargetParameter() async throws {
        let fence = TheFence(configuration: .init())
        let definition = try HeistPlan(
            name: "tapEach",
            parameter: .accessibilityTarget(name: "input"),
            body: [.action(ActionStep(command: .activate(.ref("input"))))]
        )
        let plan = try HeistPlan(
            definitions: [definition],
            body: [.warn(WarnStep(message: "namespace"))]
        )

        let request = try fence.decodeRunHeistRequest(try Self.planSourceArguments(for: plan))
        XCTAssertEqual(request.plan, plan)
    }

    @ButtonHeistActor
    func testRunHeistDecodesParameterizedRootWithStringArgument() async throws {
        let fence = TheFence(configuration: .init())
        let plan = try HeistPlan(
            name: "search",
            parameter: .string(name: "query"),
            body: [.action(ActionStep(command: .typeText(
                reference: "query",
                target: .predicate(.label("Search"))
            )))]
        )
        var arguments = try Self.planSourceArguments(for: plan).values
        arguments["argument"] = .object([
            "type": .string("string"),
            "value": .string("milk"),
        ])

        let request = try fence.decodeRunHeistRequest(TheFence.CommandArgumentEnvelope(values: arguments))

        XCTAssertEqual(request.plan, plan)
        XCTAssertEqual(request.argument, .string("milk"))
    }

    @ButtonHeistActor
    func testRunHeistRejectsMultipleStringRootArgumentValues() async throws {
        let fence = TheFence(configuration: .init())
        let plan = try HeistPlan(
            name: "search",
            parameter: .string(name: "query"),
            body: [.action(ActionStep(command: .typeText(
                reference: "query",
                target: .predicate(.label("Search"))
            )))]
        )
        var arguments = try Self.planSourceArguments(for: plan).values
        arguments["argument"] = .object([
            "type": .string("string"),
            "values": .array([.string("milk"), .string("eggs")]),
        ])

        XCTAssertThrowsError(try fence.decodeRunHeistRequest(TheFence.CommandArgumentEnvelope(values: arguments))) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Unknown heist argument field"), message)
            XCTAssertTrue(message.contains("values"), message)
        }
    }

    @ButtonHeistActor
    func testRunHeistDecodesParameterizedRootWithAccessibilityTargetArgument() async throws {
        let fence = TheFence(configuration: .init())
        let plan = try HeistPlan(
            name: "tapRow",
            parameter: .accessibilityTarget(name: "row"),
            body: [.action(ActionStep(command: .activate(.ref("row"))))]
        )
        var arguments = try Self.planSourceArguments(for: plan).values
        arguments["argument"] = .object([
            "type": .string("accessibility_target"),
            "target": targetValue(label: "Row 1"),
        ])

        let request = try fence.decodeRunHeistRequest(TheFence.CommandArgumentEnvelope(values: arguments))

        XCTAssertEqual(request.plan, plan)
        XCTAssertEqual(request.argument, .accessibilityTarget(.predicate(.label("Row 1"))))
    }

    @ButtonHeistActor
    func testRunHeistRejectsMissingRootArgumentForParameterizedRoot() async throws {
        let fence = TheFence(configuration: .init())
        let plan = try HeistPlan(
            name: "search",
            parameter: .string(name: "query"),
            body: [.action(ActionStep(command: .typeText(
                reference: "query",
                target: .predicate(.label("Search"))
            )))]
        )

        XCTAssertThrowsError(try fence.decodeRunHeistRequest(try Self.planSourceArguments(for: plan))) { error in
            XCTAssertTrue(String(describing: error).contains("run_heist argument does not match root heist parameter"))
        }
    }

    @ButtonHeistActor
    func testRunHeistRejectsRawJSONIRFieldsAsMissingCanonicalSource() async throws {
        let fence = TheFence(configuration: .init())
        XCTAssertThrowsError(try fence.decodeRunHeistRequest(
            TheFence.CommandArgumentEnvelope(values: [
                "version": .int(999),
                "body": .array([.object(["type": .string("warn"), "warn": .object(["message": .string("x")])])]),
            ])
        )) { error in
            XCTAssertTrue(String(describing: error).contains("requires exactly one plan source"), "\(error)")
            XCTAssertTrue(String(describing: error).contains("ButtonHeist DSL"), "\(error)")
            XCTAssertTrue(String(describing: error).contains(".heist"), "\(error)")
        }
        XCTAssertThrowsError(try fence.decodeRunHeistRequest(
            TheFence.CommandArgumentEnvelope(values: ["version": .int(1), "body": .array([])])
        )) { error in
            XCTAssertTrue(String(describing: error).contains("requires exactly one plan source"), "\(error)")
        }
    }

    @ButtonHeistActor
    func testRunHeistDescriptorRejectsRawJSONIRFieldsAndAcceptsCanonicalSource() async throws {
        // The descriptor must declare canonical ButtonHeist source but not raw
        // JSON IR fields. Structured JSON remains an internal codec, not the
        // public authoring surface.
        let fence = TheFence(configuration: .init())
        let definition = try HeistPlan(
            name: "addToCart",
            parameter: .string(name: "item"),
            body: [.warn(WarnStep(message: "x"))]
        )
        let plan = try HeistPlan(
            name: "flow",
            definitions: [definition],
            body: [.invoke(HeistInvocationStep(path: "addToCart", argument: .string("Milk")))]
        )
        XCTAssertThrowsError(try fence.parseRequest(command: .runHeist, arguments: try Self.inlineArguments(for: plan)))
        XCTAssertNoThrow(try fence.parseRequest(
            command: .runHeist,
            arguments: try Self.planSourceArguments(for: plan)
        ))
    }

    @ButtonHeistActor
    func testListHeistsReturnsCatalogFromValidatedInlinePlan() async throws {
        let fence = TheFence(configuration: .init())
        let item: HeistReferenceName = "item"
        let definition = try HeistPlan(
            name: "addToCart",
            parameter: .string(name: "item"),
            body: [.action(ActionStep(command: .activate(.predicate(ElementPredicate(label: .exact(item))))))]
        )
        let plan = try HeistPlan(
            name: "shop",
            definitions: [definition],
            body: [.warn(WarnStep(message: "ready"))]
        )

        let response = try await fence.execute(command: .listHeists, arguments: try Self.planSourceArguments(for: plan))

        guard case .heistCatalog(let descriptions, let detail) = response else {
            return XCTFail("Expected heistCatalog response, got \(response)")
        }
        XCTAssertEqual(detail, .summary)
        XCTAssertEqual(descriptions.map(\.identity.displayName), ["shop", "addToCart"])
        XCTAssertEqual(descriptions[1].parameterKind, .string)
        XCTAssertTrue(descriptions[1].requiresArgument)
        XCTAssertEqual(descriptions[1].parameterName, "item")
        XCTAssertEqual(descriptions[1].semanticSurface.actionCommands, [.activate])
    }

    @ButtonHeistActor
    func testListHeistsAcceptsCanonicalSourcePlan() async throws {
        let fence = TheFence(configuration: .init())
        let response = try await fence.execute(
            command: .listHeists,
            arguments: TheFence.CommandArgumentEnvelope(values: [
                "plan": .string("""
                HeistPlan("shop") {
                    HeistDef<String>("addToCart", parameter: "item") { item in
                        Activate(.label(item))
                    }

                    Warn("ready")
                }
                """),
            ])
        )

        guard case .heistCatalog(let descriptions, let detail) = response else {
            return XCTFail("Expected heistCatalog response, got \(response)")
        }
        XCTAssertEqual(detail, .summary)
        XCTAssertEqual(descriptions.map(\.identity.displayName), ["shop", "addToCart"])
        XCTAssertEqual(descriptions[1].parameterKind, .string)
        XCTAssertTrue(descriptions[1].requiresArgument)
    }

    @ButtonHeistActor
    func testDiscoveryCommandsUseSamePureRuntimeSourceAsRunHeist() async throws {
        let fence = TheFence(configuration: .init())
        let item: HeistReferenceName = "item"
        let sourceArguments = TheFence.CommandArgumentEnvelope(values: [
            "plan": .string(Self.pureRuntimeHeistSource),
            "detail": .string("detailed"),
        ])

        let listResponse = try await fence.execute(command: .listHeists, arguments: sourceArguments)
        guard case .heistCatalog(let descriptions, let detail) = listResponse else {
            return XCTFail("Expected heistCatalog response, got \(listResponse)")
        }
        XCTAssertEqual(detail, .detailed)
        XCTAssertEqual(descriptions.map(\.identity.displayName), ["agentFlow", "Cart", "Cart.addItem"])
        let addItem = try XCTUnwrap(descriptions.first { $0.identity.displayName == "Cart.addItem" })
        XCTAssertEqual(addItem.parameterKind, .string)
        XCTAssertEqual(addItem.semanticSurface.actionCommands, [.activate])

        let describeResponse = try await fence.execute(
            command: .describeHeist,
            arguments: TheFence.CommandArgumentEnvelope(values: [
                "plan": .string(Self.pureRuntimeHeistSource),
                "heist": .string("Cart.addItem"),
            ])
        )
        guard case .heistDescription(let description) = describeResponse else {
            return XCTFail("Expected heistDescription response, got \(describeResponse)")
        }
        XCTAssertEqual(description.identity.displayName, "Cart.addItem")
        XCTAssertEqual(description.parameterKind, .string)
        XCTAssertEqual(description.semanticSurface.actionCommands, [.activate])
        XCTAssertEqual(description.semanticSurface.targetPredicates, [.predicate(.label(item))])
    }

    @ButtonHeistActor
    func testRuntimeSourceRejectsNativeSwiftAtFenceBoundary() async {
        await assertValidationError(
            command: .runHeist,
            arguments: ["plan": .string(Self.nativeSwiftRuntimeSource)],
            contains: "let declarations are not supported inside ButtonHeist DSL bodies"
        )
        await assertValidationError(
            command: .listHeists,
            arguments: ["plan": .string(Self.nativeSwiftRuntimeSource)],
            contains: "let declarations are not supported inside ButtonHeist DSL bodies"
        )
        await assertValidationError(
            command: .describeHeist,
            arguments: [
                "heist": .string("agentFlow"),
                "plan": .string(Self.nativeSwiftRuntimeSource),
            ],
            contains: "let declarations are not supported inside ButtonHeist DSL bodies"
        )
    }

    @ButtonHeistActor
    func testListHeistsDetailedModeReturnsDerivedSafeFields() async throws {
        let fence = TheFence(configuration: .init())
        let definition = try HeistPlan(
            name: "checkout",
            definitions: [
                try HeistPlan(
                    name: "confirm",
                    body: [
                        .action(ActionStep(command: .activate(.predicate(.identifier("confirm_button"))))),
                    ]
                ),
            ],
            body: [
                .action(ActionStep(
                    command: .activate(.predicate(.label("Checkout"))),
                    expectationPolicy: .expect(ActionExpectation(predicate: .exists(.label("Done")), timeout: 1)))),
                .wait(WaitStep(predicate: .exists(.label("Receipt")), timeout: 1)),
                .invoke(HeistInvocationStep(path: "confirm")),
            ]
        )
        let plan = try HeistPlan(
            name: "shop",
            definitions: [definition],
            body: [.warn(WarnStep(message: "ready"))]
        )
        var arguments = try Self.planSourceArguments(for: plan).values
        arguments["detail"] = .string("detailed")

        let response = try await fence.execute(
            command: .listHeists,
            arguments: TheFence.CommandArgumentEnvelope(values: arguments)
        )

        guard case .heistCatalog(let descriptions, let detail) = response else {
            return XCTFail("Expected heistCatalog response, got \(response)")
        }
        XCTAssertEqual(detail, .detailed)
        let checkout = try XCTUnwrap(descriptions.first { $0.identity.displayName == "checkout" })
        XCTAssertEqual(checkout.semanticSurface.nestedRunHeists, [invocationPath("checkout.confirm")])
        XCTAssertEqual(checkout.semanticSurface.actionCommands, [.activate])
        XCTAssertEqual(checkout.semanticSurface.waits.count, 1)
        XCTAssertEqual(checkout.semanticSurface.expectations.count, 1)
        XCTAssertEqual(checkout.semanticSurface.semanticSurfaces, [
            .label(.exact("Checkout")),
            .label(.exact("Done")),
            .label(.exact("Receipt")),
            .identifier(.exact("confirm_button")),
        ])
    }

    @ButtonHeistActor
    func testListHeistsReturnsValidationFailureDiagnostics() async throws {
        let fence = TheFence(configuration: .init())

        let response = try await fence.execute(
            command: .listHeists,
            arguments: TheFence.CommandArgumentEnvelope(values: [
                "plan": .string("""
                HeistPlan("root") {
                    HeistDef<Void>("duplicate") {
                        Warn("one")
                    }

                    HeistDef<Void>("duplicate") {
                        Warn("two")
                    }

                    Warn("invalid")
                }
                """),
            ])
        )

        guard case .error(let failure) = response else {
            return XCTFail("Expected error response, got \(response)")
        }
        let message = failure.message
        XCTAssertTrue(message.contains("duplicate heist definition names"), message)
    }

    @ButtonHeistActor
    func testListHeistsRejectsUnknownDetailMode() async throws {
        let fence = TheFence(configuration: .init())
        let plan = try HeistPlan(
            name: "shop",
            body: [.warn(WarnStep(message: "ready"))]
        )
        var arguments = try Self.planSourceArguments(for: plan).values
        arguments["detail"] = .string("full")

        let response = try await fence.execute(
            command: .listHeists,
            arguments: TheFence.CommandArgumentEnvelope(values: arguments)
        )

        guard case .error(let failure) = response else {
            return XCTFail("Expected error response, got \(response)")
        }
        let message = failure.message
        XCTAssertTrue(message.contains("detail"), message)
        XCTAssertTrue(message.contains("summary"), message)
        XCTAssertTrue(message.contains("detailed"), message)
    }

    @ButtonHeistActor
    func testDescribeHeistReturnsSemanticSurfaceFromValidatedPlan() async throws {
        let fence = TheFence(configuration: .init())
        let definition = try HeistPlan(
            name: "checkout",
            body: [
                .action(ActionStep(
                    command: .activate(.predicate(.label("Checkout"))),
                    expectationPolicy: .expect(ActionExpectation(predicate: .exists(.label("Done")), timeout: 1)))),
            ]
        )
        let plan = try HeistPlan(
            name: "shop",
            definitions: [definition],
            body: [.warn(WarnStep(message: "ready"))]
        )
        var arguments = try Self.planSourceArguments(for: plan).values
        arguments["heist"] = .string("checkout")

        let response = try await fence.execute(
            command: .describeHeist,
            arguments: TheFence.CommandArgumentEnvelope(values: arguments)
        )

        guard case .heistDescription(let description) = response else {
            return XCTFail("Expected heistDescription response, got \(response)")
        }
        XCTAssertEqual(description.identity.displayName, "checkout")
        XCTAssertEqual(description.role, .capability)
        XCTAssertEqual(description.semanticSurface.actionCommands, [.activate])
        XCTAssertEqual(description.semanticSurface.expectations, [existsLabel("Done")])
        XCTAssertEqual(description.semanticSurface.targetPredicates, [
            .predicate(.label("Checkout")),
            .predicate(.label("Done")),
        ])
    }

    @ButtonHeistActor
    func testDescribeHeistAcceptsCanonicalSourcePlan() async throws {
        let fence = TheFence(configuration: .init())
        let response = try await fence.execute(
            command: .describeHeist,
            arguments: TheFence.CommandArgumentEnvelope(values: [
                "heist": .string("checkout"),
                "plan": .string("""
                HeistPlan("shop") {
                    HeistDef<Void>("checkout") {
                        Activate(.label("Checkout"))
                            .expect(.exists(.label("Done")), timeout: 1)
                    }

                    Warn("ready")
                }
                """),
            ])
        )

        guard case .heistDescription(let description) = response else {
            return XCTFail("Expected heistDescription response, got \(response)")
        }
        XCTAssertEqual(description.identity.displayName, "checkout")
        XCTAssertEqual(description.semanticSurface.actionCommands, [.activate])
        XCTAssertEqual(description.semanticSurface.targetPredicates, [
            .predicate(.label("Checkout")),
            .predicate(.label("Done")),
        ])
    }

    @ButtonHeistActor
    func testDescribeHeistMissingNameDiagnosticIncludesAvailableNames() async throws {
        let fence = TheFence(configuration: .init())
        let plan = try HeistPlan(
            name: "shop",
            definitions: [
                try HeistPlan(name: "openCart", body: [.warn(WarnStep(message: "open"))]),
            ],
            body: [.warn(WarnStep(message: "ready"))]
        )
        var arguments = try Self.planSourceArguments(for: plan).values
        arguments["heist"] = .string("checkout")

        let response = try await fence.execute(
            command: .describeHeist,
            arguments: TheFence.CommandArgumentEnvelope(values: arguments)
        )

        guard case .error(let failure) = response else {
            return XCTFail("Expected error response, got \(response)")
        }
        let message = failure.message
        XCTAssertTrue(message.contains(#"heist "checkout" was not found"#), message)
        XCTAssertTrue(message.contains("shop, openCart"), message)
    }

    func testHeistExecutionResponseFailureDerivesFromTypedResult() throws {
        let result = HeistResultFixture.result(
            steps: [HeistResultFixture.explicitFailure(message: "boom")],
            durationMs: 5
        )
        let response = FenceResponse.heistExecution(
            plan: try HeistPlan(body: [.warn(WarnStep(message: "x"))]),
            report: HeistReport.project(result: result)
        )
        XCTAssertTrue(response.isFailure)
        XCTAssertEqual(result.outcome, .failed(abortedAtPath: "$.body[0]"))
    }

}
