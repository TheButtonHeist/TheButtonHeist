import ButtonHeistTestSupport
import XCTest
import ThePlans
import AccessibilitySnapshotModel
@_spi(ButtonHeistInternals) @testable import TheScore

extension WireTypeRoundTripTests {
    // MARK: - ProtocolMismatchPayload

    func testProtocolMismatchPayloadRoundTrip() throws {
        let payload = ProtocolMismatchPayload(
            serverButtonHeistVersion: "2026.5.9",
            clientButtonHeistVersion: "2026.5.8"
        )
        let data = try encoder.encode(payload)
        let decoded = try decoder.decode(ProtocolMismatchPayload.self, from: data)
        XCTAssertEqual(decoded.serverButtonHeistVersion, "2026.5.9")
        XCTAssertEqual(decoded.clientButtonHeistVersion, "2026.5.8")
    }

    // MARK: - HeistPlan

    func testHeistPlanRoundTripPreservesCommandStepWireShape() throws {
        let plan = try HeistPlan(body: [
                .action(ActionStep(
                    command: .activate(.predicate(
                        ElementPredicate(label: "Settings", traits: [.button]),
                        ordinal: 1
                    )),
                    expectationPolicy: .expect(ActionExpectation(predicate: .screenChanged, timeout: 2.5)))),
                .action(ActionStep(
                    command: .setPasteboard(SetPasteboardTarget(text: "ready"))
                )),
                .warn(WarnStep(message: "optional step skipped")),
                .fail(FailStep(message: "unexpected state"))
            ]
        )

        let data = try encoder.encode(plan)
        let payload = try JSONProbe(data: data)

        XCTAssertEqual(try payload.int("version"), HeistPlan.currentVersion)
        let body = try payload.array("body")
        XCTAssertEqual(body.count, 4)
        XCTAssertEqual(try body[0].string("type"), "action")
        let action = try body[0].object("action")
        let command = try action.object("command")
        XCTAssertEqual(try command.string("type"), "activate")
        let target = try command.object("payload").object("target")
        XCTAssertEqual(try target.int("ordinal"), 1)
        let checks = try target.array("checks")
        XCTAssertEqual(checks.count, 2)
        XCTAssertEqual(try checks[0].string("kind"), "label")
        let labelMatch = try checks[0].object("match")
        XCTAssertEqual(try labelMatch.string("mode"), "exact")
        XCTAssertEqual(try labelMatch.string("value"), "Settings")
        XCTAssertEqual(try checks[1].string("kind"), "traits")
        XCTAssertEqual(try checks[1].strings("values"), ["button"])
        let expectation = try action.object("expectation")
        let predicate = try expectation.object("predicate")
        XCTAssertEqual(try predicate.string("type"), "changed")
        XCTAssertEqual(try predicate.string("scope"), "screen")
        // A screen predicate carries no assertion list at all: elements are
        // never named in this lane, so the key is absent rather than empty.
        XCTAssertThrowsError(try predicate.array("assertions"))
        XCTAssertEqual(try expectation.double("timeout"), 2.5)
        XCTAssertEqual(try body[2].object("warn").string("message"), "optional step skipped")
        XCTAssertEqual(try body[3].object("fail").string("message"), "unexpected state")

        let decoded = try decoder.decode(HeistPlan.self, from: data)
        XCTAssertEqual(decoded, plan)
    }

    func testHeistExecutionResultRoundTripKeepsActivationTraceOnlyInActionEvidence() throws {
        let command = HeistActionCommand.activate(.predicate(ElementPredicate(label: "Save")))
        let activationTrace = ActivationTrace(.activationPointFallback(
            axActivateReturned: false,
            tapActivationPoint: ScreenPoint(x: 195, y: 139),
            tapActivationSucceeded: true
        ), implementsAccessibilityActivation: false)
        let failure = HeistFailureDetail(
            category: .targetResolution,
            contract: "action dispatch succeeds",
            observed: "No element matching label \"Save\"",
            expected: "predicate(label=\"Save\")"
        )
        let step = HeistResultFixture.action(
            command: command,
            result: .activationFailure(
                failureKind: .elementNotFound,
                message: "No element matching label \"Save\"",
                observation: .none,
                activationTrace: activationTrace
            ),
            failure: failure
        )
        let result = HeistResultFixture.result(steps: [step])

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(HeistResult.self, from: data)

        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.outcome, .failed(abortedAtPath: "$.body[0]"))
        XCTAssertEqual(decoded.steps[0].actionEvidence?.result?.activationTrace, activationTrace)

