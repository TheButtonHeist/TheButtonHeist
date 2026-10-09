import ButtonHeistTestSupport
import XCTest
import Network
import ButtonHeistSupport
@_spi(ButtonHeistTooling) @testable import ButtonHeist
@_spi(ButtonHeistInternals) import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension TheFenceHandlerTests {
    // MARK: - Scroll Action Validation

    @ButtonHeistActor
    func testScrollPayloadsPassValidation() async {
        let target = targetValue(identifier: "scrollView")
        let cases: [(TheFence.Command, [String: HeistValue])] = [
            (.scroll, ["target": target]),
            (.scroll, ["direction": .string("down")]),
            (.scroll, ["direction": .string("down"), "target": target]),
            (.scroll, ["direction": .string("down"), "containerName": .string("main_scroll")]),
            (.scroll, [:]),
            (.scrollToVisible, ["target": targetValue(identifier: "targetElement")]),
            (.scrollToEdge, ["edge": .string("bottom"), "containerName": .string("main_scroll")]),
            (.scrollToEdge, ["target": target]),
            (.scrollToEdge, ["edge": .string("bottom")]),
            (.scrollToEdge, ["edge": .string("bottom"), "target": target]),
        ]

        for (command, arguments) in cases {
            await assertPassesValidation(command: command, arguments: arguments)
        }
    }

    @ButtonHeistActor
    func testInvalidScrollEnumsAreRejected() async {
        let cases: [(TheFence.Command, [String: HeistValue], String)] = [
            (
                .scroll,
                ["target": targetValue(identifier: "scrollView"), "direction": .string("diagonal")],
                "schema validation failed for direction: observed string \"diagonal\"; expected enum one of up, down, left, right"
            ),
            (
                .scrollToEdge,
                ["target": targetValue(identifier: "scrollView"), "edge": .string("middle")],
                "schema validation failed for edge: observed string \"middle\"; expected enum one of top, bottom, left, right"
            ),
        ]

        for (command, arguments, message) in cases {
            await assertValidationError(command: command, arguments: arguments, equals: message)
        }
    }

    @ButtonHeistActor
    func testLegacyScrollContainerPayloadsAreRejected() async {
        let cases: [(TheFence.Command, [String: HeistValue])] = [
            (.scroll, ["container": .object(["unexpected": .string("main_scroll")])]),
            (.scroll, ["container": .string("main_scroll")]),
            (.scrollToEdge, ["edge": .string("bottom"), "container": .string("main_scroll")]),
        ]

        for (command, arguments) in cases {
            await assertValidationError(
                command: command,
                arguments: arguments,
                contains: "schema validation failed for container"
            )
        }
    }

    @ButtonHeistActor
    func testElementCommandsReportMissingTargetContracts() async {
        let cases: [(TheFence.Command, [String: HeistValue])] = [
            (.scrollToVisible, [:]),
            (.activate, [:]),
            (.rotor, ["rotor": .string("Errors")]),
        ]

        for (command, arguments) in cases {
            await assertValidationFailure(
                command: command,
                arguments: arguments
            ) { failure in
                let expectedMessages = [
                    "\(command.rawValue) request contract failed: missing target",
                    "requires target object",
                    "Next: get_interface()",
                ]
                XCTAssertTrue(expectedMessages.allSatisfy(failure.message.contains))
                XCTAssertEqual(failure.details.code, .requestMissingTarget)
                XCTAssertEqual(failure.details.phase, .request)
                XCTAssertEqual(failure.details.retryable, false)
                XCTAssertEqual(failure.details.hint, "get_interface()")
            }
        }
    }

    // MARK: - Accessibility Action Validation

    @ButtonHeistActor
    func testInvalidRotorAndActivateEnumsAreRejected() async {
        let target = targetValue(identifier: "myElement")
        let cases: [(TheFence.Command, [String: HeistValue], String)] = [
            (
                .rotor,
                ["target": target, "rotorIndex": .int(-1)],
                "schema validation failed for rotorIndex: observed integer -1; expected integer >= 0"
            ),
            (
                .rotor,
                ["target": target, "direction": .string("sideways")],
                "schema validation failed for direction: observed string \"sideways\"; expected enum one of next, previous"
            ),
            (
                .activate,
                ["target": target, "action": .string("")],
                "schema validation failed for action: observed string \"\"; expected non-empty string"
            ),
        ]

        for (command, arguments, message) in cases {
            await assertValidationError(command: command, arguments: arguments, equals: message)
        }
    }

    @ButtonHeistActor
    func testMalformedPredicatesUseFieldQualifiedValidationFailures() async {
        let invalidPredicate: HeistValue = .object([
            "type": .string("eventually"),
        ])
        let cases: [(TheFence.Command, [String: HeistValue], String)] = [
            (
                .wait,
                ["predicate": invalidPredicate],
                "predicate.type"
            ),
            (
                .activate,
                ["target": targetValue(identifier: "myElement"), "expect": invalidPredicate],
                "expect.type"
            ),
        ]

        for (command, arguments, field) in cases {
            await assertValidationFailure(command: command, arguments: arguments) { failure in
                XCTAssertEqual(failure.details.code, .requestValidationError)
                XCTAssertTrue(failure.message.contains("schema validation failed for \(field)"))
                XCTAssertTrue(failure.message.contains("Predicate type \"eventually\" is not valid"))
            }
        }
    }

    @ButtonHeistActor
    func testMixedAndLegacyRotorSelectorsAreRejected() async {
        let target = targetValue(identifier: "myElement")
        let cases: [([String: HeistValue], String)] = [
            (
                ["target": target, "rotor": .string("Errors"), "rotorIndex": .int(1)],
                "either rotor or rotorIndex"
            ),
            (
                ["target": target, "currentTextStartOffset": .int(4)],
                "schema validation failed for currentTextStartOffset:"
            ),
        ]

        for (arguments, message) in cases {
            await assertValidationError(command: .rotor, arguments: arguments, contains: message)
        }
    }

    @ButtonHeistActor
    func testActivateActionIncrementDispatchesSingleIncrementStep() async throws {
        let (fence, mockConn) = makeConnectedFence()

        let response = try await fence.execute(command: .activate, values: [
            "target": targetValue(identifier: "myElement"),
            "action": .string("increment"),
        ])

        XCTAssertTrue(response.containsAction, "Expected single-step action response, got \(response)")
        let commands = mockConn.sent.sentHeistActionCommands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.wireType, .increment)
    }

    @ButtonHeistActor
    func testDirectActivateReturnsHeistExecutionBeforeFormatting() async throws {
        let (fence, _) = makeConnectedFence()

        let response = try await fence.execute(command: .activate, values: [
            "target": targetValue(identifier: "myElement"),
        ])

        assertDirectCommandHeistExecution(response, command: .activate, stepKind: .action)
        let json = try publicJSONProbe(response).object()
        try json.assertMissing("method")
        try json.assertPresent("report")
        assertCompactHeistSummary(response, stepLine: "  [0] activate ✓")
    }

    // MARK: - Text Input Validation

    @ButtonHeistActor
    func testRequiredTextAndEditFieldsAreValidated() async {
        let cases: [(TheFence.Command, [String: HeistValue], String)] = [
            (.typeText, [:], "schema validation failed for text: observed missing; expected string"),
            (
                .typeText,
                ["text": .string("")],
                "schema validation failed for text: observed string \"\"; expected non-empty string"
            ),
            (
                .editAction,
                [:],
                "schema validation failed for action: observed missing; expected enum one of copy, paste, cut, select, selectAll, delete"
            ),
            (.setPasteboard, [:], "schema validation failed for text: observed missing; expected string"),
        ]

        for (command, arguments, message) in cases {
            await assertValidationError(command: command, arguments: arguments, equals: message)
        }
    }

    @ButtonHeistActor
    func testTypeTextWithTextPassesValidation() async {
        await assertPassesValidation(
            command: .typeText,
            arguments: ["text": .string("hello")]
        )
    }

    @ButtonHeistActor
    func testTypeTextTypedPayloadDispatchesCanonicalWireMessage() async throws {
        let (fence, mockConn) = makeConnectedFence()

        let response = try await fence.execute(command: .typeText, values: [
            "text": .string("hello"),
            "target": targetValue(identifier: "search_field"),
        ])

        XCTAssertTrue(response.containsAction, "Expected single-step action response, got \(response)")
        guard let message = mockConn.sent.sentPlanMessages.last,
              case .typeText(let payload) = message.payload else {
            return XCTFail("Expected typeText message, got \(String(describing: mockConn.sent.sentPlanMessages.last))")
        }
        XCTAssertEqual(payload.text, "hello")
        XCTAssertEqual(payload.target, .predicate(.identifier("search_field")))
        XCTAssertEqual(payload.text.mode, .append)
    }

    @ButtonHeistActor
    func testTypeTextReplacingExistingTypedPayloadDispatchesCanonicalWireMessage() async throws {
        let (fence, mockConn) = makeConnectedFence()

        let response = try await fence.execute(command: .typeText, values: [
            "text": .string(""),
            "target": targetValue(identifier: "search_field"),
            "mode": .string("replace"),
        ])

        XCTAssertTrue(response.containsAction, "Expected single-step action response, got \(response)")
        guard let message = mockConn.sent.sentPlanMessages.last,
              case .typeText(let payload) = message.payload else {
            return XCTFail("Expected typeText message, got \(String(describing: mockConn.sent.sentPlanMessages.last))")
        }
        XCTAssertEqual(payload.text, .replacing(""))
        XCTAssertEqual(payload.target, .predicate(.identifier("search_field")))
    }

    @ButtonHeistActor
    func testInvalidTextPayloadsAreRejectedBeforeDispatch() async throws {
        let cases: [(TheFence.Command, [String: HeistValue], String)] = [
            (
                .typeText,
                ["text": .int(3)],
                "schema validation failed for text: observed integer 3; expected string"
            ),
            (
                .setPasteboard,
                ["text": .string("")],
                "schema validation failed for text: observed string \"\"; expected non-empty string"
            ),
        ]

        for (command, arguments, message) in cases {
            let (fence, connection) = makeConnectedFence()
            let response = try await fence.execute(command: command, values: arguments)

            guard case .error(let failure) = response else {
                XCTFail("Expected error response, got \(response)")
                continue
            }
            XCTAssertEqual(failure.message, message)
            XCTAssertTrue(connection.sent.isEmpty)
        }
    }

    @ButtonHeistActor
    func testEditActionValuesPassValidation() async {
        for action in ["copy", "delete"] {
            await assertPassesValidation(
                command: .editAction,
                arguments: ["action": .string(action)]
            )
        }
    }

}

