#if canImport(UIKit)
#if DEBUG
import Foundation
import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension HeistExecution {
    internal static func duration(_ timeout: WaitTimeout) -> Duration {
        .milliseconds(Int64((timeout.seconds * 1_000).rounded(.up)))
    }
}

extension HeistExecution {
    internal mutating func advanceActiveLeaf(
        _ event: HeistExecution.Event
    ) -> HeistExecution.Decision {
        guard let activeLeaf = running.activeLeaf else { return wait() }
        switch (activeLeaf, event) {
        case (
            .beginningAction(let leaf),
            .observationBegan(let id, let baseline, _)
        ) where id == leaf.id:
            let expectation = Expectation(
                leaf.expectation.authoredPredicates,
                baseline: baseline,
                requiringNoChange: true
            )
            return update(
                .dispatching(leaf, expectation: expectation),
                performing: .dispatch(leaf.id, leaf.command, deadline: activeDeadline)
            )

        case (
            .beginningWait(let leaf),
            .observationBegan(let id, let baseline, _)
        ) where id == leaf.id:
            if leaf.predicate.isNotification {
                let observed = HeistExecution.ObservedLeaf(
                    subject: .wait(leaf),
                    expectation: Expectation(
                        [leaf.predicate.resolved],
                        requiringNoChange: true
                    )
                )
                running.activeLeaf = .observing(observed)
                return wait()
            }
            return begin(wait: leaf, baseline: baseline)

        case (
            .dispatching(let leaf, let expectation),
            .observation(_, let observation, _)
        ):
            guard case .noChange = observation else {
                running.activeLeaf = .dispatching(
                    leaf,
                    expectation: expectation
                        .evaluating(observation)
                        .requiringNoChange()
                )
                return wait()
            }
            return wait()

        case (
            .dispatching(let leaf, let expectation),
            .dispatchCompleted(let id, let dispatch, _)
        ) where id == leaf.id:
            return completeDispatch(
                action: leaf,
                expectation: expectation,
                dispatch: dispatch
            )

        case (.observing, .observation(_, let observation, _)),
             (.exploring, .observation(_, let observation, _)),
             (.finishing, .observation(_, let observation, _)):
            return observe(activeLeaf, event: observation)

        case (
            .exploring(let leaf),
            .viewportExited(let id, let outcome, _)
        ) where id == leaf.id:
            return admitViewportExit(leaf, outcome: outcome)

        case (
            .finishing(let leaf, let source, let didCaptureDeadlineStability),
            .observationCloseSampled(_, _, _, let evidence, let close, let at)
        ):
            return admitObservationCloseSample(
                leaf,
                source: source,
                didCaptureDeadlineStability: didCaptureDeadlineStability,
                evidence: evidence,
                close: close,
                at: at
            )

        case (
            .committing(let leaf, let evidence, let timing, let outcome),
            .observationCloseCommitted
        ):
            return admitObservationCloseCommit(
                leaf,
                evidence: evidence,
                timing: timing,
                outcome: outcome
            )

        case (.beginningAction, _),
             (.dispatching, _),
             (.beginningWait, _),
             (.observing, _),
             (.exploring, _),
             (.finishing, _),
             (.committing, _):
            return wait()
        }
    }

    /// Rejoins the authored sequence after either an observed leaf or a
    /// synchronous leaf-admission failure.
    internal mutating func resume(
        afterCompletedLeaf result: HeistExecutionStepResult
    ) -> HeistExecution.Decision {
        running.activeLeaf = nil
        if case .sequence(var sequence)? = running.continuations.last {
            running.continuations.removeLast()
            sequence.children.append(result)
            running.continuations.append(.sequence(sequence))
            return advanceExecution()
        }
        guard running.continuations.isEmpty, case .action = running.root else {
            preconditionFailure("A completed plan leaf requires an active sequence")
        }
        return finish(children: HeistPassingChildren.empty.appending(result))
    }
}

