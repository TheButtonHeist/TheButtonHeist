import Foundation
import Testing
@_spi(ButtonHeistInternals) @testable import ThePlans

@Test func `action command contract table covers every wire command type`() throws {
    let coveredTypes = actionCommandContractCases.map(\.wireType.rawValue).sorted()
    let allTypes = HeistActionCommandType.allCases.map(\.rawValue).sorted()

    #expect(coveredTypes == allTypes)
}

@Test func `resolved action retains its authored command type`() throws {
    for testCase in actionCommandContractCases {
        let resolved = try testCase.command.resolve(in: .empty)
        #expect(resolved.type == testCase.wireType)
    }
}

@Test func `action command target traversal reports roles paths and report targets`() throws {
    let commandPath = HeistPlanPath.root.child(.body).index(0).child(.action).child(.command)
    let cases: [(String, HeistActionCommand, [TargetOccurrenceExpectation])] = [
        (
            "semantic expression target",
            .activate(.label("Pay")),
            [
                TargetOccurrenceExpectation(
                    role: .semantic,
                    path: .payloadTarget,
                    renderedPath: "$.body[0].action.command.payload.target",
                    reportTarget: .label("Pay")
                ),
            ]
        ),
        (
            "scroll expression target",
            .scrollToVisible(.label("Checkout")),
            [
                TargetOccurrenceExpectation(
                    role: .scroll,
                    path: .payloadTarget,
                    renderedPath: "$.body[0].action.command.payload.target",
                    reportTarget: .label("Checkout")
                ),
            ]
        ),
        (
            "gesture element target",
            .swipe(SwipeTarget(
                selection: .elementDirection(.label("Row"), .up)
            )),
            [
                TargetOccurrenceExpectation(
                    role: .gesture,
                    path: .payloadElement,
                    renderedPath: "$.body[0].action.command.payload.element",
                    reportTarget: .label("Row")
                ),
            ]
        ),
        (
            "scroll container element target",
            .scroll(ScrollTarget(selection: .element(.label("List")), direction: .down)),
            [
                TargetOccurrenceExpectation(
                    role: .scroll,
                    path: .payloadTarget,
                    renderedPath: "$.body[0].action.command.payload.target",
                    reportTarget: .label("List")
                ),
            ]
        ),
    ]

    for (name, command, expected) in cases {
        let actual = command.targetOccurrences.map {
            TargetOccurrenceExpectation(
                role: $0.role,
                path: $0.path,
                renderedPath: $0.path.appending(to: commandPath).description,
                reportTarget: $0.reportTarget
            )
        }
        #expect(actual == expected, "\(name)")
    }
}

@Test func `gesture point decoding rejects nonfinite coordinates`() {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
        positiveInfinity: "Infinity",
        negativeInfinity: "-Infinity",
        nan: "NaN"
    )

    #expect(throws: DecodingError.self) {
        _ = try decoder.decode(ScreenPoint.self, from: Data(#"{"x":"NaN","y":0}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        _ = try decoder.decode(UnitPoint.self, from: Data(#"{"x":0,"y":"Infinity"}"#.utf8))
    }
}

@Test func `runtime gesture coordinates require finite admission`() throws {
    let screenX: Double = 12.5
    let screenY: Double = -34
    let unitX: Double = 0.25
    let unitY: Double = 0.75

    let screenPoint = ScreenPoint(
        x: try FiniteCoordinate(validating: screenX),
        y: try FiniteCoordinate(validating: screenY)
    )
    let unitPoint = UnitPoint(
        x: try FiniteCoordinate(validating: unitX),
        y: try FiniteCoordinate(validating: unitY)
    )

    #expect(screenPoint.x == screenX)
    #expect(screenPoint.y == screenY)
    #expect(unitPoint.x == unitX)
    #expect(unitPoint.y == unitY)

    for value in [Double.nan, .infinity, -.infinity] {
        #expect(throws: FiniteCoordinate.ValidationError.self) {
            _ = try FiniteCoordinate(validating: value)
        }
    }
}