extension TheFenceHandlerTests {

    // MARK: - Target and Gesture Admission
    @ButtonHeistActor
    func testAccessibilityTargetPayloadShapesDecodeCanonically() async throws {
        let publicExpected = AccessibilityTarget.predicate(
            ElementPredicate(label: "Save", identifier: "saveButton", traits: [.button]),
            ordinal: 1
        )
        let jsonMCPShape = accessibilityTargetValue([
            "checks": .array([
                predicateCheckValue(kind: "label", match: stringMatchValue(mode: "exact", value: "Save")),
                predicateCheckValue(kind: "identifier", match: stringMatchValue(mode: "exact", value: "saveButton")),
                predicateCheckValue(kind: "traits", values: [.string("button")]),
            ]),
            "ordinal": .int(1),
        ])
        let containerShape = accessibilityTargetValue([
            "container": .object([
                "checks": .array([.object([
                    "kind": .string("scrollable"),
                    "value": .bool(true),
                ])]),
            ]),
        ])
        let cases: [(String, HeistValue?, AccessibilityTarget?)] = [
            (
                "identifier",
                targetValue(identifier: "myButton"),
                .predicate(ElementPredicate(identifier: "myButton"))
            ),
            (
                "matcher fields",
                targetValue(label: "Save", traits: ["button"]),
                .predicate(ElementPredicate(label: "Save", traits: [.button]))
            ),
            (
                "CLI public shape",
                targetValue(label: "Save", identifier: "saveButton", traits: ["button"], ordinal: 1),
                publicExpected
            ),
            ("JSON/MCP public shape", jsonMCPShape, publicExpected),
            (
                "ordinal",
                targetValue(label: "Save", ordinal: 2),
                .predicate(ElementPredicate(label: "Save"), ordinal: 2)
            ),
            (
                "no ordinal",
                targetValue(label: "Save"),
                .predicate(ElementPredicate(label: "Save"))
            ),
            ("missing", nil, nil),
            ("container", containerShape, .container(.matching(.scrollable(true)))),
        ]

        for (name, value, expected) in cases {
            XCTAssertEqual(try decodedAccessibilityTarget(target: value), expected, name)
        }
    }

