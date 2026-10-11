import ButtonHeistTestSupport
import XCTest
import ThePlans
@_spi(ButtonHeistInternals) import TheScore

final class ClientMessageTests: XCTestCase {

    func testClientHelloRoundTrip() throws {
        let message = ClientMessage.clientHello
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)

        guard case .clientHello = decoded else {
            return XCTFail("Expected clientHello, got \(decoded)")
        }
    }

    func testRequestSnapshotEncodeDecode() throws {
        let message = ClientMessage.requestInterface(InterfaceQuery())
        let data = try JSONEncoder().encode(message)
        let object = try JSONProbe(data: data)
        XCTAssertEqual(try object.string("type"), "requestInterface")
        _ = try object.object("payload")

        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)

        if case .requestInterface = decoded {
        } else {
            XCTFail("Expected requestInterface, got \(decoded)")
        }
    }

    func testRequestSnapshotRejectsMissingPayload() throws {
        let data = Data(#"{"type":"requestInterface"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ClientMessage.self, from: data))
    }

    func testRequestSnapshotRejectsInvalidDiscoveryLimits() throws {
        let data = Data(#"{"type":"requestInterface","payload":{"maxScrollsPerContainer":-1}}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ClientMessage.self, from: data)) { error in
            XCTAssertTrue(
                "\(error)".contains("interface discovery limit must be between 1 and 2000"),
                "\(error)"
            )
        }
    }

    func testRequestEnvelopeRejectsServerOnlyMessageTypeAtTypedBoundary() {
        let data = Data("""
        {"buttonHeistVersion":"\(TheScore.buttonHeistVersion)","type":"serverHello"}
        """.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(RequestEnvelope.self, from: data)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
            XCTAssertEqual(context.debugDescription, "Unsupported client wire message type: serverHello")
        }
    }

    func testRequestEnvelopeRejectsUnknownTopLevelField() throws {
        let data = Data("""
        {"buttonHeistVersion":"\(TheScore.buttonHeistVersion)","type":"ping","unknownField":"value"}
        """.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(RequestEnvelope.self, from: data)) { error in
            XCTAssertTrue(
                "\(error)".contains("unknownField"),
                "Expected unknown request envelope field in error, got \(error)"
            )
        }
    }

    func testClientMessageRejectsUnknownTopLevelField() throws {
        let data = Data(#"{"type":"ping","staleField":"value"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ClientMessage.self, from: data)) { error in
            XCTAssertTrue("\(error)".contains("staleField"), "\(error)")
        }
    }

    func testNoPayloadClientMessageRejectsStrayPayload() throws {
        let data = Data(#"{"type":"ping","payload":{"junk":true}}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ClientMessage.self, from: data)) { error in
            XCTAssertTrue("\(error)".contains("ping must not include a payload"), "\(error)")
        }
    }

    func testNoPayloadRequestEnvelopeRejectsStrayPayload() throws {
        let data = Data("""
        {"buttonHeistVersion":"\(TheScore.buttonHeistVersion)","type":"ping","payload":{"junk":true}}
        """.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(RequestEnvelope.self, from: data)) { error in
            XCTAssertTrue("\(error)".contains("ping must not include a payload"), "\(error)")
        }
    }

    func testWireTypeMatchesEncodedType() throws {
        let messages: [ClientMessage] = [
            .clientHello,
            .requestInterface(InterfaceQuery()),
            .ping,
            .status,
            .getPasteboard,
            .getNotifications,
            .requestScreen(),
            .heistPlan(HeistPlanRun(plan: try HeistPlan(body: [
                .action(ActionStep(
                    command: .activate(.predicate(ElementPredicate(label: "Save")))
                )),
            ]))),
        ]

        for message in messages {
            let encoded = try JSONEncoder().encode(message)
            let wireType = try JSONDecoder().decode(EncodedClientMessageType.self, from: encoded).type

            XCTAssertEqual(message.wireType.rawValue, wireType, "\(message)")
        }
    }

    func testPingEncodeDecode() throws {
        let message = ClientMessage.ping
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)

        if case .ping = decoded {
        } else {
            XCTFail("Expected ping, got \(decoded)")
        }
    }

    func testStatusEncodeDecode() throws {
        let message = ClientMessage.status
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)

        if case .status = decoded {
        } else {
            XCTFail("Expected status, got \(decoded)")
        }
    }

    // MARK: - Heist Plan Tests

    func testHeistPlanRunAcceptsOnlyCurrentCanonicalFields() throws {
        let policy = ActionExpectationTimeoutPolicy(standard: 3, screenTransition: 12)
        let run = HeistPlanRun(
            plan: try HeistPlan(body: [
                .wait(WaitStep(predicate: .exists(.label("Ready")), timeout: 1)),
            ]),
            actionExpectationTimeoutPolicy: policy
        )

        let encoded = try JSONEncoder().encode(run)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["action_expectation_timeout_policy", "argument", "plan", "timeout"]
        )
        let policyObject = try XCTUnwrap(
            object["action_expectation_timeout_policy"] as? [String: Any]
        )
        XCTAssertEqual(Set(policyObject.keys), ["screen_transition", "standard"])

        let decoded = try JSONDecoder().decode(HeistPlanRun.self, from: encoded)
        XCTAssertEqual(decoded.argument, .none)
        XCTAssertEqual(decoded.timeout, .default)
        XCTAssertEqual(decoded.actionExpectationTimeoutPolicy, policy)
        XCTAssertEqual(decoded.plan.body.count, 1)

        var unknownPolicy = policyObject
        unknownPolicy["screenTransition"] = 12
        var unknownRun = object
        unknownRun["action_expectation_timeout_policy"] = unknownPolicy
        XCTAssertThrowsError(try JSONDecoder().decode(
            HeistPlanRun.self,
            from: JSONSerialization.data(withJSONObject: unknownRun)
        ))
    }

    func testHeistPlanRunRequiresRuntimePoliciesOnWire() throws {
        let run = HeistPlanRun(plan: try HeistPlan(body: [
            .wait(WaitStep(predicate: .exists(.label("Ready")), timeout: 1)),
        ]))
        let encoded = try JSONEncoder().encode(run)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for field in ["timeout", "action_expectation_timeout_policy"] {
            var missingField = object
            missingField.removeValue(forKey: field)
            XCTAssertThrowsError(try JSONDecoder().decode(
                HeistPlanRun.self,
                from: JSONSerialization.data(withJSONObject: missingField)
            ), field)
        }
    }

    func testHeistPlanRunRejectsRemovedAndUnknownFields() throws {
        let run = HeistPlanRun(plan: try HeistPlan(body: [
            .wait(WaitStep(predicate: .exists(.label("Ready")), timeout: 1)),
        ]))
        let encoded = try JSONEncoder().encode(run)
        let canonicalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        for field in ["continuity", "historicalWaitDiagnostics", "unknownField"] {
            var object = canonicalObject
            object[field] = true
            let data = try JSONSerialization.data(withJSONObject: object)

            XCTAssertThrowsError(try JSONDecoder().decode(HeistPlanRun.self, from: data), field) { error in
                XCTAssertTrue("\(error)".contains(field), "Expected \(field) in error, got \(error)")
            }
        }
    }

    func testHeistPlanClientMessageRoundTrip() throws {
        let saveTarget = AccessibilityTarget.predicate(ElementPredicate(label: "Save", traits: [.button]))
        let plan = try HeistPlan(body: [
                .action(ActionStep(
                    command: .activate(saveTarget),
                    expectationPolicy: .expect(ActionExpectation(predicate: .screenChanged, timeout: 10)))),
                .wait(WaitStep(
                    predicate: .exists(.element(.label("Save"), traits: [.button])),
                    timeout: 2.5
                )),
                .wait(WaitStep(
                    predicate: .exists(.label("Done")),
                    timeout: 1.0
                )),
            ]
        )
        let message = ClientMessage.heistPlan(HeistPlanRun(plan: plan))

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)

        guard case .heistPlan(let decodedRun) = decoded else {
            return XCTFail("Expected heistPlan, got \(decoded)")
        }
        let decodedPlan = decodedRun.plan
        XCTAssertEqual(decodedRun.argument, HeistArgument.none)
        XCTAssertEqual(decodedRun.timeout, .default)
        XCTAssertEqual(decodedRun.actionExpectationTimeoutPolicy, .default)
        XCTAssertEqual(decodedPlan.body.count, 3)
        guard case .action(let decodedAction) = decodedPlan.body[0],
              decodedAction.expectationPolicy.expectedExpectation?.predicate == .screenChanged else {
            return XCTFail("Expected activate command with screen change predicate")
        }
        XCTAssertEqual(decodedAction.command, .activate(saveTarget))
    }

    func testHeistPlanClientMessageRoundTripPreservesRootArgument() throws {
        let plan = try HeistPlan(
            name: "search",
            parameter: .string(name: "query"),
            body: [
                .action(ActionStep(command: .typeText(
                    reference: "query",
                    target: .predicate(.label("Search"))
                ))),
            ]
        )
        let message = ClientMessage.heistPlan(HeistPlanRun(
            plan: plan,
            argument: .string("milk")
        ))

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)

        guard case .heistPlan(let decodedRun) = decoded else {
            return XCTFail("Expected heistPlan, got \(decoded)")
        }
        XCTAssertEqual(decodedRun.plan, plan)
        XCTAssertEqual(decodedRun.argument, .string("milk"))
    }

    func testHeistPlanEnvelopeRoundTrip() throws {
        let plan = try HeistPlan(body: [
            .action(ActionStep(
                command: .typeText(
                    text: "hello",
                    target: .predicate(ElementPredicate(identifier: "nameField"))
                )
            )),
        ])
        let envelope = RequestEnvelope(
            requestId: .fixture("heist-1"),
            message: .heistPlan(HeistPlanRun(plan: plan))
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RequestEnvelope.self, from: data)

        XCTAssertEqual(decoded.requestId, .fixture("heist-1"))
        guard case .heistPlan(let decodedRun) = decoded.message,
              let step = decodedRun.plan.body.first,
              case .action(let action) = step,
              action.expectationPolicy.expectedExpectation == nil else {
            return XCTFail("Expected heistPlan envelope, got \(decoded.message)")
        }
        guard case .typeText(let payload) = try action.command.resolve(in: .empty).payload else {
            return XCTFail("Expected resolved typeText command")
        }
        XCTAssertEqual(payload.text, "hello")
        XCTAssertEqual(payload.target, .predicate(.identifier("nameField")))
        XCTAssertEqual(payload.text.mode, .append)
    }

    func testHeistActionDescriptionUsesNormalCommandIdentity() throws {
        let step = ActionStep(
            command: .activate(.predicate(ElementPredicate(label: "Save"))),
            expectationPolicy: .expect(ActionExpectation(predicate: .screenChanged, timeout: 10)))

        XCTAssertEqual(
            step.description,
            #"action(command=activate expect=.screenChanged)"#
        )
    }

    func testPrimitiveMutatingRequestEnvelopeJSONIsRejected() throws {
        let primitiveRequests = [
            """
            {
              "buttonHeistVersion": "\(TheScore.buttonHeistVersion)",
              "type": "activate",
              "payload": {
                "target": {
                  "checks": [
                    { "kind": "label", "match": { "mode": "exact", "value": "Save" } }
                  ]
                }
              }
            }
            """,
            #"{"buttonHeistVersion":"\#(TheScore.buttonHeistVersion)","type":"wait","payload":{"predicate":{"type":"change","scopes":[{"type":"elements"}]}}}"#,
            #"{"buttonHeistVersion":"\#(TheScore.buttonHeistVersion)","type":"setPasteboard","payload":{"text":"clipboard"}}"#,
        ]

        for json in primitiveRequests {
            XCTAssertThrowsError(try JSONDecoder().decode(RequestEnvelope.self, from: Data(json.utf8)), json) { error in
                XCTAssertTrue("\(error)".contains("Unsupported client wire message type"), "\(error)")
            }
        }
    }

    func testPrimitiveMutatingClientMessageJSONIsRejected() throws {
        let primitiveMessages = [
            #"{"type":"activate","payload":{"target":{"checks":[{"kind":"label","match":{"mode":"exact","value":"Save"}}]}}}"#,
            #"{"type":"typeText","payload":{"text":"hello","mode":"append"}}"#,
            #"{"type":"setPasteboard","payload":{"text":"clipboard"}}"#,
            #"{"type":"wait","payload":{"predicate":{"type":"change","scopes":[{"type":"elements"}]},"timeout":1}}"#,
        ]

        for json in primitiveMessages {
            XCTAssertThrowsError(try JSONDecoder().decode(ClientMessage.self, from: Data(json.utf8)), json) { error in
                XCTAssertTrue("\(error)".contains("Unsupported client wire message type"), "\(error)")
            }
        }
    }

    func testSingleActivateWireShapeIsHeistPlan() throws {
        let plan = try HeistPlan(body: [
            .action(ActionStep(
                command: .activate(.predicate(ElementPredicate(label: "Log In")))
            )),
        ])
        let message = ClientMessage.heistPlan(HeistPlanRun(plan: plan))
        let data = try JSONEncoder().encode(message)

        let object = try JSONProbe(data: data)
        XCTAssertEqual(try object.string("type"), "heistPlan")
        let body = try object.object("payload").object("plan").array("body")
        let firstStep = try XCTUnwrap(body.first)
        XCTAssertEqual(try firstStep.string("type"), "action")
    }

    func testRequestScreenshotEncodeDecode() throws {
        let message = ClientMessage.requestScreen()
        let data = try JSONEncoder().encode(message)
        let object = try JSONProbe(data: data)
        XCTAssertEqual(try object.string("type"), "requestScreen")
        try object.assertMissing("payload")

        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)

        if case .requestScreen = decoded {
        } else {
            XCTFail("Expected requestScreen, got \(decoded)")
        }
    }

    func testRequestAccessibilityScreenshotEncodeDecode() throws {
        let envelope = RequestEnvelope(
            requestId: .fixture("screen-1"),
            message: .requestScreen(ScreenRequestPayload(
                mode: .accessibility,
                timeout: 12
            ))
        )
        let data = try JSONEncoder().encode(envelope)
        let object = try JSONProbe(data: data)
        XCTAssertEqual(try object.string("type"), "requestScreen")
        XCTAssertEqual(try object.object("payload").string("mode"), "accessibility")
        XCTAssertEqual(try object.object("payload").double("timeout"), 12)

        let decoded = try JSONDecoder().decode(RequestEnvelope.self, from: data)
        if case .requestScreen(let payload) = decoded.message {
            XCTAssertEqual(payload.mode, .accessibility)
            XCTAssertEqual(payload.timeout, 12)
        } else {
            XCTFail("Expected requestScreen, got \(decoded.message)")
        }
    }

    func testRequestScreenshotRejectsUnknownPayloadField() throws {
        let data = Data(
            #"{"type":"requestScreen","payload":{"mode":"raw","timeout":30,"stale":true}}"#.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(ClientMessage.self, from: data)) { error in
            XCTAssertTrue("\(error)".contains("stale"), "\(error)")
        }
    }

    // MARK: - TypeText Tests

    func testTypeTextWithTextOnly() throws {
        let target = TypeTextTarget(text: "Hello")
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(TypeTextTarget.self, from: data)

        XCTAssertEqual(decoded.source, .text("Hello"))
        XCTAssertNil(decoded.target)
    }

    func testTypeTextRejectsMissingTextOnDecode() throws {
        let json = #"{}"#

        XCTAssertThrowsError(try JSONDecoder().decode(TypeTextTarget.self, from: Data(json.utf8)))
    }

    func testTypeTextReplacingExistingAllowsEmptyText() throws {
        let target = TypeTextTarget(
            text: .replacing(""),
            target: .predicate(ElementPredicate(identifier: "nameField"))
        )
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(TypeTextTarget.self, from: data)

        XCTAssertEqual(decoded.source, .text(.replacing("")))
        if case .predicate(let matcher, _) = decoded.target {
            XCTAssertEqual(matcher.checks, [.identifier(.exact("nameField"))])
        } else {
            XCTFail("Expected .matcher target")
        }
    }

    func testTypeTextRejectsEmptyTextWithoutReplacingExistingOnDecode() throws {
        let json = #"{"text":"","mode":"append"}"#

        XCTAssertThrowsError(try JSONDecoder().decode(TypeTextTarget.self, from: Data(json.utf8)))
    }

    func testTypeTextWithAccessibilityTarget() throws {
        let target = TypeTextTarget(
            text: "Hello",
            target: .predicate(ElementPredicate(identifier: "nameField"))
        )
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(TypeTextTarget.self, from: data)

        XCTAssertEqual(decoded.source, .text("Hello"))
        if case .predicate(let matcher, _) = decoded.target {
            XCTAssertEqual(matcher.checks, [.identifier(.exact("nameField"))])
        } else {
            XCTFail("Expected .matcher target")
        }
    }

    // MARK: - SetPasteboard Tests

    func testSetPasteboardRoundTrip() throws {
        let target = SetPasteboardTarget(text: "clipboard content")
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(SetPasteboardTarget.self, from: data)

        XCTAssertEqual(decoded.text, "clipboard content")
    }

    func testSetPasteboardEnvelopeUsesHeistPlan() throws {
        let plan = try HeistPlan(body: [
            .action(ActionStep(command: .setPasteboard(SetPasteboardTarget(text: "hello")))),
        ])
        let envelope = RequestEnvelope(
            requestId: .fixture("pb-set"),
            message: .heistPlan(HeistPlanRun(plan: plan))
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RequestEnvelope.self, from: data)

        XCTAssertEqual(decoded.requestId, .fixture("pb-set"))
        guard case .heistPlan(let run) = decoded.message,
              case .action(let step)? = run.plan.body.first else {
            return XCTFail("Expected heistPlan setPasteboard, got \(decoded.message)")
        }
        XCTAssertEqual(step.command, .setPasteboard(SetPasteboardTarget(text: "hello")))
    }

    // MARK: - GetPasteboard Tests

    func testGetPasteboardRoundTrip() throws {
        let message = ClientMessage.getPasteboard
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)

        if case .getPasteboard = decoded {
            // pass
        } else {
            XCTFail("Expected getPasteboard, got \(decoded)")
        }
    }

    func testGetPasteboardEnvelopeRoundTrip() throws {
        let envelope = RequestEnvelope(
            requestId: .fixture("pb-get"),
            message: .getPasteboard
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RequestEnvelope.self, from: data)

        XCTAssertEqual(decoded.requestId, .fixture("pb-get"))
        if case .getPasteboard = decoded.message {
            // pass
        } else {
            XCTFail("Expected getPasteboard, got \(decoded.message)")
        }
    }

    func testGetNotificationsRoundTrip() throws {
        let message = ClientMessage.getNotifications
        let data = try JSONEncoder().encode(message)
        let object = try JSONProbe(data: data)
        XCTAssertEqual(try object.string("type"), "getNotifications")
        try object.assertMissing("payload")
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)

        if case .getNotifications = decoded {
            // pass
        } else {
            XCTFail("Expected getNotifications, got \(decoded)")
        }
    }

    func testGetNotificationsEnvelopeRoundTrip() throws {
        let envelope = RequestEnvelope(
            requestId: .fixture("notifications-get"),
            message: .getNotifications
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RequestEnvelope.self, from: data)

        XCTAssertEqual(decoded.requestId, .fixture("notifications-get"))
        if case .getNotifications = decoded.message {
            // pass
        } else {
            XCTFail("Expected getNotifications, got \(decoded.message)")
        }
    }

    // MARK: - Wait Tests

    func testWaitAbsentRoundTrip() throws {
        let target = WaitTarget(
            predicate: .missing(.element(.label("Loading"), traits: [.staticText])),
            timeout: 5.0
        )
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(WaitTarget.self, from: data)

        XCTAssertEqual(decoded.predicate, .missing(.element(.label("Loading"), traits: [.staticText])))
        XCTAssertEqual(decoded.timeout, 5.0)
    }

    func testWaitPresentRoundTrip() throws {
        let target = WaitTarget(predicate: .exists(.identifier("spinner")))
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(WaitTarget.self, from: data)

        XCTAssertEqual(decoded.predicate, .exists(.identifier("spinner")))
        XCTAssertNil(decoded.timeout)
        XCTAssertEqual(decoded.resolvedTimeout, defaultWaitTimeout)
    }

    func testWaitRejectsTimeoutAboveMaximum() {
        let json = #"{"predicate":{"type":"exists","target":{"checks":[{"kind":"label","match":{"mode":"exact","value":"x"}}]}},"timeout":999}"#

        XCTAssertThrowsError(try JSONDecoder().decode(WaitTarget.self, from: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("wait timeout must be"), "\(error)")
        }
    }

    func testWaitChangedScreenRoundTrip() throws {
        let target = WaitTarget(predicate: .screenChanged, timeout: 15.0)
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(WaitTarget.self, from: data)

        XCTAssertEqual(decoded.predicate, .screenChanged)
        XCTAssertEqual(decoded.timeout, 15.0)
    }

    func testWaitAbsentConvenienceRoundTrip() throws {
        let target = WaitTarget(predicate: .missing(.label("Loading")), timeout: 5.0)
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(WaitTarget.self, from: data)

        XCTAssertEqual(decoded.predicate, .missing(.label("Loading")))
        XCTAssertEqual(decoded.timeout, 5.0)
    }

    func testWaitEnvelopeUsesHeistPlan() throws {
        let plan = try HeistPlan(body: [
            .wait(WaitStep(predicate: .elementsChanged, timeout: 8.0)),
        ])
        let envelope = RequestEnvelope(
            requestId: .fixture("wait-1"),
            message: .heistPlan(HeistPlanRun(plan: plan))
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RequestEnvelope.self, from: data)

        XCTAssertEqual(decoded.requestId, .fixture("wait-1"))
        guard case .heistPlan(let run) = decoded.message,
              case .wait(let target)? = run.plan.body.first else {
            return XCTFail("Expected heistPlan wait, got \(decoded.message)")
        }
        XCTAssertEqual(target.predicate, .elementsChanged)
        XCTAssertEqual(target.timeout, 8.0)
    }

    func testActionResultWithoutPayload() throws {
        let result = ActionResult.success(payload: .activate)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ActionResult.self, from: data)
        XCTAssertEqual(decoded.payload, .activate)
    }

    // MARK: - AccessibilityTarget Ordinal Tests

    func testAccessibilityTargetMatcherWithoutOrdinalRoundTrip() throws {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Save"))
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(AccessibilityTarget.self, from: data)

        guard case .predicate(let matcher, let ordinal) = decoded else {
            return XCTFail("Expected .matcher, got \(decoded)")
        }
        XCTAssertEqual(matcher.checks, [.label(.exact("Save"))])
        XCTAssertNil(ordinal)
    }

    func testAccessibilityTargetMatcherWithOrdinalRoundTrip() throws {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Save", traits: [.button]), ordinal: 2)
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(AccessibilityTarget.self, from: data)

        guard case .predicate(let matcher, let ordinal) = decoded else {
            return XCTFail("Expected .matcher, got \(decoded)")
        }
        XCTAssertEqual(matcher.checks, [
            .label(.exact("Save")),
            .traits([.button]),
        ])
        XCTAssertEqual(ordinal, 2)
    }

    func testAccessibilityTargetOrdinalWireFormat() throws {
        let json = #"{"checks":[{"kind":"label","match":{"mode":"exact","value":"Save"}}],"ordinal":2}"#
        let decoded = try JSONDecoder().decode(AccessibilityTarget.self, from: Data(json.utf8))

        guard case .predicate(let matcher, let ordinal) = decoded else {
            return XCTFail("Expected .matcher, got \(decoded)")
        }
        XCTAssertEqual(matcher.checks, [.label(.exact("Save"))])
        XCTAssertEqual(ordinal, 2)
    }

    func testAccessibilityTargetOrdinalOmittedInWireFormat() throws {
        let json = #"{"checks":[{"kind":"label","match":{"mode":"exact","value":"Save"}}]}"#
        let decoded = try JSONDecoder().decode(AccessibilityTarget.self, from: Data(json.utf8))

        guard case .predicate(_, let ordinal) = decoded else {
            return XCTFail("Expected .matcher, got \(decoded)")
        }
        XCTAssertNil(ordinal)
    }

    func testAccessibilityTargetNegativeOrdinalThrows() {
        let json = #"{"checks":[{"kind":"label","match":{"mode":"exact","value":"Save"}}],"ordinal":-1}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AccessibilityTarget.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("non-negative"))
        }
    }

    func testAccessibilityTargetRejectsHeistIdWithMatcherFieldsAtCodableBoundary() {
        // heistId is no longer a targeting field — it is rejected as unknown.
        let json = #"{"heistId":"button_save","checks":[{"kind":"label","match":{"mode":"exact","value":"Save"}}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AccessibilityTarget.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("heistId"))
        }
    }

    func testAccessibilityTargetRejectsHeistIdWithOrdinalAtCodableBoundary() {
        let json = #"{"heistId":"button_save","ordinal":1}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AccessibilityTarget.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("heistId"))
        }
    }

    func testAccessibilityTargetRejectsUnknownFieldAtCodableBoundary() {
        let json = #"{"checks":[{"kind":"label","match":{"mode":"exact","value":"Save"}}],"unexpectedTargetField":"button_save"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AccessibilityTarget.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("unexpectedTargetField"))
        }
    }

    func testAccessibilityTargetOrdinalEquality() {
        let withOrdinal = AccessibilityTarget.predicate(ElementPredicate(label: "Save"), ordinal: 1)
        let withoutOrdinal = AccessibilityTarget.predicate(ElementPredicate(label: "Save"))
        let differentOrdinal = AccessibilityTarget.predicate(ElementPredicate(label: "Save"), ordinal: 2)

        XCTAssertNotEqual(withOrdinal, withoutOrdinal)
        XCTAssertNotEqual(withOrdinal, differentOrdinal)
        XCTAssertEqual(withOrdinal, AccessibilityTarget.predicate(ElementPredicate(label: "Save"), ordinal: 1))
    }

    // MARK: - UnitPoint Tests

    func testUnitPointRoundTrip() throws {
        let swipe = SwipeTarget(
            selection: .unitElement(
                .predicate(ElementPredicate(identifier: "scrollable")),
                start: UnitPoint(x: 0.8, y: 0.5),
                end: UnitPoint(x: 0.2, y: 0.5)
            )
        )
        let data = try JSONEncoder().encode(swipe)
        let decoded = try JSONDecoder().decode(SwipeTarget.self, from: data)

        XCTAssertEqual(
            decoded.selection,
            .unitElement(
                .predicate(ElementPredicate(identifier: "scrollable")),
                start: UnitPoint(x: 0.8, y: 0.5),
                end: UnitPoint(x: 0.2, y: 0.5)
            )
        )
    }
}

// MARK: - Test Helpers

private struct EncodedClientMessageType: Decodable {
    let type: String
}

extension HeistElement {
    static func stub(
        label: String? = nil,
        traits: [HeistTrait] = []
    ) -> HeistElement {
        makeTestHeistElement(
            description: label ?? "stub",
            label: label,
            traits: traits,
            actions: []
        )
    }
}