@Test func `action command wire durability report target and canonical source contracts stay aligned`() throws {
    for testCase in actionCommandContractCases {
        let data = try JSONEncoder().encode(testCase.command)
        let encoded = try JSONDecoder().decode(EncodedCommandType.self, from: data)

        #expect(testCase.command.wireType == testCase.wireType)
        #expect(encoded.type == testCase.wireType.rawValue)
        #expect(try JSONDecoder().decode(HeistActionCommand.self, from: data) == testCase.command)
        #expect(testCase.command.durableHeistActionFailure == testCase.durabilityFailure)
        #expect(testCase.command.reportTarget == testCase.reportTarget)

        if let canonicalLine = testCase.canonicalLine {
            let plan = try HeistPlan(body: [.action(ActionStep(command: testCase.command))])
            let expectedSource = canonicalPlanSource(canonicalLine)
            #expect(try plan.canonicalSwiftDSL() == expectedSource)
            #expect(try HeistSourceParser.parse(expectedSource) == plan)
        } else {
            let expectedFailure = try #require(testCase.durabilityFailure)
            let diagnostics = runtimeSafetyDiagnostics {
                try HeistPlan(body: [.action(ActionStep(command: testCase.command))])
            }
            expectNonDurableHeistActionFailure(diagnostics, observed: expectedFailure)
        }
    }
}

@Test func `runtime admission validates every string loop value through invocations`() throws {
    let definition = try HeistPlan(
        name: "typeQuery",
        parameter: .string(name: "query"),
        body: [.action(ActionStep(command: .typeText(
            reference: "query",
            target: .label("Search")
        )))])
    let diagnostics = runtimeSafetyDiagnostics {
        try HeistPlan(
            definitions: [
                definition,
            ],
            body: [.forEachString(try ForEachStringStep(
                values: ["Milk", ""],
                parameter: "item",
                body: [.invoke(HeistInvocationStep(
                    path: "typeQuery",
                    argument: .string(reference: "item")
                ))]
            ))]
        )
    }

    #expect(diagnostics.contains {
        $0.message.contains("string loop value must resolve to an admissible action command")
            && $0.message.contains("$.body[0].for_each_string.values[1] resolved to")
            && $0.message.contains("text to append must be non-empty")
    }, "\(diagnostics)")
}

@Test func `rotor index admits dynamic values before command construction`() throws {
    #expect(try RotorIndex(validating: 0).value == 0)
    #expect(throws: RotorIndex.ValidationError.self) {
        _ = try RotorIndex(validating: -1)
    }
}

@Test func `action command refs encode as accessibility targets`() throws {
    let commands: [HeistActionCommand] = [
        .activate(.ref("field")),
        .increment(.ref("field")),
        .decrement(.ref("field")),
        .customAction(name: "Archive", target: .ref("field")),
        .rotor(selection: .named("Links"), target: .ref("field"), direction: .next),
        .typeText(text: "milk", target: .ref("field")),
        .scrollToVisible(.ref("field")),
    ]

    for command in commands {
        let data = try JSONEncoder().encode(command)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])
        let target = try #require(payload["target"] as? [String: Any])

        #expect(target["ref"] as? String == "field", "\(command.wireType)")
    }
}

@Test func `runtime action payloads encode the target key`() throws {
    func expectCanonicalTargetKey<Payload: Encodable>(_ payload: Payload, name: String) throws {
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["target"] != nil, "\(name)")
    }

    try expectCanonicalTargetKey(
        CustomActionTarget(target: .ref("field"), actionName: "Archive"),
        name: "custom action"
    )
    try expectCanonicalTargetKey(
        RotorTarget(target: .ref("field"), selection: .named("Links")),
        name: "rotor"
    )
    try expectCanonicalTargetKey(
        TypeTextTarget(text: "milk", target: .ref("field")),
        name: "type text"
    )
}

