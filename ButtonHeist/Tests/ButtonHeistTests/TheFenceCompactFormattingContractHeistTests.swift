import ButtonHeistTestSupport
import XCTest
import ThePlans
import AccessibilitySnapshotModel
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

extension TheFenceCompactFormattingContractTests {

    private struct MeasurementExpectation: Equatable {
        let name: String
        let valueMs: Int
        let path: String?

        init(name: String, valueMs: Int, path: String?) {
            self.name = name
            self.valueMs = valueMs
            self.path = path
        }

        init(measurement: HeistReport.Measurement) {
            self.init(
                name: measurement.name.rawValue,
                valueMs: measurement.valueMs.milliseconds,
                path: measurement.path?.description
            )
        }
    }

    func testExpectationSuccessStaysSuccessfulAcrossPublicFormats() throws {
        let response = FenceResponse.action(
            result: ActionResult.success(payload: .activate),
            expectation: ExpectationResult(
                met: true,
                predicate: .exists(.label("Done")),
                actual: "matched"
            )
        )

        let json = try publicJSONProbe(response)
        let expectation = try json.object("expectation")

        XCTAssertEqual(try json.string("status"), "ok")
        XCTAssertEqual(try expectation.bool("met"), true)
        XCTAssertEqual(response.compactFormatted(), "activate: ok")
        XCTAssertTrue(response.humanFormatted().contains("[expectation met]"))
        XCTAssertFalse(response.isFailure)
    }

    func testCompactHeistExpectationGapIsTotalForEveryObservationGap() throws {
        for expectationGap in PublicHeistExecutionJSONContractFixture.expectationGaps {
            let response = try publicHeistExecutionResponse(
                step: PublicHeistExecutionJSONContractFixture.failedWait(
                    expectationGap: expectationGap.gap
                )
            )

            XCTAssertTrue(
                response.compactFormatted().contains(" ?"),
                expectationGap.publicCode
            )
        }
    }

    func testHumanHeistFormattingCountsNestedProjectedExpectations() throws {
        let expected = AccessibilityPredicate.exists(.label("Done"))
        let childAction = try HeistStep.action(ActionStep(
            command: .activate(.predicate(ElementPredicate(label: .exact("Submit")))),
            expectationPolicy: .expect(ActionExpectation(predicate: expected, timeout: 1))))
        let casePredicate = PresenceCondition.exists(.label("Home"))
        let casePredicateRuntime = AccessibilityPredicate.exists(.label("Home"))
        let conditional = try ConditionalStep(cases: [
            PredicateCase(predicate: casePredicate, body: [childAction]),
        ])
        let plan = try HeistPlan(body: [.conditional(conditional)])
        let childResult = HeistResultFixture.action(
            path: "$.body[0].conditional.cases[0].body[0]",
            result: ActionResult.success(payload: .activate),
            expectation: HeistResultFixture.defaultWaitEvidence(met: true)
        )
        let result = try HeistResult(
            steps: [
                HeistResultFixture.conditional(
                    status: .passed,
                    selection: .selectingFirstMatch(
                        cases: [
                            HeistCaseMatchResult(
                                predicate: casePredicateRuntime,
                                met: true
                            ),
                        ],
                        ifNone: .noMatch,
                        elapsedMs: 1
                    ),
                    children: [childResult]
                ),
            ],
            durationMs: 1
        )

        let output = FenceResponse.heistExecution(plan: plan, report: HeistReport.project(result: result)).humanFormatted()

        XCTAssertTrue(output.contains("[expectations: 1/1 met]"), output)
    }