        let payload = try JSONProbe(data: data)
        let encodedStep = try payload.array("steps")[0]
        let node = try encodedStep.object("node")
        let encodedFailure = try node.object("failure")
        XCTAssertEqual(try node.string("type"), "action")
        XCTAssertEqual(try node.string("outcome"), "failed")
        XCTAssertEqual(try node.object("command").string("type"), "activate")
        try encodedStep.assertMissing("kind")
        try encodedStep.assertMissing("intent")
        try encodedStep.assertMissing("outcome")
        try encodedFailure.assertMissing("activationTrace")
    }

    func testHeistCaseSelectionOutcomeRequiresUnsignedIndex() {
        let json = """
        {
          "cases": [],
          "outcome": {
            "kind": "matched_case",
            "index": -1
          },
          "elapsedMs": 1
        }
        """
        XCTAssertThrowsError(try decoder.decode(HeistCaseSelectionResult.self, from: Data(json.utf8)))
    }

    func testHeistCaseSelectionRejectsInvalidTiming() {
        let json = """
        {
          "cases": [],
          "outcome": {"kind": "no_match"},
          "elapsedMs": -1
        }
        """
        XCTAssertThrowsError(
            try decoder.decode(HeistCaseSelectionResult.self, from: Data(json.utf8))
        ) { error in
            assertDecodingError(error, contains: ["elapsed milliseconds", "must not be negative"])
        }
    }

    func testHeistCaseSelectionRejectsOutcomeContradictingCases() throws {
        let matched = HeistCaseMatchResult(
            predicate: .exists(.label("Ready")),
            met: true
        )
        let valid = HeistCaseSelectionResult.selectingFirstMatch(
            cases: [matched],
            ifNone: .noMatch,
            elapsedMs: 1
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(valid)) as? [String: Any]
        )
        object["outcome"] = ["kind": "no_match"]

        XCTAssertThrowsError(try decoder.decode(
            HeistCaseSelectionResult.self,
            from: JSONSerialization.data(withJSONObject: object)
        )) { error in
            assertDecodingError(error, contains: ["cannot contain a matched case"])
        }
    }

    func testHeistCaseSelectionRejectsTimeoutOutcomeWithoutTimeout() {
        let json = """
        {
          "cases": [],
          "outcome": {"kind": "timed_out"},
          "elapsedMs": 1
        }
        """
        XCTAssertThrowsError(
            try decoder.decode(HeistCaseSelectionResult.self, from: Data(json.utf8))
        ) { error in
            assertDecodingError(error, contains: ["timed_out", "positive timeout"])
        }
    }

    func testHeistCaseSelectionDerivesItsMatchedCaseFromItsCases() {
        let matched = HeistCaseMatchResult(
            predicate: .exists(.label("Ready")),
            met: true
        )
        let missed = HeistCaseMatchResult(
            predicate: .exists(.label("Waiting")),
            met: false
        )
        let result = HeistCaseSelectionResult.selectingFirstMatch(
            cases: [missed, matched],
            ifNone: .noMatch,
            elapsedMs: 4
        )

        XCTAssertEqual(result.outcome, .matchedCase(index: 1))
    }

    func testForEachEvidenceRejectsPartialStringIterationShape() throws {
        let missingValue = """
        {
          "iterationCount": 1,
          "iterationOrdinal": 0
        }
        """

        XCTAssertThrowsError(
            try decoder.decode(HeistForEachEvidence.self, from: Data(missingValue.utf8))
        ) { error in
            assertDecodingError(error, contains: ["do not form one string or element iteration"])
        }
    }

    func testForEachEvidenceRejectsPartialElementIterationShape() throws {
        let missingTargetSummary = """
        {
          "matchedCount": 2,
          "iterationCount": 1,
          "iterationOrdinal": 0,
          "targetOrdinal": 0
        }
        """

        XCTAssertThrowsError(
            try decoder.decode(HeistForEachEvidence.self, from: Data(missingTargetSummary.utf8))
        ) { error in
            assertDecodingError(
                error,
                contains: ["do not form one string or element iteration"]
            )
        }
    }

    func testRotorTextRangeRejectsPartialIndexedShape() throws {
        let missingEndOffset = """
        {
          "rangeDescription": "[0..<4]",
          "text": "Menu",
          "startOffset": 0
        }
        """

        XCTAssertThrowsError(try decoder.decode(RotorTextRange.self, from: Data(missingEndOffset.utf8))) { error in
            assertDecodingError(error, contains: ["requires startOffset and endOffset together"])
        }
    }

    // MARK: - Wire Message Types

    func testClientWireMessageTypeAllCasesRoundTrip() throws {
        for messageType in ClientWireMessageType.allCases {
            let data = try encoder.encode(messageType)
            let decoded = try decoder.decode(ClientWireMessageType.self, from: data)
            XCTAssertEqual(decoded, messageType)
        }
    }

    func testServerWireMessageTypeAllCasesRoundTrip() throws {
        for messageType in ServerWireMessageType.allCases {
            let data = try encoder.encode(messageType)
            let decoded = try decoder.decode(ServerWireMessageType.self, from: data)
            XCTAssertEqual(decoded, messageType)
        }
    }

    // MARK: - TXTRecordKey

    func testTXTRecordKeyRawValues() {
        XCTAssertEqual(TXTRecordKey.simUDID.rawValue, "simudid")
        XCTAssertEqual(TXTRecordKey.installationId.rawValue, "installationid")
        XCTAssertEqual(TXTRecordKey.deviceName.rawValue, "devicename")
        XCTAssertEqual(TXTRecordKey.instanceId.rawValue, "instanceid")
        XCTAssertEqual(TXTRecordKey.transport.rawValue, "transport")
    }

    // MARK: - Failure kinds

    func testActionFailureKindAllCasesRoundTrip() throws {
        for kind in ActionFailure.Kind.allCases {
            let data = try encoder.encode(kind)
            let decoded = try decoder.decode(ActionFailure.Kind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    func testServerErrorKindAllCasesRoundTrip() throws {
        for kind in ServerError.Kind.allCases {
            let data = try encoder.encode(kind)
            let decoded = try decoder.decode(ServerError.Kind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    // MARK: - WaitTarget

    func testWaitTargetRoundTrip() throws {
        let target = WaitTarget(
            predicate: .missing(.label("loading")),
            timeout: 15
        )
        let data = try encoder.encode(target)
        let decoded = try decoder.decode(WaitTarget.self, from: data)
        XCTAssertEqual(decoded.predicate, .missing(.label("loading")))
        XCTAssertEqual(decoded.timeout, 15)
    }

    func testWaitTargetResolvedDefaults() {
        let target = WaitTarget(predicate: .exists(.label("x")))
        XCTAssertEqual(target.resolvedTimeout, defaultWaitTimeout)
    }

    func testWaitTargetRejectsTimeoutAboveMaximum() {
        let json = #"{"predicate":{"type":"exists","target":{"checks":[{"kind":"label","match":{"mode":"exact","value":"x"}}]}},"timeout":61}"#

        XCTAssertThrowsError(try decoder.decode(WaitTarget.self, from: Data(json.utf8))) { error in
            assertDecodingError(error, contains: ["wait timeout must be"])
        }
    }

    func testWaitTargetChangedResolvedDefaults() {
        let target = WaitTarget(predicate: .elementsChanged)
        XCTAssertEqual(target.resolvedTimeout, defaultWaitTimeout)
    }
}
