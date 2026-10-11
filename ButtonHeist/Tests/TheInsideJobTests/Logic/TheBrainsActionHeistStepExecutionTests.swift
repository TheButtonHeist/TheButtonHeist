#if canImport(UIKit)
import ButtonHeistTestSupport
import XCTest

@testable import AccessibilitySnapshotParser
@_spi(ButtonHeistInternals) @testable import ThePlans
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

final class HeistExecutionStepExecutionTests: XCTestCase {
    func testBareActionUsesStandardPolicyBudgetAndOneTypedRequestPipeline() throws {
        let policy = ActionExpectationTimeoutPolicy(standard: 3, screenTransition: 12)
        let plan = try HeistPlan(body: [
            .action(ActionStep(command: .dismiss)),
        ])
        var execution = try HeistExecution(
            plan: plan,
            actionExpectationTimeoutPolicy: policy
        )
        let now = ContinuousClock.now
        let observation = try XCTUnwrap(
            execution.start(at: now, timeout: .default).singleBeginObservationRequest
        )

        XCTAssertEqual(
            observation.deadline.timeoutSeconds,
            policy.standard.seconds
        )

        var driver = try HeistExecutionTestDriver(
            plan: plan,
            actionExpectationTimeoutPolicy: policy,
            script: ExecutionRunScript(events: [.noChange])
        )

        let completion = try driver.run()

        XCTAssertEqual(completion.steps.map(\.status), [.passed])
        XCTAssertEqual(driver.requests.map(\.kind), [
            .beginObservation,
            .dispatch,
            .sampleObservationClose,
            .commitObservationClose,
        ])
        XCTAssertEqual(Array(driver.history), [.noChange])
    }