    func testHeistExpectationCountsAgreeAcrossPublicFormats() throws {
        let expected = AccessibilityPredicate.exists(.label("Done"))
        let action = try HeistStep.action(ActionStep(
            command: .activate(.predicate(ElementPredicate(label: "Submit"))),
            expectationPolicy: .expect(ActionExpectation(predicate: expected, timeout: 1))))
        let plan = try HeistPlan(body: [
            .warn(WarnStep(message: "starting checkout")),
            action,
        ])
        let result = try HeistResult(
            steps: [
                HeistResultFixture.warning(path: "$.body[0]", message: "starting checkout"),
                HeistResultFixture.action(
                    path: "$.body[1]",
                    command: .activate(.predicate(ElementPredicate(label: "Submit"))),
                    result: ActionResult.success(payload: .activate),
                    expectation: HeistResultFixture.defaultWaitEvidence(met: true)
                ),
            ],
            durationMs: 5
        )
        let response = FenceResponse.heistExecution(plan: plan, report: HeistReport.project(result: result))

        let json = try publicJSONProbe(response)
        let report = try json.object("report")
        let reportExpectations = try json.object("report").object("summary").object("expectations")

        try assertHeistReportRootOmitsSummaryDuplicates(json)
        try assertPublicHeistSummary(
            report.object("summary"),
            executedTopLevelStepCount: 2,
            executedNodeCount: 2,
            outputNodeCount: 2,
            durationMs: 5,
            abortedAtPath: nil
        )
        XCTAssertEqual(try reportExpectations.int("checked"), 1)
        XCTAssertEqual(try reportExpectations.int("met"), 1)
        XCTAssertTrue(response.compactFormatted().contains("heist: 2 top-level steps in 5ms"))
        XCTAssertTrue(response.compactFormatted().contains("[expectations: 1/1]"))
        XCTAssertTrue(response.humanFormatted().contains("Heist: 2 top-level step(s) executed in 5ms"))
        XCTAssertTrue(response.humanFormatted().contains("[expectations: 1/1 met]"))
    }

    func testPublicHeistJSONIncludesScoreMetricProjection() throws {
        let expected = AccessibilityPredicate.exists(.label("Done"))
        let command = HeistActionCommand.activate(.predicate(ElementPredicate(label: "Submit")))
        let plan = try HeistPlan(body: [
            .action(ActionStep(command: command, expectationPolicy: .expect(ActionExpectation(
                predicate: expected,
                timeout: 1
            )))),
        ])
        let result = try HeistResult(
            steps: [
                HeistResultFixture.action(
                    command: command,
                    result: ActionResult.success(
                        payload: .activate,
                        observation: .observed(makeObservationEvidence(
                            before: makeTestInterface(elementCount: 0),
                            coverage: .complete
                        )),
                        timing: ActionPerformanceTiming(targetResolutionMs: 1, totalMs: 9)
                    ),
                    expectation: HeistResultFixture.defaultWaitEvidence(met: true)
                ),
            ],
            durationMs: 12
        )

        let metrics = try publicHeistReportJSON(
            FenceResponse.heistExecution(plan: plan, report: HeistReport.project(result: result))
        ).object("metrics").decode(HeistReport.Metrics.self)

        XCTAssertEqual(metrics.measurements.map(MeasurementExpectation.init(measurement:)), [
            MeasurementExpectation(name: "heistDurationMs", valueMs: 12, path: nil),
            MeasurementExpectation(name: "actionPipeline.targetResolutionMs", valueMs: 1, path: "$.body[0]"),
            MeasurementExpectation(name: "actionPipeline.totalMs", valueMs: 9, path: "$.body[0]"),
        ])
    }

    func testExplicitSingleActionHeistKeepsReportShapeAcrossPublicFormats() throws {
        let plan = try HeistPlan(body: [
            .action(ActionStep(command: .activate(.predicate(ElementPredicate(label: "Pay"))))),
        ])
        let result = try HeistResult(
            steps: [
                HeistResultFixture.action(
                    command: .activate(.predicate(ElementPredicate(label: "Pay"))),
                    result: ActionResult.success(payload: .activate)
                ),
            ],
            durationMs: 3
        )
        let response = FenceResponse.heistExecution(plan: plan, report: HeistReport.project(result: result))

        let json = try publicJSONProbe(response)
        let compact = response.compactFormatted()

        XCTAssertEqual(try json.string("status"), "ok")
        try json.assertPresent("report")
        try json.assertMissing("method")
        XCTAssertTrue(compact.contains("heist: 1 top-level steps in 3ms"), compact)
        XCTAssertTrue(compact.contains("[0] activate"), compact)
    }