    @ButtonHeistActor
    func testAccessibilityTargetRejectsHeistIdField() async throws {
        // heistId is no longer a targeting field — it is rejected as unknown.
        XCTAssertThrowsError(try decodedAccessibilityTarget(target: legacyHeistIdTargetValue("button_save")))
    }

    @ButtonHeistActor
    func testAccessibilityTargetRejectsRemovedContainerPredicateShapes() async {
        let exactOrders = stringMatchValue(mode: "exact", value: "orders")
        let removedShapes = [
            accessibilityTargetValue([
                "container": .object(["identifier": .string("orders")]),
            ]),
            accessibilityTargetValue([
                "container": .object([
                    "checks": .array([
                        .object([
                            "kind": .string("identifier"),
                            "match": exactOrders,
                            "semantic": .object([
                                "kind": .string("label"),
                                "match": exactOrders,
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ]

        for target in removedShapes {
            XCTAssertThrowsError(try decodedAccessibilityTarget(target: target))
        }
    }

    @ButtonHeistActor
    func testAccessibilityTargetRejectsUnknownTargetField() async throws {
        XCTAssertThrowsError(
            try decodedAccessibilityTarget(
                target: accessibilityTargetValue([
                    "checks": .array([
                        predicateCheckValue(kind: "label", match: stringMatchValue(mode: "exact", value: "Save")),
                    ]),
                    "unexpectedTargetField": .string("button_save"),
                ])
            )
        ) { error in
            XCTAssertTrue(
                "\(error)".contains("unexpectedTargetField"),
                "Expected unknown target field rejection, got \(error)"
            )
        }
    }

    @ButtonHeistActor
    func testRequestTargetRejectsNegativeOrdinal() async {
        await assertValidationError(
            command: .activate,
            arguments: ["target": targetValue(label: "Save", ordinal: -1)],
            equals: "schema validation failed for target.ordinal: observed integer -1; expected ordinal must be non-negative, got -1"
        )
    }

    @ButtonHeistActor
    func testElementOnlyCommandRejectsContainerTargetWithTypedError() async {
        let arguments = TheFence.CommandArgumentEnvelope(values: [
            "target": .object([
                "container": .object([
                    "checks": .array([.object([
                        "kind": .string("scrollable"),
                        "value": .bool(true),
                    ])]),
                ]),
            ]),
        ])

        XCTAssertThrowsError(try arguments.requiredAccessibilityTarget(command: .activate)) { error in
            XCTAssertEqual(error as? TheFence.ContainerTargetRequiresElement, .init(command: .activate))
        }
    }

    @ButtonHeistActor
    func testDirectCommandResolvesTargetRefsAtRuntimeBoundary() async {
        let arguments = TheFence.CommandArgumentEnvelope(values: [
            "target": .object(["ref": .string("item")]),
        ])

        XCTAssertThrowsError(try arguments.requiredAccessibilityTarget(command: .activate)) { error in
            XCTAssertEqual(error as? HeistExpressionError, .unresolvedTargetReference("item"))
        }
    }

    // MARK: - Schema Validation Diagnostics

    @ButtonHeistActor
    func testSchemaValidationReportsBadCoercedValue() async {
        await assertValidationError(
            command: .wait,
            arguments: [
                "predicate": .object([
                    "type": .string("changed"),
                    "scope": .string("elements"),
                    "assertions": .array([]),
                ]),
                "timeout": .string("forever"),
            ],
            equals: "schema validation failed for timeout: observed string \"forever\"; expected number"
        )
    }

    // MARK: - Gesture Validation

    @ButtonHeistActor
    func testTapAndLongPressValidPayloadsPassValidation() async {
        let cases: [(TheFence.Command, [String: HeistValue])] = [
            (.oneFingerTap, ["point": .object(["x": .double(100), "y": .double(200)])]),
            (.oneFingerTap, ["element": targetValue(identifier: "myButton")]),
            (.longPress, ["point": .object(["x": .double(50), "y": .double(50)])]),
        ]

        for (command, arguments) in cases {
            await assertPassesValidation(command: command, arguments: arguments)
        }
    }

    @ButtonHeistActor
    func testTapAndLongPressMissingTargetsAreRejected() async {
        for command in [TheFence.Command.oneFingerTap, .longPress] {
            await assertValidationError(
                command: command,
                contains: "point requires element, element with unitPoint, or ScreenPoint"
            )
        }
    }

    @ButtonHeistActor
    func testTapAndLongPressInvalidPayloadsAreRejected() async {
        let cases: [(TheFence.Command, [String: HeistValue], String)] = [
            (
                .oneFingerTap,
                ["point": .object(["x": .double(100)])],
                "schema validation failed for point.y: observed missing; expected number"
            ),
            (
                .oneFingerTap,
                [
                    "element": targetValue(identifier: "myButton"),
                    "unitPoint": .object(["x": .double(1.2), "y": .double(0.5)]),
                ],
                "schema validation failed for unitPoint.x: observed number 1.2; expected number in 0...1"
            ),
            (
                .oneFingerTap,
                ["point": .object(["x": .double(Double.nan), "y": .double(200)])],
                "schema validation failed for point.x: observed number nan; expected number"
            ),
            (
                .oneFingerTap,
                ["point": .object(["x": .double(Double.infinity), "y": .double(200)])],
                "schema validation failed for point.x: observed number inf; expected number"
            ),
            (
                .longPress,
                [
                    "point": .object(["x": .double(50), "y": .double(50)]),
                    "duration": .double(-1),
                ],
                "schema validation failed for duration: observed number -1.0; expected number > 0"
            ),
            (
                .longPress,
                [
                    "point": .object(["x": .double(50), "y": .double(50)]),
                    "duration": .double(61),
                ],
                "schema validation failed for duration: observed number 61.0; expected number in 0...60.0"
            ),
        ]

        for (command, arguments, message) in cases {
            await assertValidationError(command: command, arguments: arguments, equals: message)
        }
    }

    @ButtonHeistActor
    func testDirectTapReturnsHeistExecutionBeforeFormatting() async throws {
        let (fence, mockConn) = makeConnectedFence()
        let point = ScreenPoint(x: 12, y: 34)
        let scriptedResult = HeistResultFixture.result(steps: [
            HeistResultFixture.action(
                command: .oneFingerTap(TapTarget(selection: .coordinate(point))),
                result: HeistResultFixture.actionResult(payload: .oneFingerTap)
            ),
        ])
        mockConn.responseScript = { _ in scriptedHeistResponse(scriptedResult) }

        let response = try await fence.execute(command: .oneFingerTap, values: [
            "point": .object(["x": .double(12), "y": .double(34)]),
        ])

        assertDirectCommandHeistExecution(
            response,
            command: .oneFingerTap,
            stepKind: .action,
            reportCommandName: "oneFingerTap"
        )
        assertCompactHeistSummary(response, stepLine: "  [0] oneFingerTap ✓")
    }

    @ButtonHeistActor
    func testGestureTargetRejectsHeistId() async {
        await assertValidationError(
            command: .oneFingerTap,
            arguments: [
                "element": accessibilityTargetValue([
                    "heistId": .string("button_save"),
                ]),
            ],
            contains: "Unknown accessibility target field \"heistId\""
        )
    }

    @ButtonHeistActor
    func testSwipeAndDragValidPayloadsPassValidation() async {
        let cases: [(TheFence.Command, [String: HeistValue])] = [
            (
                .swipe,
                ["elementUnitPoints": .object([
                    "element": targetValue(identifier: "row_5"),
                    "start": .object(["x": .double(0.8), "y": .double(0.5)]),
                    "end": .object(["x": .double(0.2), "y": .double(0.5)]),
                ])]
            ),
            (
                .drag,
                ["elementToPoint": .object([
                    "element": targetValue(identifier: "source"),
                    "end": .object(["x": .double(100), "y": .double(200)]),
                ])]
            ),
        ]

        for (command, arguments) in cases {
            await assertPassesValidation(command: command, arguments: arguments)
        }
    }

    @ButtonHeistActor
    func testSwipeAndDragInvalidPayloadsAreRejected() async {
        let point = HeistValue.object(["x": .double(10), "y": .double(20)])
        let dragStart = HeistValue.object(["x": .double(10), "y": .double(10)])
        let end = HeistValue.object(["x": .double(100), "y": .double(200)])
        let swipeEnd = HeistValue.object(["x": .double(30), "y": .double(40)])
        let cases: [(TheFence.Command, [String: HeistValue], String)] = [
            (
                .swipe,
                ["pointDirection": .object(["start": point, "direction": .string("diagonal")])],
                "schema validation failed for pointDirection.direction: observed string \"diagonal\"; " +
                    "expected enum one of up, down, left, right"
            ),
            (
                .swipe,
                ["pointDirection": .object(["direction": .string("up")])],
                "schema validation failed for pointDirection.start: observed missing; expected object"
            ),
            (
                .swipe,
                ["pointToPoint": .object([
                    "start": .object(["x": .double(10)]),
                    "end": end,
                ])],
                "schema validation failed for pointToPoint.start.y: observed missing; expected number"
            ),
            (
                .swipe,
                ["elementUnitPoints": .object([
                    "element": targetValue(identifier: "row_5"),
                    "start": .object(["x": .double(1.2), "y": .double(0.5)]),
                    "end": .object(["x": .double(0.2), "y": .double(0.5)]),
                ])],
                "schema validation failed for elementUnitPoints.start.x: observed number 1.2; expected number in 0...1"
            ),
            (
                .swipe,
                [
                    "pointDirection": .object(["start": point, "direction": .string("down")]),
                    "pointToPoint": .object(["start": point, "end": swipeEnd]),
                ],
                "swipe accepts exactly one gesture intent"
            ),
            (
                .drag,
                ["pointToPoint": .object(["start": dragStart])],
                "schema validation failed for pointToPoint.end: observed missing; expected object"
            ),
            (
                .drag,
                ["pointToPoint": .object(["end": end])],
                "schema validation failed for pointToPoint.start: observed missing; expected object"
            ),
            (
                .drag,
                [
                    "elementToPoint": .object([
                        "element": targetValue(identifier: "source"),
                        "end": end,
                    ]),
                    "pointToPoint": .object(["start": point, "end": end]),
                ],
                "drag accepts exactly one gesture intent"
            ),
        ]

        for (command, arguments, message) in cases {
            await assertValidationError(command: command, arguments: arguments, equals: message)
        }
    }

    @ButtonHeistActor
    func testSwipeDirectionWithElementDispatchesElementDirectionPayload() async {
        let (fence, mockConn) = makeConnectedFence()
        _ = try? await fence.execute(command: .swipe, values: [
            "elementDirection": .object([
                "element": targetValue(identifier: "row_5"),
                "direction": .string("left"),
            ]),
        ])
        guard let message = mockConn.sent.sentPlanMessages.last,
              case .swipe(let target) = message.payload,
              case .elementDirection(let target, let direction) = target.selection else {
            XCTFail("Expected element direction swipe to lower to element direction swipe")
            return
        }
        XCTAssertEqual(target, .predicate(.identifier("row_5")))
        XCTAssertEqual(direction, .left)
    }

    @ButtonHeistActor
    func testDragWithStartCoordinatesDispatchesCanonicalPayload() async {
        let (fence, mockConn) = makeConnectedFence()
        _ = try? await fence.execute(command: .drag, values: [
                "pointToPoint": .object([
                    "start": .object(["x": .double(100.0), "y": .double(300.0)]),
                    "end": .object(["x": .double(300.0), "y": .double(600.0)]),
                ]),
            ])
        guard let message = mockConn.sent.sentPlanMessages.last,
              case .drag(let target) = message.payload,
              case .pointToPoint(let start, let end) = target.selection else {
            XCTFail("Expected drag message")
            return
        }
        XCTAssertEqual(start, ScreenPoint(x: 100.0, y: 300.0))
        XCTAssertEqual(end, ScreenPoint(x: 300.0, y: 600.0))
    }

    @ButtonHeistActor
    func testPublicMutatingCommandsUseDurableOrTransientDeviceWire() async throws {
        let target = targetValue(identifier: "target")
        let durableCases: [(command: TheFence.Command, arguments: [String: HeistValue])] = [
            (.activate, ["target": target]),
            (.activate, ["target": target, "action": .string("increment")]),
            (.activate, ["target": target, "action": .string("decrement")]),
            (.activate, ["target": target, "action": .string("Archive")]),
            (.rotor, ["target": target, "rotor": .string("Errors")]),
            (.oneFingerTap, ["point": .object(["x": .double(12), "y": .double(34)])]),
            (.longPress, ["point": .object(["x": .double(12), "y": .double(34)])]),
            (.swipe, [
                "elementDirection": .object([
                    "element": target,
                    "direction": .string(SwipeDirection.left.rawValue),
                ]),
            ]),
            (.drag, [
                "elementToPoint": .object([
                    "element": target,
                    "end": .object(["x": .double(120), "y": .double(240)]),
                ]),
            ]),
            (.typeText, ["text": .string("hello"), "target": target]),
            (.editAction, ["action": .string(EditAction.paste.rawValue)]),
            (.setPasteboard, ["text": .string("clipboard")]),
            (.dismissKeyboard, [:]),
            (.wait, [
                "predicate": .object([
                    "type": .string("changed"),
                    "scope": .string("elements"),
                    "assertions": .array([]),
                ]),
                "timeout": .double(1),
            ]),
        ]
        let transientCases: [(command: TheFence.Command, arguments: [String: HeistValue])] = [
            (.scroll, ["direction": .string(ScrollDirection.down.rawValue)]),
            (.scrollToVisible, ["target": target]),
            (.scrollToEdge, ["edge": .string(ScrollEdge.bottom.rawValue)]),
        ]

        for testCase in durableCases {
            let (fence, mockConn) = makeConnectedFence()

            _ = try await fence.execute(command: testCase.command, values: testCase.arguments)

            XCTAssertEqual(mockConn.sent.count, 1, testCase.command.rawValue)
            guard case .heistPlan(let run) = mockConn.sent.first?.0 else {
                return XCTFail("Expected \(testCase.command.rawValue) to send heistPlan, got \(String(describing: mockConn.sent.first?.0))")
            }
            XCTAssertEqual(run.plan.body.count, 1, testCase.command.rawValue)
        }

        for testCase in transientCases {
            let (fence, mockConn) = makeConnectedFence()

            _ = try await fence.execute(command: testCase.command, values: testCase.arguments)

            XCTAssertEqual(mockConn.sent.count, 1, testCase.command.rawValue)
            guard case .runtimeAction(let command) = mockConn.sent.first?.0 else {
                return XCTFail(
                    "Expected \(testCase.command.rawValue) to send runtimeAction, got \(String(describing: mockConn.sent.first?.0))"
                )
            }
            XCTAssertNotNil(command.durableHeistActionFailure, testCase.command.rawValue)
        }
    }

}