private extension HeistExecution.ObservedLeaf {
    var explorationPredicate: HeistExecution.Predicate? {
        switch subject {
        case .action(let leaf, _):
            guard let predicate = leaf.expectation.authoredPredicate,
                  !predicate.isNotification,
                  predicate.resolved.watchTarget != nil else {
                return nil
            }
            return predicate
        case .wait(let leaf):
            return leaf.predicate
        }
    }
}

extension HeistExecution {
    mutating func begin(
        wait leaf: HeistExecution.WaitLeaf,
        baseline: Observation.Snapshot?
    ) -> HeistExecution.Decision {
        let predicateExpectation = Expectation(
            [leaf.predicate.resolved],
            baseline: baseline
        )
        let observed = HeistExecution.ObservedLeaf(
            subject: .wait(leaf),
            expectation: Expectation(
                [leaf.predicate.resolved],
                baseline: baseline,
                requiringNoChange: true
            )
        )
        var canPrepareTarget = false
        if case .elementsChanged(let assertions) = leaf.predicate.resolved, assertions.count == 1 {
            switch assertions[0] {
            case .exists, .disappeared, .updated:
                canPrepareTarget = true
            case .missing:
                canPrepareTarget = baseline != nil
            case .appeared:
                break
            }
        }
        guard predicateExpectation.result != .satisfied,
              !predicateExpectation.hasMatchedTemporalBaseline,
              canPrepareTarget else {
            running.activeLeaf = .observing(observed)
            return wait()
        }
        return update(
            .exploring(observed),
            performing: .explore(leaf.id, leaf.predicate, deadline: activeDeadline)
        )
    }

    mutating func completeDispatch(
        action leaf: HeistExecution.ActionLeaf,
        expectation: Expectation,
        dispatch: TheSafecracker.ActionDispatchResult
    ) -> HeistExecution.Decision {
        let observed = HeistExecution.ObservedLeaf(
            subject: .action(leaf, dispatch: dispatch),
            expectation: expectation
        )
        guard dispatch.success else {
            return finish(observed, exitPosition: .current)
        }
        guard let predicate = observed.explorationPredicate else {
            running.activeLeaf = .observing(observed)
            return wait()
        }
        return update(
            .exploring(observed),
            performing: .explore(leaf.id, predicate, deadline: activeDeadline)
        )
    }

    mutating func admitViewportExit(
        _ leaf: HeistExecution.ObservedLeaf,
        outcome: Navigation.ViewportExit.Outcome
    ) -> HeistExecution.Decision {
        switch outcome {
        case .failed:
            return finish(leaf, exitPosition: .current)
        case .superseded:
            guard let predicate = leaf.explorationPredicate else {
                preconditionFailure("A superseded discovery requires an observation predicate")
            }
            return update(
                .exploring(leaf),
                performing: .explore(leaf.id, predicate, deadline: activeDeadline)
            )
        case .restored, .retained:
            running.activeLeaf = .observing(leaf)
            return wait()
        }
    }
}

extension HeistExecution {
    mutating func observe(
        _ activeLeaf: HeistExecution.ActiveLeaf,
        event: Observation.Event
    ) -> HeistExecution.Decision {
        switch activeLeaf {
        case .observing(var leaf):
            leaf.expectation = expectation(leaf.expectation, evaluating: event)
            guard leaf.expectation.result == .satisfied else {
                if !leaf.expectation.isWaitingOnlyForNoChange,
                   shouldExplore(after: event, for: leaf.explorationPredicate),
                   let predicate = leaf.explorationPredicate {
                    return update(
                        .exploring(leaf),
                        performing: .explore(leaf.id, predicate, deadline: activeDeadline)
                    )
                }
                running.activeLeaf = .observing(leaf)
                return wait()
            }
            return finish(leaf, exitPosition: .current)

        case .exploring(var leaf):
            leaf.expectation = expectation(leaf.expectation, evaluating: event)
            guard leaf.expectation.result == .satisfied else {
                running.activeLeaf = .exploring(leaf)
                return wait()
            }
            return finish(leaf, exitPosition: .current)

        case .finishing(let leaf, _, _):
            guard case .noChange = event else {
                return observe(.observing(leaf), event: event)
            }
            return wait()

        case .beginningAction,
             .dispatching,
             .beginningWait,
             .committing:
            return wait()
        }
    }