    func testCompactHeistFormattingReportsFailStepMessage() throws {
        let plan = try HeistPlan(body: [.fail(FailStep(message: "Unknown screen"))])
        let result = try HeistResult(
            steps: [
                HeistResultFixture.explicitFailure(message: "Unknown screen"),
            ],
            durationMs: 1
        )

        let output = FenceResponse.heistExecution(plan: plan, report: HeistReport.project(result: result)).compactFormatted()

        XCTAssertTrue(
            output.contains("[0] fail -> error[request.action_failed request retryable=false]: Unknown screen"),
            output
        )
    }

    func testPublicHeistJSONReportsFailStepMessage() throws {
        let plan = try HeistPlan(body: [.fail(FailStep(message: "Unknown screen"))])
        let result = try HeistResult(
            steps: [
                HeistResultFixture.explicitFailure(message: "Unknown screen"),
            ],
            durationMs: 1
        )
        let response = FenceResponse.heistExecution(plan: plan, report: HeistReport.project(result: result))

        let json = try publicJSONProbe(response)
        let node = try XCTUnwrap(try json.object("report").array("nodes").first)

        XCTAssertEqual(try json.string("status"), "partial")
        try json.assertMissing("results")
        XCTAssertEqual(try node.string("path"), "$.body[0]")
        XCTAssertEqual(try node.string("kind"), "fail")
        XCTAssertEqual(try node.string("status"), "failed")
        XCTAssertEqual(try node.string("message"), "Unknown screen")
    }