    func testWaivedActionRequiresTerminalNoChangeBeforeFinishing() throws {
        let plan = try HeistPlan(body: [
            .action(ActionStep(
                command: .dismiss,
                expectationPolicy: .waived(try ActionExpectationWaiver(validating: "fixture"))
            )),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now
        let observation = try XCTUnwrap(execution.start(at: now, timeout: .default).singleBeginObservationRequest)
        let dispatch = try XCTUnwrap(execution.reduce(.observationBegan(
            observation.id,
            baseline: nil,
            at: now
        )).singleDispatchRequest)

        guard case .wait(let firstWait) = execution.reduce(.dispatchCompleted(
            dispatch.id,
            .success(payload: .dismiss),
            at: now
        )),
              case .wait(let secondWait) = execution.reduce(.observation(
                firstWait.id,
                .elementsChanged(makeTestObservationSnapshot(labels: ["Unexpected"])),
                at: now
              )) else {
            return XCTFail("A waived action must remain active until its no-change witness")
        }

        guard case .perform(.sampleObservationClose) = execution.reduce(
            .observation(secondWait.id, .noChange, at: now)
        ) else {
            return XCTFail("A no-change witness must finish the waived action")
        }
    }

    func testNoChangeOnlyActionTimeoutIsSettlementFailureAfterSuccessfulDispatch() throws {
        let policies: [ActionExpectationPolicy] = [
            .default,
            .waived(try ActionExpectationWaiver(validating: "fixture")),
        ]

        for policy in policies {
            let plan = try HeistPlan(body: [
                .action(ActionStep(command: .dismiss, expectationPolicy: policy)),
            ])
            var driver = try HeistExecutionTestDriver(plan: plan)

            let completion = try driver.run()
            let action = try XCTUnwrap(completion.steps.first)

            XCTAssertEqual(action.status, .failed)
            XCTAssertEqual(action.actionEvidence?.result?.outcome.failureKind, .timeout)
            XCTAssertEqual(action.failure?.category, .expectation)
            XCTAssertEqual(action.failure?.contract, "action settles through terminal no-change")
            XCTAssertNil(action.failure?.expected)
            XCTAssertEqual(try action.replayExpectation()?.predicate, nil)
            XCTAssertEqual(try action.replayExpectation()?.met, false)
        }
    }

    func testAuthoredActionRequiresNoChangeAfterItsAuthoredExpectation() throws {
        let plan = try HeistPlan(body: [
            .action(ActionStep(
                command: .dismiss,
                expectationPolicy: .expect(ActionExpectation(predicate: .notification("Saved")))
            )),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now
        let observation = try XCTUnwrap(execution.start(at: now, timeout: .default).singleBeginObservationRequest)
        let dispatch = try XCTUnwrap(execution.reduce(.observationBegan(
            observation.id,
            baseline: nil,
            at: now
        )).singleDispatchRequest)
        guard case .wait(let firstWait) = execution.reduce(
            .dispatchCompleted(dispatch.id, .success(payload: .dismiss), at: now)
        ) else {
            return XCTFail("A dispatched action must await its authored expectation")
        }

        guard case .wait(let terminalWait) = execution.reduce(
            .observation(firstWait.id, heistNotification("Saved"), at: now)
        ) else {
            return XCTFail("The authored expectation must still await terminal no-change")
        }
        guard case .perform(.sampleObservationClose) = execution.reduce(
            .observation(terminalWait.id, .noChange, at: now)
        ) else {
            return XCTFail("No-change after the authored expectation must finish the action")
        }
    }

    func testRuntimePolicyResolvesStandardScreenAndExplicitExpectationBudgets() throws {
        let policy = ActionExpectationTimeoutPolicy(standard: 3, screenTransition: 12)
        let explicitTimeout = try WaitTimeout.seconds(7)
        let cases: [(
            name: String,
            predicate: AccessibilityPredicate,
            timeout: ActionExpectation.Timeout,
            expected: WaitTimeout
        )] = [
            ("standard", .exists(.label("Done")), .sessionDefault, policy.standard),
            ("screen", .screenChanged, .sessionDefault, policy.screenTransition),
            ("explicit", .screenChanged, .explicit(explicitTimeout), explicitTimeout),
        ]

        for expectationCase in cases {
            let plan = try HeistPlan(body: [
                .action(ActionStep(
                    command: .dismiss,
                    expectationPolicy: .expect(ActionExpectation(
                        predicate: expectationCase.predicate,
                        timeout: expectationCase.timeout
                    ))
                )),
            ])
            var execution = try HeistExecution(
                plan: plan,
                actionExpectationTimeoutPolicy: policy
            )
            let now = ContinuousClock.now
            let observation = try XCTUnwrap(
                execution.start(at: now, timeout: .default).singleBeginObservationRequest,
                expectationCase.name
            )

            XCTAssertEqual(
                observation.deadline.timeoutSeconds,
                expectationCase.expected.seconds,
                expectationCase.name
            )
        }
    }

    func testStaleAndDuplicateDispatchCompletionsRetainTheActiveDecision() throws {
        let plan = try HeistPlan(body: [
            .action(ActionStep(command: .dismiss)),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now
        let observation = try XCTUnwrap(execution.start(at: now, timeout: .default).singleBeginObservationRequest)
        let dispatchRequest = try XCTUnwrap(
            execution.reduce(.observationBegan(
                observation.id,
                baseline: nil,
                at: now
            )).singleDispatchRequest
        )
        guard case .perform(.dispatch(let retainedDispatchID, _, _)) = execution.reduce(.observationBegan(
            observation.id,
            baseline: makeTestObservationSnapshot(labels: ["Late"]),
            at: now
        )), retainedDispatchID == dispatchRequest.id else {
            return XCTFail("A duplicate observation receipt must be ignored")
        }

        guard case .perform(.dispatch(let retainedStaleDispatchID, _, _)) = execution.reduce(.dispatchCompleted(
            HeistExecution.EffectID(rawValue: dispatchRequest.id.rawValue + 1),
            .success(payload: .dismiss),
            at: now
        )), retainedStaleDispatchID == dispatchRequest.id else {
            return XCTFail("A stale dispatch completion must be ignored")
        }
        guard case .wait(let settledWait) = execution.reduce(.dispatchCompleted(
            dispatchRequest.id,
            .success(payload: .dismiss),
            at: now
        )) else {
            return XCTFail("The admitted dispatch completion must await settlement")
        }
        guard case .wait(let retainedWait) = execution.reduce(.dispatchCompleted(
            dispatchRequest.id,
            .failure(.dismiss, message: "duplicate"),
            at: now
        )) else {
            return XCTFail("A duplicate dispatch completion must be ignored")
        }
        XCTAssertEqual(retainedWait, settledWait)
    }

    func testHostBaselineStartsActionWithoutSecondSnapshotRequest() throws {
        let plan = try HeistPlan(body: [
            .action(ActionStep(command: .dismiss)),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now
        let observation = try XCTUnwrap(execution.start(at: now, timeout: .default).singleBeginObservationRequest)
        let dispatch = try XCTUnwrap(execution.reduce(.observationBegan(
            observation.id,
            baseline: makeTestObservationSnapshot(labels: ["Before"]),
            at: now
        )).singleDispatchRequest)

        XCTAssertEqual(dispatch.id, observation.id)
    }

    func testDispatchFailureProducesFailedStepAndSkipsSibling() throws {
        let plan = try HeistPlan(body: [
            .action(ActionStep(command: .dismiss)),
            .warn(WarnStep(message: "later")),
        ])
        var driver = try HeistExecutionTestDriver(
            plan: plan,
            script: ExecutionRunScript(
                events: [.noChange],
                dispatchResults: [
                    .failure(.dismiss, message: "dismiss unavailable"),
                ]
            )
        )

        let completion = try driver.run()

        XCTAssertEqual(completion.steps.map(\.status), [.failed, .skipped])
        XCTAssertEqual(completion.steps.first?.actionEvidence?.result?.outcome.failureKind, .actionFailed)
        XCTAssertEqual(completion.steps.first(where: { $0.status == .failed })?.path, completion.steps.first?.path)
    }

    func testCancellationIsTerminalExecutionOutcome() throws {
        let plan = try HeistPlan(body: [
            .action(ActionStep(command: .dismiss)),
            .warn(WarnStep(message: "later")),
        ])
        var driver = try HeistExecutionTestDriver(
            plan: plan,
            script: ExecutionRunScript(
                waitDispositions: [.cancellationRequested]
            )
        )

        let completion = try driver.run()

        XCTAssertEqual(completion.outcome, .cancelled)
        XCTAssertTrue(completion.steps.isEmpty)
    }

    func testWarnAndFailRetainCanonicalPathsAndStatuses() throws {
        let plan = try HeistPlan(body: [
            .warn(WarnStep(message: "heads up")),
            .fail(FailStep(message: "stop")),
            .warn(WarnStep(message: "unreachable")),
        ])
        var driver = try HeistExecutionTestDriver(plan: plan)

        let completion = try driver.run()

        XCTAssertEqual(completion.steps.map(\.kind), [.warn, .fail, .warn])
        XCTAssertEqual(completion.steps.map(\.status), [.passed, .failed, .skipped])
        XCTAssertEqual(
            completion.steps.map(\.path.description),
            ["$.body[0]", "$.body[1]", "$.body[2]"]
        )
        XCTAssertEqual(completion.steps.first(where: { $0.status == .failed })?.path, completion.steps[1].path)
    }

    func testFailureScreenshotIsAHostRequestNotASecondExecutor() throws {
        let plan = try HeistPlan(body: [
            .fail(FailStep(message: "stop")),
        ])
        var execution = try HeistExecution(
            plan: plan,
            failureCaptureMode: .raw
        )
        let now = ContinuousClock.now

        guard case .perform(let request) = execution.start(at: now, timeout: .default),
              case let .captureFailureScreenshot(
                  id,
                  failedPath: failedPath,
                  mode: .raw
              ) = request else {
            return XCTFail("Failure capture must be one typed host request")
        }
        XCTAssertEqual(failedPath.description, "$.body[0]")

        let screenshot = ScreenPayload(
            pngData: "png",
            width: 1,
            height: 1
        )
        guard case .complete(let completion) = execution.reduce(
            .failureScreenshotCaptured(id, .captured(screenshot), at: now)
        ) else {
            return XCTFail("The screenshot completion must finish the same execution")
        }
        XCTAssertEqual(completion.steps.map(\.kind), [.fail])
        XCTAssertEqual(completion.steps.map(\.status), [.failed])
        XCTAssertEqual(completion.failureCapture, .captured(screenshot))
        XCTAssertEqual(completion.steps.first(where: { $0.status == .failed })?.path, completion.steps.first?.path)
    }
}

private enum ExecutionEffectKind: Equatable {
    case currentSnapshot
    case beginObservation
    case dispatch
    case explore
    case sampleObservationClose
    case commitObservationClose
    case captureFailureScreenshot
    case cancelObservation
}

struct BeginObservationRequest {
    let id: HeistExecution.EffectID
    let scope: SemanticObservationScope
    let deadline: SemanticObservationDeadline
}

struct DispatchRequest {
    let id: HeistExecution.EffectID
}

private extension HeistExecution.Effect {
    var kind: ExecutionEffectKind {
        switch self {
        case .currentSnapshot: .currentSnapshot
        case .beginObservation: .beginObservation
        case .dispatch: .dispatch
        case .explore: .explore
        case .sampleObservationClose: .sampleObservationClose
        case .commitObservationClose: .commitObservationClose
        case .captureFailureScreenshot: .captureFailureScreenshot
        case .cancelObservation: .cancelObservation
        }
    }
}

extension HeistExecution.Decision {
    var singleBeginObservationRequest: BeginObservationRequest? {
        guard case .perform(let action) = self,
              case .beginObservation(let id, let scope, let deadline) = action else {
            return nil
        }
        return BeginObservationRequest(id: id, scope: scope, deadline: deadline)
    }

    var singleDispatchRequest: DispatchRequest? {
        guard case .perform(let request) = self,
              case .dispatch(let id, _, _) = request else {
            return nil
        }
        return DispatchRequest(id: id)
    }
}

#endif // canImport(UIKit)