@Test func `wait timeout contract matrix covers DSL expectations and runtime payloads`() throws {
    let waitCases: [(String, HeistPlan, WaitStep)] = [
        (
            "WaitFor default",
            try HeistPlan {
                WaitFor(.exists(.label("Home")))
            },
            WaitStep(predicate: .exists(.label("Home")), timeout: defaultWaitTimeout)
        ),
        (
            "WaitFor explicit",
            try HeistPlan {
                WaitFor(.exists(.label("Home")), timeout: 5)
            },
            WaitStep(predicate: .exists(.label("Home")), timeout: 5)
        ),
        (
            "expect any element delta",
            try HeistPlan {
                Activate(.label("Pay")).expect(.elementsChanged)
            },
            WaitStep(predicate: .elementsChanged, timeout: 3)
        ),
        (
            "expect default timeout",
            try HeistPlan {
                Activate(.label("Pay")).expect(.exists(.label("Receipt")))
            },
            WaitStep(predicate: .exists(.label("Receipt")), timeout: 3)
        ),
        (
            "expect explicit timeout",
            try HeistPlan {
                Activate(.label("Pay")).expect(.exists(.label("Receipt")), timeout: 3)
            },
            WaitStep(predicate: .exists(.label("Receipt")), timeout: 3)
        ),
    ]

    for (name, plan, expectedWait) in waitCases {
        let actualWait = try #require(plan.onlyWaitStep, "Missing wait step for \(name)")
        #expect(actualWait == expectedWait, "\(name)")
    }

    let predicate = AccessibilityPredicate.exists(.label("Home"))
    let waitTargetCases: [(String, WaitTarget, WaitTimeout?, WaitTimeout)] = [
        ("default runtime timeout", WaitTarget(predicate: predicate), nil, defaultWaitTimeout),
        ("explicit runtime timeout", WaitTarget(predicate: predicate, timeout: 12), 12, 12),
        ("maximum runtime timeout", WaitTarget(predicate: predicate, timeout: 60), 60, 60),
    ]

    for (name, target, timeout, resolvedTimeout) in waitTargetCases {
        #expect(target.timeout == timeout, "\(name)")
        #expect(target.resolvedTimeout == resolvedTimeout, "\(name)")
    }
}

@Test func `wait timeout maximum has one external override`() throws {
    let configuredMaximum = WaitTimeout.maximumSeconds(environment: [
        WaitTimeout.maximumSecondsEnvironmentKey: "120",
    ])

    #expect(WaitTimeout.maximumSeconds(environment: [:]) == 60)
    #expect(configuredMaximum == 120)
    for invalidValue in ["", "not-a-number", "0", "29", "-1", "nan", "infinity"] {
        #expect(
            WaitTimeout.maximumSeconds(environment: [
                WaitTimeout.maximumSecondsEnvironmentKey: invalidValue,
            ]) == 60,
            "invalid override: \(invalidValue)"
        )
    }
    for invalidLowerBoundary in [-Double.leastNonzeroMagnitude, 0] {
        #expect(throws: WaitTimeoutError.self) {
            _ = try WaitTimeout(validatingSeconds: invalidLowerBoundary)
        }
    }
    let smallestPositiveBoundary = Double.leastNonzeroMagnitude
    #expect(
        try WaitTimeout(validatingSeconds: smallestPositiveBoundary).seconds == smallestPositiveBoundary
    )
    #expect(try WaitTimeout(validatingSeconds: 120, maximumSeconds: configuredMaximum).seconds == 120)
    #expect(throws: WaitTimeoutError.self) {
        _ = try WaitTimeout(
            validatingSeconds: configuredMaximum.nextUp,
            maximumSeconds: configuredMaximum
        )
    }
}

@Test func `heist timeout admits every finite positive duration without an upper cap`() throws {
    #expect(HeistTimeout.default.seconds == 60)
    #expect(try HeistTimeout(validatingSeconds: Double.greatestFiniteMagnitude).seconds ==
        Double.greatestFiniteMagnitude)

    for seconds in [0, -1, .nan, .infinity] {
        #expect(throws: HeistTimeoutError.self) {
            _ = try HeistTimeout(validatingSeconds: seconds)
        }
    }
}

@Test func `heist timeout codable contract is one admitted number`() throws {
    let timeout = try HeistTimeout(validatingSeconds: 120.5)
    let encoded = try JSONEncoder().encode(timeout)

    #expect(String(bytes: encoded, encoding: .utf8) == "120.5")
    #expect(try JSONDecoder().decode(HeistTimeout.self, from: encoded) == timeout)

    for json in ["0", "-1", "null", #""60""#] {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(HeistTimeout.self, from: Data(json.utf8))
        }
    }
}

@Test func `payload admission rejects invalid durations and prohibited empty text`() throws {
    for seconds in [0, -1, .nan, .infinity, GestureDuration.maximumSeconds.nextUp] {
        #expect(throws: GestureProjectionError.self) {
            _ = try GestureDuration(validatingSeconds: seconds)
        }
    }

    for seconds in [0, -1, .nan, .infinity, WaitTimeout.maximumSeconds.nextUp] {
        #expect(throws: WaitTimeoutError.self) {
            _ = try WaitTimeout.seconds(seconds)
        }
    }

    for milliseconds in [0, -1, .nan, .infinity, (WaitTimeout.maximumSeconds * 1_000).nextUp] {
        #expect(throws: WaitTimeoutError.self) {
            _ = try WaitTimeout.milliseconds(milliseconds)
        }
    }

    #expect(throws: TextInputTextError.self) {
        _ = try TextInputText(validating: "")
    }
    #expect(TextInputText.replacing("").description.isEmpty)
    #expect(throws: PasteboardTextError.self) {
        _ = try PasteboardText(validating: "")
    }
}

