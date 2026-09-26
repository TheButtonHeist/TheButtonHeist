import ButtonHeistTestSupport
import XCTest
import Network
import ButtonHeistSupport
@_spi(ButtonHeistTooling) @testable import ButtonHeist
@_spi(ButtonHeistInternals) import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension TheFenceHandlerTests {
    // MARK: - Wait Validation

    @ButtonHeistActor
    func testWaitMissingPredicate() async {
        await assertValidationError(command: .wait, contains: "predicate")
    }

    @ButtonHeistActor
    func testWaitPredicateShapesPassValidation() async {
        let cases: [[String: HeistValue]] = [
            ["predicate": .object([
                "type": .string("exists"),
                "target": elementPredicateValue(label: "Loading"),
            ])],
            [
                "predicate": .object([
                    "type": .string("missing"),
                    "target": elementPredicateValue(label: "Loading"),
                ]),
                "timeout": .double(5),
            ],
            ["predicate": .object([
                "type": .string("notification"),
            ])],
            ["predicate": .object([
                "type": .string("notification"),
                "text": stringMatchValue(mode: "contains", value: "Payment complete"),
                "element": elementPredicateValue(label: "Receipt"),
            ])],
            ["predicate": .object([
                "type": .string("changed"),
                "scope": .string("screen"),
            ])],
            ["predicate": .object([
                "type": .string("changed"),
                "scope": .string("screen"),
                "match": stringMatchValue(mode: "exact", value: "Receipt"),
            ])],
            [
                "predicate": .object([
                    "type": .string("changed"),
                    "scope": .string("elements"),
                    "assertions": .array([]),
                ]),
                "timeout": .double(5),
            ],
        ]

        for arguments in cases {
            await assertPassesValidation(command: .wait, arguments: arguments)
        }
    }

    @ButtonHeistActor
    func testWaitSendsDefaultTimeoutWhenOmitted() async {
        let (fence, mockConn) = makeConnectedFence()
        _ = try? await fence.execute(command: .wait, values: [
            "predicate": .object([
                "type": .string("changed"),
                "scope": .string("screen"),
            ]),
        ])
        guard let step = mockConn.sent.sentWaitSteps.last else {
            return XCTFail("Expected wait step")
        }
        XCTAssertEqual(step.predicate, .screenChanged)
        XCTAssertEqual(step.timeout, defaultWaitTimeout)
    }

    @ButtonHeistActor
    func testDirectWaitReturnsHeistExecutionBeforeFormatting() async throws {
        let (fence, mockConn) = makeConnectedFence()
        let scriptedResult = HeistResultFixture.result(steps: [HeistResultFixture.wait()])
        mockConn.responseScript = { _ in scriptedHeistResponse(scriptedResult) }

        let response = try await fence.execute(command: .wait, values: [
            "predicate": .object([
                "type": .string("changed"),
                "scope": .string("elements"),
                "assertions": .array([]),
            ]),
        ])

        assertDirectCommandHeistExecution(response, command: .wait, stepKind: .wait)
        let json = try publicJSONProbe(response).object()
        try json.assertMissing("method")
        try json.assertPresent("report")
    }

    @ButtonHeistActor
    func testInvalidExpectationIsRejectedBeforeDispatch() async throws {
        let (fence, mockConn) = makeConnectedFence()

        let response = try await fence.execute(command: .activate, values: [
            "target": targetValue(identifier: "myElement"),
            "expect": .string("change"),
        ])

        guard case .error(let failure) = response else {
            return XCTFail("Expected .error response, got \(response)")
        }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertTrue(mockConn.sent.isEmpty)
    }

    @ButtonHeistActor
    func testActionExpectationIsSentAsServerSideExpectationStep() async throws {
        let (fence, mockConn) = makeConnectedFence()
        let predicate = AccessibilityPredicate.exists(.label("Home"))

        _ = try await fence.execute(command: .activate, values: [
            "target": targetValue(identifier: "myElement"),
            "expect": .object([
                "type": .string("exists"),
                "target": elementPredicateValue(label: "Home"),
            ]),
        ])

        // The action and its expectation cross the wire as one heist plan; the
        // expectation is a server-side step on the action, not a separate
        // client-issued wait round-trip.
        XCTAssertEqual(mockConn.sent.count, 1)
        guard case .action(let step)? = mockConn.sent.sentHeistPlan?.body.first else {
            return XCTFail("Expected a single action step, got \(String(describing: mockConn.sent.sentHeistPlan))")
        }
        XCTAssertEqual(step.expectationPolicy.expectedExpectation?.predicate, predicate)
        XCTAssertEqual(step.expectationPolicy.expectedExpectation?.timeout, .sessionDefault)
    }

    @ButtonHeistActor
    func testDirectActionExpectationUsesSessionScreenTransitionTimeout() async throws {
        let policy = ActionExpectationTimeoutPolicy(standard: 3, screenTransition: 12)
        let (fence, mockConn) = makeConnectedFence(configuration: .init(
            actionExpectationTimeoutPolicy: policy
        ))

        _ = try await fence.execute(command: .activate, values: [
            "target": targetValue(identifier: "myElement"),
            "expect": .object([
                "type": .string("changed"),
                "scope": .string("screen"),
            ]),
        ])

        guard case .action(let step)? = mockConn.sent.sentHeistPlan?.body.first else {
            return XCTFail("Expected a single action step")
        }
        XCTAssertEqual(step.expectationPolicy.expectedExpectation?.timeout, .sessionDefault)
        XCTAssertEqual(mockConn.sent.sentHeistRun?.actionExpectationTimeoutPolicy, policy)
    }

    // MARK: - Expectation Parsing

    @ButtonHeistActor
    func testParseExpectationNilWhenAbsent() async throws {
        let result = try parseTypedExpectation(nil)
        XCTAssertNil(result)
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
            XCTAssertTrue(String(describing: error).contains("scope"), "Unexpected error: \(error)")
        }
    }

    func testNormalizeToolCallRoutesWithoutParsingRequestArguments() throws {
        let result = TheFence.Command.routeToolCall(named: "perform")

        guard case .success(let command) = result else {
            return XCTFail("Expected successful command, got \(result)")
        }

        XCTAssertEqual(command, .perform)
    }

    func testNormalizeToolCallRejectsNonMCPCommands() {
        for tool in ["activate", "type_text", "wait", "swipe", "scroll", "help"] {
            let result = TheFence.Command.routeToolCall(named: tool)

            guard case .failure(let error) = result else {
                return XCTFail("Expected non-MCP command rejection, got \(result)")
            }

            XCTAssertEqual(error.message, "Unknown tool: \(tool)")
        }
    }

    // MARK: - Parse Expectation: Discriminator Wire Shape

    @ButtonHeistActor
    func testParseExpectationDiscriminatorElementUpdatedFull() async throws {
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
        XCTAssertEqual(
            result,
            .elementsChanged([
                .updated(.identifier("slider"), .value(before: "0", after: "50")),
            ])
        )
    }

    @ButtonHeistActor
    func testParseExpectationDiscriminatorElementUpdatedInvalidPropertyListsValidValues() async {
        XCTAssertThrowsError(try parseTypedExpectation(.object([
            "type": .string("changed"),
            "scope": .string("elements"),
            "assertions": .array([.object([
                "type": .string("updated"),
                "target": elementPredicateValue(identifier: "slider"),
                "property": .string("bogus"),
            ])]),
        ]))) { error in
            guard case FenceError.invalidRequest(let msg) = error else {
                XCTFail("Expected FenceError.invalidRequest, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("ElementProperty"), msg)
            XCTAssertTrue(msg.contains("bogus"), msg)
        }
    }

    @ButtonHeistActor
    func testParseExpectationDiscriminatorElementUpdatedRequiresTargetAndProperty() async {
        XCTAssertThrowsError(try parseTypedExpectation(.object([
            "type": .string("changed"),
            "scope": .string("elements"),
            "assertions": .array([.object(["type": .string("updated")])]),
        ])))
    }

    @ButtonHeistActor
    func testParseExpectationDiscriminatorPresentWithElement() async throws {
        let result = try parseTypedExpectation(.object([
            "type": .string("exists"),
            "target": elementPredicateValue(label: "Cart", identifier: "cart.button"),
        ]))
        XCTAssertEqual(
            result,
            .exists(.predicate(ElementPredicate(label: "Cart", identifier: "cart.button")))
        )
    }

    @ButtonHeistActor
    func testParseExpectationAcceptsContainerTarget() async throws {
        let result = try parseTypedExpectation(.object([
            "type": .string("exists"),
            "target": .object([
                "container": .object([
                    "checks": .array([.object([
                        "kind": .string("scrollable"),
                        "value": .bool(true),
                    ])]),
                ]),
            ]),
        ]))

        XCTAssertEqual(result, .exists(.container(.matching(.scrollable(true)))))
    }

    @ButtonHeistActor
    func testParseExpectationPreservesTargetRefsForExecutionResolution() async throws {
        let item: HeistReferenceName = "item"
        let result = try parseTypedExpectation(.object([
            "type": .string("exists"),
            "target": .object(["ref": .string("item")]),
        ]))

        XCTAssertEqual(result, .exists(.ref(item)))
    }

    @ButtonHeistActor
    func testParseExpectationTypedPayloadPreservesTargetTraits() async throws {
        let result = try parseTypedExpectation(.object([
            "type": .string("missing"),
            "target": accessibilityTargetValue([
                "checks": .array([
                    predicateCheckValue(kind: "label", match: stringMatchValue(mode: "exact", value: "Spinner")),
                    predicateCheckValue(kind: "traits", values: [.string("button")]),
                    predicateCheckValue(
                        kind: "exclude",
                        check: predicateCheckValue(kind: "traits", values: [.string("selected")])
                    ),
                ]),
            ]),
        ]))

        XCTAssertEqual(
            result,
            .missing(.element(
                .label("Spinner"),
                .traits([.button]),
                .exclude(.traits([.selected]))
            ))
        )
    }

    @ButtonHeistActor
    func testParseExpectationAcceptsNotificationWithOptionalCanonicalFields() async throws {
        let cases: [(value: HeistValue, expected: AccessibilityPredicate)] = [
            (.object(["type": .string("notification")]), .notification),
            (
                .object([
                    "type": .string("notification"),
                    "text": stringMatchValue(mode: "contains", value: "Payment complete"),
                    "element": elementPredicateValue(label: "Receipt"),
                ]),
                .notification(
                    text: .contains("Payment complete"),
                    element: ElementPredicate(label: "Receipt")
                )
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(try parseTypedExpectation(testCase.value), testCase.expected)
        }
    }

    /// `elements` is the only scope with an assertion list, so it is the only
    /// place a notification can be smuggled in as an assertion. A screen
    /// predicate asks about the screen and reads no list at all.
    @ButtonHeistActor
    func testParseExpectationRejectsNotificationInElementsAssertionContext() async {
        XCTAssertThrowsError(try parseTypedExpectation(.object([
            "type": .string("changed"),
            "scope": .string("elements"),
            "assertions": .array([.object([
                "type": .string("notification"),
            ])]),
        ]))) { error in
            XCTAssertTrue(
                String(describing: error).contains("elements assertion"),
                "Unexpected error: \(error)"
            )
        }
    }

    @ButtonHeistActor
    func testCanonicalExpectationDecoderRejectsUnknownTargetFields() async {
        XCTAssertThrowsError(try parseTypedExpectation(.object([
            "type": .string("exists"),
            "target": .object([
                "checks": .array([
                    predicateCheckValue(kind: "label", match: stringMatchValue(mode: "exact", value: "Done")),
                ]),
                "unknown": .string("ignored before"),
            ]),
        ])))
    }

}
