#if canImport(UIKit)
#if DEBUG
import ButtonHeistTestSupport
import Foundation
import XCTest

@testable import AccessibilitySnapshotParser
@_spi(ButtonHeistInternals) @testable import ThePlans
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

final class HeistExecutionTests: XCTestCase {
    func testExecutionAdmitsLargestFiniteWholeHeistTimeout() throws {
        let plan = try HeistPlan(body: [.wait(WaitStep(predicate: .notification("Saved"), timeout: 1))])
        var execution = try HeistExecution(plan: plan)
        let timeout = try HeistTimeout(validatingSeconds: .greatestFiniteMagnitude)

        guard case .perform(.beginObservation(_, _, let deadline)) = execution.start(at: .now, timeout: timeout) else {
            return XCTFail("A large whole-heist timeout must still begin observation")
        }
        XCTAssertTrue(deadline.hasTimeRemaining(at: .now))
    }
    func testExecutionEmitsEffectsWaitsAndCompletes() throws {
        let plan = try HeistPlan(body: [
            .wait(WaitStep(
                predicate: .notification("Saved"),
                timeout: try .seconds(1)
            )),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now

        guard case .perform(let request) = execution.start(at: now, timeout: .default),
              case .beginObservation = request else {
            return XCTFail("A wait must begin one observation")
        }

        guard case .wait = execution.reduce(.observationBegan(
            HeistExecution.EffectID(rawValue: 1),
            baseline: nil,
            at: now
        )) else {
            return XCTFail("An observed wait must suspend for events")
        }
    }

    func testDeadlineDuringObservationStartCannotCompleteWait() throws {
        let plan = try HeistPlan(body: [
            .wait(WaitStep(
                predicate: .missing(.label("Target")),
                timeout: try .seconds(1)
            )),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now
        guard case .perform(.beginObservation(let observationID, _, _)) = execution.start(
            at: now,
            timeout: .default
        ),
              case .wait(let wait) = execution.reduce(
                  .observationBegan(observationID, baseline: nil, at: now)
              ),
              case .perform(.sampleObservationClose(
                  let closeID,
                  let closedObservationID,
                  _,
                  _,
                  let closeSource
              )) = execution.reduce(
                  .deadlineElapsed(wait.id, at: now.advanced(by: .seconds(1)))
              ), closedObservationID == observationID else {
            return XCTFail("A deadline must sample evidence for the active wait")
        }
        let evidence = Observation.History(retentionLimit: 1).evidence(
            in: 0..<0,
            baseline: nil,
            current: nil
        )

        guard case .perform(.commitObservationClose(let commitID, let committedObservationID)) = execution.reduce(.observationCloseSampled(
                  closeID,
                  source: closeSource,
                  observationID: observationID,
                  evidence: evidence,
                  close: .init(captureAvailable: true, viewportExit: nil, lastTreeChangeAt: nil),
                  at: now.advanced(by: .seconds(1))
              )), committedObservationID == observationID,
              case .complete(let completion) = execution.reduce(
                  .observationCloseCommitted(commitID, at: now.advanced(by: .seconds(1)))
              ) else {
            return XCTFail("An uninitialized expectation must remain unmet at its deadline")
        }
        XCTAssertEqual(completion.steps.first?.status, .failed)
    }

    func testStaleRequestCompletionDoesNotAdvanceExecution() throws {
        let plan = try HeistPlan(body: [
            .conditional(try ConditionalStep(cases: [
                PredicateCase(
                    predicate: .exists(.label("Home")),
                    body: [.warn(WarnStep(message: "selected"))]
                ),
            ])),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now
        let state = execution.start(at: now, timeout: .default)
        let request = try XCTUnwrap(state.singleSnapshotRequest)

        guard case .perform(.currentSnapshot(let retainedID, _, _)) = execution.reduce(.currentSnapshot(
            HeistExecution.EffectID(rawValue: request.id.rawValue + 1),
            makeTestObservationSnapshot(labels: ["Home"]),
            at: now
        )), retainedID == request.id else {
            return XCTFail("A stale snapshot must retain the pending effect")
        }

        guard case .complete(let completion) = execution.reduce(.currentSnapshot(
            request.id,
            makeTestObservationSnapshot(labels: ["Home"]),
            at: now
        )) else {
            return XCTFail("The admitted snapshot must complete the conditional")
        }
        XCTAssertEqual(completion.steps.first?.status, .passed)
    }

    func testCompletedExecutionIgnoresLateInput() throws {
        let plan = try HeistPlan(body: [
            .warn(WarnStep(message: "done")),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now
        guard case .complete(let completion) = execution.start(at: now, timeout: .default) else {
            return XCTFail("A warning-only plan must complete synchronously")
        }
        XCTAssertEqual(completion.steps.map(\.path), ["$.body[0]"])
        XCTAssertEqual(completion.steps.map(\.kind), [.warn])
        XCTAssertEqual(completion.steps.map(\.reportMessage), ["done"])
        XCTAssertNil(completion.steps.first(where: { $0.status == .failed }))

        guard case .complete(let lateCompletion) = execution.reduce(
            .cancellationRequested(at: now)
        ) else {
            return XCTFail("Late input must not reopen a completed execution")
        }
        XCTAssertEqual(lateCompletion.steps, completion.steps)
        XCTAssertEqual(lateCompletion.steps.first(where: { $0.status == .failed })?.path,
                       completion.steps.first(where: { $0.status == .failed })?.path)
    }

    func testElementWaitRestartsDiscoveryAfterScreenReplacementAndSubstantiveEvents() throws {
        let plan = try HeistPlan(body: [
            .wait(WaitStep(
                predicate: .exists(.label("Target")),
                timeout: try .seconds(1)
            )),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now

        guard case .perform(.beginObservation(let id, _, _)) = execution.start(
            at: now,
            timeout: .default
        ) else {
            return XCTFail("The wait must begin one observation")
        }
        guard case .perform(let firstExploration) = execution.reduce(
            .observationBegan(id, baseline: makeTestObservationSnapshot(labels: []), at: now)
        ),
              case .explore(id, _, _) = firstExploration else {
            return XCTFail("An unresolved element wait must explore")
        }

        guard case .perform(let restartedExploration) = execution.reduce(
            .explorationCompleted(id, .init(viewportExit: .superseded, coverage: .complete), at: now)
        ),
              case .explore(id, _, _) = restartedExploration else {
            return XCTFail("A screen replacement must restart the unfinished discovery")
        }
        guard case .wait(let firstWait) = execution.reduce(.explorationCompleted(id, .init(viewportExit: .restored, coverage: .complete), at: now)) else {
            return XCTFail("A completed unmatched discovery must wait for new evidence")
        }

        guard case .perform(let eventExploration) = execution.reduce(
            .observation(firstWait.id, .elementsChanged(makeTestObservationSnapshot(labels: ["Other"])), at: now)
        ),
              case .explore(id, _, _) = eventExploration else {
            return XCTFail("A substantive unmatched event must request one new discovery")
        }
        guard case .wait(let secondWait) = execution.reduce(.explorationCompleted(id, .init(viewportExit: .restored, coverage: .complete), at: now)) else {
            return XCTFail("The second completed discovery must return to waiting")
        }
        guard case .wait = execution.reduce(.observation(secondWait.id, .noChange, at: now)) else {
            return XCTFail("Stillness must not start another discovery")
        }
    }

    func testVisiblePresenceWaitsForRemovalWithoutPreparingRememberedTarget() throws {
        let plan = try HeistPlan(body: [
            .wait(WaitStep(predicate: .missing(.label("Target")), timeout: 1)),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now
        guard case .perform(.beginObservation(let id, _, _)) = execution.start(at: now, timeout: .default),
              case .wait = execution.reduce(.observationBegan(
                  id, baseline: makeTestObservationSnapshot(labels: ["Target"]), at: now
              )) else {
            return XCTFail("Fresh visible presence needs observation, not a remembered-target search")
        }
    }

    func testActionObservesFreshVisibleRemovalWithoutSearchingDepartureSnapshots() throws {
        let plan = try HeistPlan(body: [
            .action(ActionStep(
                command: .dismiss,
                expectationPolicy: .expect(ActionExpectation(predicate: .missing(.label("Title")), timeout: 1))
            )),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now
        let baseline = makeTestObservationSnapshot(labels: ["Title"])
        guard case .perform(.beginObservation(let id, _, _)) = execution.start(at: now, timeout: .default),
              case .perform(.dispatch) = execution.reduce(.observationBegan(id, baseline: baseline, at: now)),
              case .wait(let wait) = execution.reduce(.dispatchCompleted(id, .success(payload: .dismiss), at: now)),
              case .wait = execution.reduce(.observation(wait.id, .elementsChanged(baseline), at: now)),
              case .wait = execution.reduce(.observation(
                  wait.id, .elementsChanged(makeTestObservationSnapshot(labels: [])), at: now
              )) else {
            return XCTFail("Captured presence must observe removal without searching the departing or replacement screen")
        }
        guard case .perform(.sampleObservationClose) = execution.reduce(.observation(wait.id, .noChange, at: now)) else {
            return XCTFail("Fresh absence followed by stillness must complete the action")
        }
    }

    func testFreshExistenceCanCompleteAfterAnEarlierLimitedSearch() throws {
        let plan = try HeistPlan(body: [
            .wait(WaitStep(predicate: .exists(.label("Target")), timeout: 1)),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now
        guard case .perform(.beginObservation(let id, _, _)) = execution.start(at: now, timeout: .default),
              case .perform(.explore) = execution.reduce(.observationBegan(
                  id, baseline: makeTestObservationSnapshot(labels: []), at: now
              )),
              case .wait(let wait) = execution.reduce(.explorationCompleted(
                  id, .init(viewportExit: .restored, coverage: .incomplete(.explorationIncomplete)), at: now
              )),
              case .wait = execution.reduce(.observation(
                  wait.id, .elementsChanged(makeTestObservationSnapshot(labels: ["Target"])), at: now
              )) else {
            return XCTFail("The wait must admit a fresh sighting after limited exploration")
        }

        guard case .perform(.sampleObservationClose) = execution.reduce(
            .observation(wait.id, .noChange, at: now)
        ) else {
            return XCTFail("Positive capture evidence does not require exhaustive exploration")
        }
    }

    func testCurrentVisibleTruthSatisfiesWaitBeforeDiscovery() throws {
        let plan = try HeistPlan(body: [
            .wait(WaitStep(
                predicate: .exists(.label("Target")),
                timeout: try .seconds(1)
            )),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now
        guard case .perform(.beginObservation(let id, _, _)) = execution.start(
            at: now,
            timeout: .default
        ) else {
            return XCTFail("The wait must begin one observation")
        }
        guard case .wait(let wait) = execution.reduce(.observationBegan(
            id,
            baseline: makeTestObservationSnapshot(labels: ["Target"]),
            at: now
        )) else {
            return XCTFail("Current visible truth must satisfy existence without discovery")
        }
        guard case .perform(.sampleObservationClose(_, let observationID, _, _, _)) = execution.reduce(
            .observation(wait.id, .noChange, at: now)
        ), observationID == id else {
            return XCTFail("Settled current truth must finish the wait")
        }
    }

    func testDispatchesEveryDurableActionCommandThroughTypedRequests() throws {
        let target = AccessibilityTarget.identifier("target")
        let point = GesturePointSelection.coordinate(ScreenPoint(x: 10, y: 20))
        let commands: [HeistActionCommand] = [
            .activate(target),
            .increment(target),
            .decrement(target),
            .customAction(name: "Archive", target: target),
            .rotor(selection: .named("Errors"), target: target, direction: .next),
            .typeText(text: "hello", target: target),
            .oneFingerTap(TapTarget(selection: point)),
            .longPress(LongPressTarget(selection: point)),
            .swipe(SwipeTarget(selection: .pointDirection(
                start: ScreenPoint(x: 20, y: 20),
                direction: .left
            ))),
            .drag(DragTarget(
                start: .coordinate(ScreenPoint(x: 20, y: 20)),
                end: ScreenPoint(x: 80, y: 80)
            )),
            .editAction(EditActionTarget(action: .paste)),
            .setPasteboard(SetPasteboardTarget(text: "clipboard")),
            .takeScreenshot,
            .dismissKeyboard,
        ]
        let plan = try HeistPlan(body: commands.map { .action(ActionStep(command: $0)) })
        var driver = try HeistExecutionTestDriver(
            plan: plan,
            script: ExecutionRunScript(
                events: Array(repeating: [.noChange, .noChange], count: commands.count)
                    .flatMap { $0 }
            )
        )

        let completion = try driver.run()

        let expectedCommands = try commands.map { try $0.resolve(in: .empty) }
        XCTAssertEqual(driver.requests.compactMap(\.dispatchedCommand), expectedCommands)
        XCTAssertEqual(completion.steps.count, commands.count)
        XCTAssertTrue(completion.steps.allSatisfy { $0.status == .passed })
    }

    func testDirectScrollUsesTheActionPipelineWithoutDurablePlanAdmission() throws {
        var execution = HeistExecution(action: .scroll(.init()))
        let now = ContinuousClock.now
        guard case .perform(.beginObservation(let observationID, _, _)) = execution.start(
            at: now,
            timeout: .default
        ),
              case .perform(.dispatch(let dispatchID, _, _)) = execution.reduce(
                .observationBegan(observationID, baseline: nil, at: now)
              ),
              dispatchID == observationID,
              case .perform(.sampleObservationClose(let closeID, let finishedObservationID, _, _, _)) = execution.reduce(
                .dispatchCompleted(
                    dispatchID,
                    .failure(
                        .empty(for: .scroll),
                        message: "scroll dispatch failed",
                        failureKind: .actionFailed
                    ),
                    at: now
                )
              ),
              finishedObservationID == observationID,
              case .perform(.commitObservationClose(let commitID, let committedObservationID)) = execution.reduce(.observationCloseSampled(
                closeID,
                source: .request,
                observationID: observationID,
                evidence: .init(
                    baseline: nil,
                    events: [],
                    current: nil,
                    coverage: .incomplete(.captureUnavailable)
                ),
                close: .init(captureAvailable: false, viewportExit: nil, lastTreeChangeAt: nil),
                at: now
              )), committedObservationID == observationID,
              case .complete(let completion) = execution.reduce(
                .observationCloseCommitted(commitID, at: now)
              )
        else {
            return XCTFail("A direct scroll must complete through the action reducer")
        }
        XCTAssertEqual(completion.steps.count, 1)
        XCTAssertEqual(completion.steps.first?.status, .failed)
    }

    func testFailedActivateKeepsActivationTraceInActionEvidence() throws {
        let activationTrace = ActivationTrace(.activationPointFallback(
            axActivateReturned: false,
            tapActivationPoint: ScreenPoint(x: 195, y: 139),
            tapActivationSucceeded: true
        ), implementsAccessibilityActivation: false)
        let target = AccessibilityTarget.label("Search all items")
        let command = HeistActionCommand.activate(target)
        let plan = try HeistPlan(body: [.action(ActionStep(command: command))])
        var driver = try HeistExecutionTestDriver(
            plan: plan,
            script: ExecutionRunScript(
                events: [.noChange],
                dispatchResults: [
                    .failure(
                        .activate,
                        message: "text entry failed: observed focus=none "
                            + "keyboardVisible=false activeTextInput=false",
                        activationTrace: activationTrace
                    ),
                ]
            )
        )

        let completion = try driver.run()
        let step = try XCTUnwrap(completion.steps.first)

        XCTAssertEqual(step.status, .failed)
        XCTAssertEqual(step.actionEvidence?.result?.activationTrace, activationTrace)
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