@Test func `dynamic duration admission preserves units at valid boundaries`() throws {
    let gestureSeconds = GestureDuration.maximumSeconds
    let waitSeconds = WaitTimeout.maximumSeconds
    let waitMilliseconds = WaitTimeout.maximumSeconds * 1_000
    let replacement = String()

    #expect(try GestureDuration(validatingSeconds: gestureSeconds).seconds == gestureSeconds)
    #expect(try WaitTimeout.seconds(waitSeconds).seconds == waitSeconds)
    #expect(try WaitTimeout.milliseconds(waitMilliseconds).seconds == waitSeconds)
    #expect(try TextInputText(validating: replacement, mode: .replace) == .replacing(replacement))
}

@Test func `payload decoding uses the same admission bounds without repair`() throws {
    for json in ["0", "-1", "60.0000000001", "1e20", "-1e20", "1.7976931348623157e308"] {
        expectDataCorrupted("gesture duration \(json)", contains: "duration must be") {
            _ = try JSONDecoder().decode(GestureDuration.self, from: Data(json.utf8))
        }
    }

    let waitPrefix = #"{"predicate":{"type":"exists","target":{"checks":[{"kind":"label","match":{"mode":"exact","value":"Home"}}]}},"timeout":"#
    for timeout in ["0", "-1", "60.0000000001"] {
        expectDataCorrupted("wait timeout \(timeout)", contains: "wait timeout must be") {
            _ = try JSONDecoder().decode(WaitTarget.self, from: Data("\(waitPrefix)\(timeout)}".utf8))
        }
    }

    expectDataCorrupted("type text", contains: "text to append must be non-empty") {
        _ = try JSONDecoder().decode(TypeTextTarget.self, from: Data(#"{"text":"","mode":"append"}"#.utf8))
    }
    expectDataCorrupted("pasteboard", contains: "pasteboard text must be non-empty") {
        _ = try JSONDecoder().decode(SetPasteboardTarget.self, from: Data(#"{"text":""}"#.utf8))
    }
}

@Test func `number rendering preserves finite values outside integer range`() throws {
    for value in [Double(Int.max), Double(Int.min).nextDown, 1e20, -1e20, Double.greatestFiniteMagnitude] {
        let text = CanonicalValueDescription.decimal(value)
        #expect(Double(text) == value)
    }
    #expect(CanonicalValueDescription.decimal(1.000_000_1) == "1")
    #expect(CanonicalValueDescription.decimal(1.25) == "1.25")
}

@Test func `nonpositive wait timeout wire payloads are rejected at admission`() {
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(WaitStep.self, from: Data("""
        {
          "predicate": {
            "type": "exists",
            "target": {
              "checks": [
                { "kind": "label", "match": { "mode": "exact", "value": "Home" } }
              ]
            }
          },
          "timeout": 0
        }
        """.utf8))
    }
}

@Test func `blank custom action names are rejected at admission`() throws {
    expectDataCorrupted("plan command payload", contains: "custom action name must not be blank") {
        _ = try JSONDecoder().decode(HeistActionCommand.self, from: Data("""
        {
          "type": "performCustomAction",
          "payload": {
            "actionName": "",
            "target": {
              "checks": [
                { "kind": "label", "match": { "mode": "exact", "value": "Message" } }
              ]
            }
          }
        }
        """.utf8))
    }

    expectDataCorrupted("runtime action payload", contains: "custom action name must not be blank") {
        _ = try JSONDecoder().decode(CustomActionTarget.self, from: Data("""
        {
          "target": {
            "checks": [
              { "kind": "label", "match": { "mode": "exact", "value": "Message" } }
            ]
          },
          "actionName": ""
        }
        """.utf8))
    }

    #expect(throws: (any Error).self) {
        _ = try CustomActionName(validating: " \n\t")
    }
    #expect(throws: (any Error).self) {
        _ = try RotorName(validating: " \n\t")
    }
    #expect(throws: (any Error).self) {
        _ = try HeistWarningMessage(validating: " \n\t")
    }
    #expect(throws: (any Error).self) {
        _ = try HeistFailureMessage(validating: " \n\t")
    }
    #expect(try CustomActionName(validating: " Archive ").description == " Archive ")
    #expect(try RotorName(validating: " Headings ").description == " Headings ")
}