    mutating func finish(
        _ leaf: HeistExecution.ObservedLeaf,
        exitPosition: Navigation.ViewportExitPosition
    ) -> HeistExecution.Decision {
        beginObservationClose(
            leaf,
            source: .request,
            capture: .coverage,
            exitPosition: exitPosition
        )
    }

    mutating func sampleDeadlineClose(
        _ leaf: HeistExecution.ObservedLeaf
    ) -> HeistExecution.Decision {
        beginObservationClose(
            leaf,
            source: .deadline,
            capture: .nextCycle,
            exitPosition: .current
        )
    }

    mutating func beginObservationClose(
        _ leaf: HeistExecution.ObservedLeaf,
        source: HeistExecution.ObservationCloseSource,
        capture: HeistExecution.ObservationCloseCapture,
        exitPosition: Navigation.ViewportExitPosition
    ) -> HeistExecution.Decision {
        let effectID = nextID()
        return update(
            .finishing(
                leaf,
                source: source,
                didCaptureDeadlineStability: false
            ),
            performing: .sampleObservationClose(
                effectID: effectID,
                observationID: leaf.id,
                exitPosition: exitPosition,
                capture: capture,
                source: source
            )
        )
    }

    mutating func admitObservationCloseSample(
        _ leaf: HeistExecution.ObservedLeaf,
        source: HeistExecution.ObservationCloseSource,
        didCaptureDeadlineStability: Bool,
        evidence: Observation.Evidence,
        close: HeistExecution.ObservationClose,
        at: RuntimeElapsed.Instant
    ) -> HeistExecution.Decision {
        let effectID = nextID()
        let outcome = observationOutcome(
            leaf,
            source: source,
            close: close,
            evidence: evidence,
            at: at
        )
        let needsProofRefresh = source == .request
            && outcome == .completed
            && !leaf.expectationIsProven(by: evidence)
        let needsDeadlineStability = source == .deadline
            && !didCaptureDeadlineStability
            && leaf.needsStabilityCapture(after: evidence)
        guard !needsProofRefresh && !needsDeadlineStability else {
            return update(
                .finishing(
                    leaf,
                    source: source,
                    didCaptureDeadlineStability: didCaptureDeadlineStability || needsDeadlineStability
                ),
                performing: .sampleObservationClose(
                    effectID: effectID,
                    observationID: leaf.id,
                    exitPosition: .current,
                    capture: needsDeadlineStability ? .nextCycle : .refresh,
                    source: source
                )
            )
        }
        return update(
            .committing(
                leaf,
                evidence: evidence,
                timing: observationTiming(close: close, endedAt: at),
                outcome: outcome
            ),
            performing: .commitObservationClose(effectID, observationID: leaf.id)
        )
    }

    mutating func admitObservationCloseCommit(
        _ leaf: HeistExecution.ObservedLeaf,
        evidence: Observation.Evidence,
        timing: HeistExpectationTiming,
        outcome: HeistExecution.LeafOutcome
    ) -> HeistExecution.Decision {
        switch leaf.subject {
        case .action(let action, let dispatch):
            return resume(afterCompletedLeaf: HeistExecution.ResultProjector.project(
                action: action,
                dispatch: dispatch,
                evidence: evidence,
                outcome: outcome,
                timing: timing
            ))
        case .wait(let wait):
            let expectation = HeistExecution.ResultProjector.expectationEvidence(
                wait.predicate,
                observation: evidence,
                outcome: outcome,
                timing: timing
            )
            switch wait.purpose {
            case .repeatCheck(let loop, let bodyChildren):
                return resumeRepeatCheck(
                    loop,
                    bodyChildren: bodyChildren,
                    expectation: expectation
                )
            case .authored(let step, let context):
                return resumeAuthoredWait(
                    step: step,
                    context: context,
                    expectation: expectation,
                    outcome: outcome
                )
            }
        }
    }