    @ButtonHeistActor
    func testTimeoutMismatchUsesCanonicalFailureDiagnostics() async throws {
        let predicate = AccessibilityPredicate.exists(.label("Ticket saved."))
        let mismatch = #"observed accessibility candidate label="Ticket saved., Dismiss" traits=[staticText] "#
            + #"did not match exists(target(predicate(label="Ticket saved.")))"#
        let message = "timed out waiting for exact predicate; \(mismatch)"
        let plan = try HeistPlan(body: [
            .wait(WaitStep(predicate: predicate, timeout: 1)),
        ])
        let current = makeTestObservationSnapshot(elements: [])
        let step = HeistResultFixture.failedWait(
            evidence: HeistResultFixture.expectationEvidence(
                predicate: predicate,
                observation: Observation.Evidence(
                    baseline: nil,
                    events: [.elementsChanged(current)],
                    current: current,
                    coverage: .complete
                ),
                terminalCause: .deadline
            ),
            failure: HeistFailureDetail(
                category: .wait,
                contract: "wait predicate is met before timeout",
                observed: message,
                expected: predicate.description
            )
        )
        let report = HeistReport.project(result: try HeistResult(steps: [step], durationMs: 1))
        let response = FenceResponse.heistExecution(plan: plan, report: report)
        let node = try XCTUnwrap(try publicJSONProbe(response).object("report").array("nodes").first)
        let (fence, _) = makeConnectedFence()

        XCTAssertEqual(try node.object("failure").string("observed"), message)
        XCTAssertTrue(response.compactFormatted().contains(mismatch), response.compactFormatted())
        let human = response.humanFormatted()
        XCTAssertTrue(
            human.contains("Heist: 1 top-level step(s) executed in 1ms (stopped at $.body[0])"),
            human
        )
        XCTAssertTrue(human.contains("Error at $.body[0] [request.action_failed request retryable=false]"), human)
        XCTAssertTrue(human.contains(message), human)
        let junit = fence.junitXML(for: report, heistName: "toast")
        XCTAssertTrue(junit.contains(#"observed accessibility candidate label=&quot;Ticket saved., Dismiss&quot;"#))
        XCTAssertTrue(junit.contains(#"did not match exists(target(predicate(label=&quot;Ticket saved.&quot;)))"#))
        try node.assertMissing("historicalDiagnostics")
        try node.assertMissing("continuity")
    }

    func testAbortedHeistOutputCountsOnlyResultNodes() throws {
        let plan = try HeistPlan(body: [
            .warn(WarnStep(message: "before")),
            .fail(FailStep(message: "stop")),
            .warn(WarnStep(message: "after")),
        ])
        let result = try HeistResult(
            steps: [
                HeistResultFixture.warning(path: "$.body[0]", message: "before"),
                HeistResultFixture.explicitFailure(path: "$.body[1]", message: "stop"),
                .warning(
                    path: try HeistExecutionPath(validating: "$.body[2]"),
                    message: "after",
                    completion: .skipped()
                ),
            ],
            durationMs: 2
        )
        let response = FenceResponse.heistExecution(plan: plan, report: HeistReport.project(result: result))

        let json = try publicJSONProbe(response)
        let report = try json.object("report")
        let nodes = try report.array("nodes")
        let compact = response.compactFormatted()

        try assertHeistReportRootOmitsSummaryDuplicates(json)
        try assertPublicHeistSummary(
            report.object("summary"),
            executedTopLevelStepCount: 2,
            executedNodeCount: 2,
            outputNodeCount: 3,
            durationMs: 2,
            abortedAtPath: "$.body[1]"
        )
        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(try nodes.map { try $0.string("path") }, ["$.body[0]", "$.body[1]", "$.body[2]"])
        XCTAssertEqual(try nodes.map { try $0.string("status") }, ["passed", "failed", "skipped"])
        XCTAssertTrue(compact.contains("heist: 2 top-level steps"), compact)
        XCTAssertTrue(compact.contains("[0] warn -> warning: before"), compact)
        XCTAssertTrue(compact.contains("[2] warn -> skipped"), compact)
        XCTAssertFalse(compact.contains("after"), compact)
        XCTAssertTrue(
            response.humanFormatted().contains("Heist: 2 top-level step(s) executed"),
            response.humanFormatted()
        )
    }

    func testPublicHeistJSONReportsNestedSelectedCaseFailureAsTreeNodes() throws {
        let childAction = try HeistStep.action(ActionStep(
            command: .activate(.predicate(ElementPredicate(label: "Continue")))
        ))
        let casePredicate = PresenceCondition.exists(.label("Ready"))
        let casePredicateRuntime = AccessibilityPredicate.exists(.label("Ready"))
        let conditional = try ConditionalStep(cases: [
            PredicateCase(predicate: casePredicate, body: [childAction]),
        ])
        let plan = try HeistPlan(body: [.conditional(conditional)])
        let childPath = "$.body[0].conditional.cases[0].body[0]"
        let childResult = HeistResultFixture.action(
            path: childPath,
            command: .activate(.predicate(ElementPredicate(label: "Continue"))),
            result: ActionResult.failure(
                payload: .activate,
                failureKind: .actionFailed,
                message: "nested button failed"),
            failure: HeistFailureDetail(
                category: .action,
                contract: "activate command succeeds",
                observed: "nested button failed"
            )
        )
        let result = try HeistResult(
            steps: [
                HeistResultFixture.conditional(
                    status: .failed,
                    selection: .selectingFirstMatch(
                        cases: [
                            HeistCaseMatchResult(
                                predicate: casePredicateRuntime,
                                met: true
                            ),
                        ],
                        ifNone: .noMatch,
                        elapsedMs: 1
                    ),
                    failure: HeistFailureDetail(
                        category: .invocation,
                        contract: "selected case completes without failure",
                        observed: "child failed at \(childPath)"
                    ),
                    children: [childResult]
                ),
            ],
            durationMs: 9
        )

        let json = try publicJSONProbe(.heistExecution(plan: plan, report: HeistReport.project(result: result)))
        let nodes = try json.object("report").array("nodes")
        let root = try XCTUnwrap(nodes.first)
        let children = try root.array("children")
        let child = try XCTUnwrap(children.first)
        let caseSelection = try root.object("evidence").object("caseSelection")
        let action = try child.object("evidence").object("action")
        let actionResult = try action.object("result")

        try json.assertMissing("results")
        XCTAssertEqual(try root.string("path"), "$.body[0]")
        XCTAssertEqual(try root.string("kind"), "conditional")
        try caseSelection.assertPresent("outcome")
        try caseSelection.assertMissing("selectedCaseIndex")
        try caseSelection.assertMissing("timedOut")
        try caseSelection.assertMissing("elseRan")
        XCTAssertEqual(try root.string("abortedAtChildPath"), childPath)
        XCTAssertEqual(try child.string("path"), "$.body[0].conditional.cases[0].body[0]")
        XCTAssertEqual(try child.string("kind"), "action")
        XCTAssertEqual(try child.string("status"), "failed")
        try child.assertMissing("action")
        XCTAssertEqual(try action.string("commandName"), "activate")
        XCTAssertEqual(try actionResult.string("status"), "error")
        XCTAssertEqual(try actionResult.string("message"), "nested button failed")
    }

    func testPublicHeistJSONReportsSelectedElsePathAsTreeNodes() throws {
        let elseStep = try HeistStep.action(ActionStep(
            command: .activate(.predicate(ElementPredicate(label: "Fallback")))
        ))
        let predicate = PresenceCondition.exists(.label("Home"))
        let runtimePredicate = AccessibilityPredicate.exists(.label("Home"))
        let conditional = try ConditionalStep(
            cases: [
                PredicateCase(
                    predicate: predicate,
                    body: [try HeistStep.action(ActionStep(command: .activate(.predicate(ElementPredicate(label: "Home")))))]
                ),
            ],
            elseBody: [elseStep]
        )
        let plan = try HeistPlan(body: [.conditional(conditional)])
        let childPath = "$.body[0].conditional.else_body[0]"
        let childResult = HeistResultFixture.action(
            path: childPath,
            command: .activate(.predicate(ElementPredicate(label: "Fallback"))),
            result: ActionResult.success(payload: .activate)
        )
        let result = try HeistResult(
            steps: [
                HeistResultFixture.conditional(
                    status: .passed,
                    selection: .selectingFirstMatch(
                        cases: [
                            HeistCaseMatchResult(
                                predicate: runtimePredicate,
                                met: false
                            ),
                        ],
                        ifNone: .noMatch,
                        elapsedMs: 1,
                        lastObservedSummary: nil
                    ).selectingElseBranch(),
                    children: [childResult]
                ),
            ],
            durationMs: 3
        )

        let json = try publicJSONProbe(.heistExecution(plan: plan, report: HeistReport.project(result: result)))
        let nodes = try json.object("report").array("nodes")
        let root = try XCTUnwrap(nodes.first)
        let evidence = try root.object("evidence")
        let children = try root.array("children")
        let child = try XCTUnwrap(children.first)
        let compact = FenceResponse.heistExecution(plan: plan, report: HeistReport.project(result: result)).compactFormatted()

        XCTAssertEqual(try root.string("kind"), "conditional")
        XCTAssertEqual(try root.string("status"), "passed")
        try evidence.assertPresent("caseSelection")
        XCTAssertEqual(try child.string("path"), "$.body[0].conditional.else_body[0]")
        XCTAssertTrue(compact.contains("[0] conditional"), compact)
        XCTAssertTrue(compact.contains("[1] activate"), compact)
    }

    func testHeistReportProjectsForEachStructurally() throws {
        let forEach = try ForEachStringStep(
            values: ["Milk", "Eggs"],
            parameter: "item",
            body: [.action(ActionStep(command: .typeText(reference: "item", target: nil)))]
        )
        let plan = try HeistPlan(body: [.forEachString(forEach)])
        let firstIteration = HeistResultFixture.forEachStringIteration(
            ordinal: 0,
            value: "Milk",
            status: .passed,
            children: [
                HeistResultFixture.action(
                    path: "$.body[0].for_each_string.iterations[0].body[0]",
                    command: .typeText(reference: "item", target: nil),
                    result: ActionResult.success(payload: .typeText(nil))
                ),
            ]
        )
        let failedActionPath = "$.body[0].for_each_string.iterations[1].body[0]"
        let failedAction = HeistResultFixture.action(
            path: failedActionPath,
            command: .typeText(reference: "item", target: nil),
            result: ActionResult.failure(
                payload: .typeText(nil),
                failureKind: .elementNotFound,
                message: "field missing"),
            failure: HeistFailureDetail(
                category: .action,
                contract: "type_text command succeeds",
                observed: "field missing"
            )
        )
        let secondIteration = HeistResultFixture.forEachStringIteration(
            ordinal: 1,
            value: "Eggs",
            status: .failed,
            failureReason: "iteration 1 failed for value \"Eggs\"",
            children: [failedAction]
        )
        let failedLoopEvidence = try XCTUnwrap(HeistFailedForEachStringEvidence(try XCTUnwrap(
            HeistForEachStringEvidence(
                iterationCount: 2,
                failureReason: "iteration 1 failed for value \"Eggs\""
            )
        )))
        let abortedChildren = try XCTUnwrap(HeistAbortedChildren([firstIteration, secondIteration]))
        let declaration = try XCTUnwrap(HeistForEachStringDeclaration(parameter: "item", count: 2))
        let loopResult = HeistExecutionStepResult.forEachString(
            path: try HeistExecutionPath(validating: "$.body[0]"),
            declaration: declaration,
            completion: .childAborted(
                evidence: failedLoopEvidence,
                failure: HeistFailureDetail(
                    category: .loop,
                    contract: "for_each_string completes all 2 value(s)",
                    observed: "for_each_string stopped after 2 of 2 iteration(s): iteration 1 failed for value \"Eggs\""
                ),
                children: abortedChildren
            )
        )
        let result = try HeistResult(
            steps: [
                loopResult,
            ],
            durationMs: 30
        )
        let response = FenceResponse.heistExecution(plan: plan, report: HeistReport.project(result: result))

        let json = try publicJSONProbe(response)
        let report = try json.object("report")
        let nodeProbes = try json.object("report").array("nodes")
        let rootProbe = try XCTUnwrap(nodeProbes.first)
        let evidence = try rootProbe.object("evidence")
        let children = try rootProbe.array("children")
        let compact = response.compactFormatted()

        try assertHeistReportRootOmitsSummaryDuplicates(json)
        try assertPublicHeistSummary(
            report.object("summary"),
            executedTopLevelStepCount: 1,
            executedNodeCount: 5,
            outputNodeCount: 5,
            durationMs: 30,
            abortedAtPath: failedActionPath
        )
        XCTAssertEqual(try rootProbe.string("kind"), "for_each_string")
        try evidence.assertPresent("forEachString")
        XCTAssertEqual(try rootProbe.string("abortedAtChildPath"), failedActionPath)
        XCTAssertEqual(try children.map { try $0.string("kind") }, ["for_each_iteration", "for_each_iteration"])
        XCTAssertTrue(compact.contains("heist: 1 top-level steps in 30ms"), compact)
        XCTAssertTrue(
            compact.contains(
                "[0] for_each_string -> error[request.action_failed request retryable=false]: for_each_string stopped"
            ),
            compact
        )
    }

}