@Test func `type text reference payload uses canonical target`() throws {
    let referenced = try JSONDecoder().decode(HeistActionCommand.self, from: Data("""
    {
      "type": "typeText",
      "payload": {
        "text_ref": "item",
        "mode": "append",
        "target": { "ref": "field" }
      }
    }
    """.utf8))
    #expect(referenced == .typeText(reference: "item", target: .ref("field"), mode: .append))
}

private struct EncodedCommandType: Decodable {
    let type: String
}

private struct TargetOccurrenceExpectation: Equatable {
    let role: HeistActionCommandTargetOccurrence.Role
    let path: HeistActionCommandTargetOccurrence.Path
    let renderedPath: String
    let reportTarget: AccessibilityTarget?
}

private struct ActionCommandContractCase {
    let wireType: HeistActionCommandType
    let command: HeistActionCommand
    let durabilityFailure: String?
    let reportTarget: AccessibilityTarget?
    let canonicalLine: String?
}

private let actionCommandContractCases: [ActionCommandContractCase] = [
    ActionCommandContractCase(
        wireType: .activate,
        command: .activate(.label("Activate Target")),
        durabilityFailure: nil,
        reportTarget: .label("Activate Target"),
        canonicalLine: #"Activate(.label("Activate Target"))"#
    ),
    ActionCommandContractCase(
        wireType: .increment,
        command: .increment(.label("Stepper")),
        durabilityFailure: nil,
        reportTarget: .label("Stepper"),
        canonicalLine: #"Increment(.label("Stepper"))"#
    ),
    ActionCommandContractCase(
        wireType: .decrement,
        command: .decrement(.label("Stepper")),
        durabilityFailure: nil,
        reportTarget: .label("Stepper"),
        canonicalLine: #"Decrement(.label("Stepper"))"#
    ),
    ActionCommandContractCase(
        wireType: .performCustomAction,
        command: .customAction(name: "Archive", target: .label("Message")),
        durabilityFailure: nil,
        reportTarget: .label("Message"),
        canonicalLine: #"CustomAction("Archive", on: .label("Message"))"#
    ),
    ActionCommandContractCase(
        wireType: .rotor,
        command: .rotor(selection: .named("Headings"), target: .label("Article"), direction: .previous),
        durabilityFailure: nil,
        reportTarget: .label("Article"),
        canonicalLine: #"Rotor("Headings", on: .label("Article"), direction: .previous)"#
    ),
    ActionCommandContractCase(
        wireType: .oneFingerTap,
        command: .oneFingerTap(TapTarget(selection: .element(.label("Tap Target")))),
        durabilityFailure: nil,
        reportTarget: .label("Tap Target"),
        canonicalLine: #"oneFingerTap(.label("Tap Target"))"#
    ),
    ActionCommandContractCase(
        wireType: .longPress,
        command: .longPress(LongPressTarget(selection: .element(.label("Press Target")))),
        durabilityFailure: nil,
        reportTarget: .label("Press Target"),
        canonicalLine: #"longPress(.label("Press Target"))"#
    ),
    ActionCommandContractCase(
        wireType: .swipe,
        command: .swipe(SwipeTarget(selection: .elementDirection(.label("List"), .up))),
        durabilityFailure: nil,
        reportTarget: .label("List"),
        canonicalLine: #"swipe(.label("List"), .up)"#
    ),
    ActionCommandContractCase(
        wireType: .drag,
        command: .drag(DragTarget(start: .element(.label("Slider")), end: ScreenPoint(x: 200, y: 40))),
        durabilityFailure: nil,
        reportTarget: .label("Slider"),
        canonicalLine: #"drag(.label("Slider"), to: ScreenPoint(x: 200, y: 40))"#
    ),
    ActionCommandContractCase(
        wireType: .typeText,
        command: .typeText(text: "milk", target: .label("Search")),
        durabilityFailure: nil,
        reportTarget: .label("Search"),
        canonicalLine: #"TypeText("milk", into: .label("Search"))"#
    ),
    ActionCommandContractCase(
        wireType: .editAction,
        command: .editAction(EditActionTarget(action: .paste)),
        durabilityFailure: nil,
        reportTarget: nil,
        canonicalLine: "Edit(.paste)"
    ),
    ActionCommandContractCase(
        wireType: .setPasteboard,
        command: .setPasteboard(SetPasteboardTarget(text: "milk")),
        durabilityFailure: nil,
        reportTarget: nil,
        canonicalLine: #"SetPasteboard("milk")"#
    ),
    ActionCommandContractCase(
        wireType: .takeScreenshot,
        command: .takeScreenshot,
        durabilityFailure: nil,
        reportTarget: nil,
        canonicalLine: "TakeScreenshot()"
    ),
    ActionCommandContractCase(
        wireType: .dismiss,
        command: .dismiss,
        durabilityFailure: nil,
        reportTarget: nil,
        canonicalLine: "ScreenActions.Dismiss()"
    ),
    ActionCommandContractCase(
        wireType: .magicTap,
        command: .magicTap,
        durabilityFailure: nil,
        reportTarget: nil,
        canonicalLine: "ScreenActions.MagicTap()"
    ),
    ActionCommandContractCase(
        wireType: .scroll,
        command: .scroll(ScrollTarget(selection: .element(.label("Scrollable List")), direction: .down)),
        durabilityFailure: "scroll is a direct client command, not a durable heist action",
        reportTarget: .label("Scrollable List"),
        canonicalLine: nil
    ),
    ActionCommandContractCase(
        wireType: .scrollToVisible,
        command: .scrollToVisible(.label("Checkout")),
        durabilityFailure: "scroll_to_visible is a direct client command, not a durable heist action",
        reportTarget: .label("Checkout"),
        canonicalLine: nil
    ),
    ActionCommandContractCase(
        wireType: .scrollToEdge,
        command: .scrollToEdge(ScrollToEdgeTarget(selection: .element(.label("Scrollable List")), edge: .bottom)),
        durabilityFailure: "scroll_to_edge is a direct client command, not a durable heist action",
        reportTarget: .label("Scrollable List"),
        canonicalLine: nil
    ),
    ActionCommandContractCase(
        wireType: .dismissKeyboard,
        command: .dismissKeyboard,
        durabilityFailure: nil,
        reportTarget: nil,
        canonicalLine: "dismissKeyboard()"
    ),
]