    mutating func update(
        _ leaf: HeistExecution.ActiveLeaf,
        performing effect: HeistExecution.Effect
    ) -> HeistExecution.Decision {
        running.activeLeaf = leaf
        return perform(effect)
    }
}

extension HeistExecution {
    mutating func resumeAuthoredWait(
        step: WaitStep,
        context: HeistExecution.StepContext,
        expectation: HeistExpectationEvidence,
        outcome: HeistExecution.LeafOutcome
    ) -> HeistExecution.Decision {
        let result = HeistExecution.ResultProjector.project(
            wait: step,
            path: context.path,
            expectation: expectation,
            outcome: outcome
        )
        guard outcome == .timedOut,
              let evidence = result.waitEvidence,
              let fallbackEvidence = HeistPassedWaitEvidence(evidence),
              fallbackEvidence.usesFallback,
              let elseBody = step.elseBody else {
            return resume(afterCompletedLeaf: result)
        }
        running.activeLeaf = nil
        running.continuations.append(.waitElse(HeistExecution.WaitElseContinuation(
            step: step,
            context: context,
            evidence: fallbackEvidence
        )))
        running.continuations.append(.sequence(HeistExecution.SequenceContinuation(
            steps: elseBody,
            context: HeistExecution.StepContext(
                path: context.path.waitElseBody(),
                environment: context.environment,
                scope: context.scope
            ),
            nextIndex: 0,
            children: .empty
        )))
        return advanceExecution()
    }
}

private extension HeistExecution {
    func shouldExplore(
        after event: Observation.Event,
        for predicate: HeistExecution.Predicate?
    ) -> Bool {
        guard let predicate,
              case .elementsChanged = predicate.resolved else {
            return false
        }
        if case .noChange = event { return false }
        return true
    }

    func expectation(
        _ expectation: Expectation,
        evaluating event: Observation.Event
    ) -> Expectation {
        let evaluated = expectation.evaluating(event)
        guard case .noChange = event else {
            return evaluated.requiringNoChange()
        }
        return evaluated
    }

    func observationOutcome(
        _ leaf: HeistExecution.ObservedLeaf,
        source: HeistExecution.ObservationCloseSource,
        close: HeistExecution.ObservationClose,
        evidence: Observation.Evidence,
        at: RuntimeElapsed.Instant
    ) -> HeistExecution.LeafOutcome {
        if case .failed(let failure)? = close.viewportExit {
            return .viewportExitFailed(failure)
        }
        if case .request = source,
           close.captureAvailable,
           leaf.expectationIsProven(by: evidence) {
            return .completed
        }
        guard close.captureAvailable || evidence.baseline != nil || evidence.current != nil else {
            return .unavailable
        }
        guard running.executionDeadline.hasTimeRemaining(at: at) else {
            return .heistTimedOut
        }
        guard running.observationDeadline?.hasTimeRemaining(at: at) != false else {
            return .timedOut
        }
        return .completed
    }

    func observationTiming(
        close: HeistExecution.ObservationClose,
        endedAt: RuntimeElapsed.Instant
    ) -> HeistExpectationTiming {
        let deadline = running.observationDeadline ?? running.executionDeadline
        return .init(
            budgetMs: RuntimeElapsed.admit(milliseconds: deadline.budgetMilliseconds),
            elapsedMs: RuntimeElapsed.milliseconds(since: deadline.start, endedAt: endedAt),
            lastTreeChangeElapsedMs: close.lastTreeChangeAt.map {
                RuntimeElapsed.milliseconds(since: deadline.start, endedAt: $0)
            }
        )
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