private func canonicalPlanSource(_ line: String) -> String {
    """
    HeistPlan {
        \(line)
    }
    """
}

private func runtimeSafetyDiagnostics(
    _ operation: () throws -> HeistPlan
) -> [HeistBuildDiagnostic] {
    do {
        _ = try operation()
        return []
    } catch let error as HeistPlanBuildError {
        return error.diagnostics
    } catch {
        Issue.record("Expected runtime safety error, got \(error)")
        return []
    }
}

private let nonDurableHeistActionRepairHint =
    "Use a direct client command for debug/session actions, or replace " +
    "this with a canonical durable DSL action."

private func expectNonDurableHeistActionFailure(
    _ diagnostics: [HeistBuildDiagnostic],
    observed: String,
    path: String = "$.body[0].action.command"
) {
    #expect(diagnostics.contains {
        $0.path == path
            && $0.message == "durable heist action; observed \(observed)"
            && $0.hint == nonDurableHeistActionRepairHint
    }, "\(diagnostics)")
}

private func expectDataCorrupted(
    _ name: String,
    contains expectedMessage: String,
    decode: () throws -> Void
) {
    do {
        try decode()
        Issue.record("Expected \(name) to reject invalid JSON")
    } catch DecodingError.dataCorrupted(let context) {
        #expect(
            context.debugDescription.contains(expectedMessage),
            "\(name) error \(context.debugDescription) did not contain \(expectedMessage)"
        )
    } catch {
        Issue.record("Expected \(name) to throw DecodingError.dataCorrupted, got \(error)")
    }
}

private extension HeistPlan {
    var onlyWaitStep: WaitStep? {
        guard body.count == 1 else { return nil }
        switch body[0] {
        case .wait(let step):
            return step
        case .action(let step):
            return step.expectationPolicy.expectedExpectation?
                .waitStep(using: .default)
        case .conditional, .forEachElement, .forEachString, .repeatUntil, .warn, .fail, .heist, .invoke:
            return nil
        }
    }
}
