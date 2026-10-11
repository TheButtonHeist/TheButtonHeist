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
        switch activeLeaf {
        case .action(let leaf):
            return advance(action: leaf, event: event)
        case .wait(let leaf):
            return advance(wait: leaf, event: event)
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

extension HeistExecution {
    mutating func advance(
        action leaf: HeistExecution.ActionLeaf,
        event: HeistExecution.Event
    ) -> HeistExecution.Decision {
        var leaf = leaf
        switch event {
        case .observationBegan(let id, let baseline, _):
            guard id == leaf.id,
                  case .beginningObservation = leaf.phase else {
                return wait()
            }
            let expectation = Expectation(
                leaf.expectation.authoredPredicates,
                baseline: baseline,
                requiringNoChange: true
            )
            leaf.phase = .dispatching(expectation)
            return update(
                .action(leaf),
                performing: .dispatch(leaf.id, leaf.command, deadline: activeDeadline)
            )

        case .observation(_, let event, _):
            return observe(action: leaf, event: event)

        case .dispatchCompleted(let id, let dispatch, _):
            guard id == leaf.id,
                  case .dispatching(let expectation) = leaf.phase else {
                return wait()
            }
            return completeDispatch(
                action: leaf,
                expectation: expectation,
                dispatch: dispatch
            )

        case .viewportExited(let id, let outcome, _):
            guard id == leaf.id,
                  case .exploring(let expectation, let dispatch) = leaf.phase else {
                return wait()
            }
            switch outcome {
            case .failed:
                return finish(action: leaf, exitPosition: .current)
            case .superseded:
                guard let predicate = leaf.expectation.authoredPredicate else {
                    preconditionFailure("A superseded action discovery requires a predicate")
                }
                return update(
                    .action(leaf),
                    performing: .explore(leaf.id, predicate, deadline: activeDeadline)
                )
            case .restored, .retained:
                leaf.phase = .observing(expectation, dispatch: dispatch)
                running.activeLeaf = .action(leaf)
                return wait()
            }

        case .observationCloseSampled(
            _,
            _,
            _,
            let evidence,
            let close,
            let at
        ):
            return admitObservationCloseSample(
                action: leaf,
                evidence: evidence,
                close: close,
                at: at
            )

        case .observationCloseCommitted:
            return admitObservationCloseCommit(action: leaf)

        case .currentSnapshot, .failureScreenshotCaptured, .deadlineElapsed, .cancellationRequested, .cancellationCompleted:
            return wait()
        }
    }

    mutating func advance(
        wait leaf: HeistExecution.WaitLeaf,
        event: HeistExecution.Event
    ) -> HeistExecution.Decision {
        var leaf = leaf
        switch event {
        case .observationBegan(let id, let baseline, _):
            guard id == leaf.id,
                  case .beginningObservation = leaf.phase else {
                return wait()
            }
            if leaf.predicate.isNotification {
                leaf.phase = .observing(Expectation(
                    [leaf.predicate.resolved],
                    requiringNoChange: true
                ))
                running.activeLeaf = .wait(leaf)
                return wait()
            }
            return begin(wait: leaf, baseline: baseline)

        case .observation(_, let event, _):
            return observe(wait: leaf, event: event)

        case .viewportExited(let id, let outcome, _):
            guard id == leaf.id,
                  case .exploring(let expectation) = leaf.phase else {
                return wait()
            }
            switch outcome {
            case .failed:
                return finish(wait: leaf, exitPosition: .current)
            case .superseded:
                return update(.wait(leaf), performing: .explore(leaf.id, leaf.predicate, deadline: activeDeadline))
            case .restored, .retained:
                leaf.phase = .observing(expectation)
                running.activeLeaf = .wait(leaf)
                return wait()
            }

        case .observationCloseSampled(
            _,
            _,
            _,
            let evidence,
            let close,
            let at
        ):
            return admitObservationCloseSample(
                wait: leaf,
                evidence: evidence,
                close: close,
                at: at
            )

        case .observationCloseCommitted:
            return admitObservationCloseCommit(wait: leaf)

        case .currentSnapshot, .dispatchCompleted, .failureScreenshotCaptured, .deadlineElapsed, .cancellationRequested, .cancellationCompleted:
            return wait()
        }
    }

    mutating func admitObservationCloseSample(
        action leaf: HeistExecution.ActionLeaf,
        evidence: Observation.Evidence,
        close: HeistExecution.ObservationClose,
        at: RuntimeElapsed.Instant
    ) -> HeistExecution.Decision {
        var leaf = leaf
        guard case .finishingObservation(
            let expectation,
            let dispatch,
            let source,
            let didCaptureDeadlineStability
        ) = leaf.phase else {
            return wait()
        }
        let effectID = nextID()
        let activeLeaf = HeistExecution.ActiveLeaf.action(leaf)
        let outcome = observationOutcome(
            activeLeaf,
            source: source,
            close: close,
            evidence: evidence,
            at: at
        )
        let needsProofRefresh = source == .request
            && outcome == .completed
            && !activeLeaf.expectationIsProven(by: evidence)
        let needsDeadlineStability = source == .deadline
            && !didCaptureDeadlineStability
            && activeLeaf.needsStabilityCapture(after: evidence)
        guard !needsProofRefresh && !needsDeadlineStability else {
            leaf.phase = .finishingObservation(
                expectation: expectation,
                dispatch: dispatch,
                source: source,
                didCaptureDeadlineStability: didCaptureDeadlineStability || needsDeadlineStability
            )
            return update(
                .action(leaf),
                performing: .sampleObservationClose(
                    effectID: effectID,
                    observationID: leaf.id,
                    exitPosition: .current,
                    capture: needsDeadlineStability ? .nextCycle : .refresh,
                    source: source
                )
            )
        }
        leaf.phase = .committingObservation(
            evidence: evidence,
            timing: observationTiming(close: close, endedAt: at),
            outcome: outcome,
            dispatch: dispatch
        )
        return update(
            .action(leaf),
            performing: .commitObservationClose(effectID, observationID: leaf.id)
        )
    }

    mutating func admitObservationCloseCommit(
        action leaf: HeistExecution.ActionLeaf,
    ) -> HeistExecution.Decision {
        guard case .committingObservation(
            let evidence,
            let timing,
            let outcome,
            _
        ) = leaf.phase else {
            return wait()
        }
        return resume(afterCompletedLeaf: HeistExecution.ResultProjector.project(
            action: leaf,
            evidence: evidence,
            outcome: outcome,
            timing: timing
        ))
    }

    mutating func admitObservationCloseSample(
        wait leaf: HeistExecution.WaitLeaf,
        evidence: Observation.Evidence,
        close: HeistExecution.ObservationClose,
        at: RuntimeElapsed.Instant
    ) -> HeistExecution.Decision {
        var leaf = leaf
        guard case .finishingObservation(
            let expectation,
            let source,
            let didCaptureDeadlineStability
        ) = leaf.phase else {
            return wait()
        }
        let effectID = nextID()
        let activeLeaf = HeistExecution.ActiveLeaf.wait(leaf)
        let outcome = observationOutcome(
            activeLeaf,
            source: source,
            close: close,
            evidence: evidence,
            at: at
        )
        let needsProofRefresh = source == .request
            && outcome == .completed
            && !activeLeaf.expectationIsProven(by: evidence)
        let needsDeadlineStability = source == .deadline
            && !didCaptureDeadlineStability
            && activeLeaf.needsStabilityCapture(after: evidence)
        guard !needsProofRefresh && !needsDeadlineStability else {
            leaf.phase = .finishingObservation(
                expectation: expectation,
                source: source,
                didCaptureDeadlineStability: didCaptureDeadlineStability || needsDeadlineStability
            )
            return update(
                .wait(leaf),
                performing: .sampleObservationClose(
                    effectID: effectID,
                    observationID: leaf.id,
                    exitPosition: .current,
                    capture: needsDeadlineStability ? .nextCycle : .refresh,
                    source: source
                )
            )
        }
        leaf.phase = .committingObservation(
            evidence: evidence,
            timing: observationTiming(close: close, endedAt: at),
            outcome: outcome
        )
        return update(
            .wait(leaf),
            performing: .commitObservationClose(effectID, observationID: leaf.id)
        )
    }

    mutating func admitObservationCloseCommit(
        wait leaf: HeistExecution.WaitLeaf,
    ) -> HeistExecution.Decision {
        guard case .committingObservation(
            let evidence,
            let timing,
            let outcome
        ) = leaf.phase else {
            return wait()
        }
        let expectation = HeistExecution.ResultProjector.expectationEvidence(
            leaf.predicate,
            observation: evidence,
            outcome: outcome,
            timing: timing
        )
        switch leaf.purpose {
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

    mutating func begin(
        wait leaf: HeistExecution.WaitLeaf,
        baseline: Observation.Snapshot?
    ) -> HeistExecution.Decision {
        var leaf = leaf
        let predicateExpectation = Expectation(
            [leaf.predicate.resolved],
            baseline: baseline
        )
        let expectation = Expectation(
            [leaf.predicate.resolved],
            baseline: baseline,
            requiringNoChange: true
        )
        var canPrepareTarget = false
        if case .elementsChanged(let assertions) = leaf.predicate.resolved, assertions.count == 1 {
            switch assertions[0] {
            case .exists, .disappeared, .updated:
                canPrepareTarget = true
            case .missing, .appeared:
                break
            }
        }
        guard predicateExpectation.result != .satisfied,
              !predicateExpectation.hasMatchedTemporalBaseline,
              canPrepareTarget else {
            leaf.phase = .observing(expectation)
            running.activeLeaf = .wait(leaf)
            return wait()
        }
        leaf.phase = .exploring(expectation)
        return update(.wait(leaf), performing: .explore(leaf.id, leaf.predicate, deadline: activeDeadline))
    }

    mutating func finish(
        action leaf: HeistExecution.ActionLeaf,
        exitPosition: Navigation.ViewportExitPosition
    ) -> HeistExecution.Decision {
        beginObservationClose(
            action: leaf,
            source: .request,
            capture: .coverage,
            exitPosition: exitPosition
        )
    }

    mutating func sampleDeadlineClose(
        action leaf: HeistExecution.ActionLeaf
    ) -> HeistExecution.Decision {
        beginObservationClose(
            action: leaf,
            source: .deadline,
            capture: .nextCycle,
            exitPosition: .current
        )
    }

    mutating func beginObservationClose(
        action leaf: HeistExecution.ActionLeaf,
        source: HeistExecution.ObservationCloseSource,
        capture: HeistExecution.ObservationCloseCapture,
        exitPosition: Navigation.ViewportExitPosition
    ) -> HeistExecution.Decision {
        var leaf = leaf
        guard let expectation = leaf.phase.expectation else {
            guard source == .deadline else {
                preconditionFailure("An action expectation exists after observation begins")
            }
            return resume(afterCompletedLeaf: HeistExecution.ResultProjector.heistTimeout(action: leaf))
        }
        guard let dispatch = leaf.phase.dispatch else {
            guard source == .deadline else { return wait() }
            return resume(afterCompletedLeaf: HeistExecution.ResultProjector.heistTimeout(action: leaf))
        }
        let effectID = nextID()
        leaf.phase = .finishingObservation(
            expectation: expectation,
            dispatch: dispatch,
            source: source,
            didCaptureDeadlineStability: false
        )
        return update(
            .action(leaf),
            performing: .sampleObservationClose(
                effectID: effectID,
                observationID: leaf.id,
                exitPosition: exitPosition,
                capture: capture,
                source: source
            )
        )
    }

    mutating func observe(
        action leaf: HeistExecution.ActionLeaf,
        event: Observation.Event
    ) -> HeistExecution.Decision {
        var leaf = leaf
        switch leaf.phase {
        case .dispatching(let expectation):
            guard case .noChange = event else {
                leaf.phase = .dispatching(
                    expectation
                    .evaluating(event)
                    .requiringNoChange()
                )
                running.activeLeaf = .action(leaf)
                return wait()
            }
            return wait()
        case .observing(let current, let dispatch):
            let evaluated = expectation(
                current,
                evaluating: event
            )
            guard evaluated.result == .satisfied else {
                if leaf.expectation.authoredPredicate?.resolved.watchTarget != nil,
                   !evaluated.isWaitingOnlyForNoChange,
                   shouldExplore(after: event, for: leaf.expectation.authoredPredicate) {
                    guard let predicate = leaf.expectation.authoredPredicate else {
                        preconditionFailure("An observing action without a predicate cannot request discovery")
                    }
                    leaf.phase = .exploring(evaluated, dispatch: dispatch)
                    return update(
                        .action(leaf),
                        performing: .explore(leaf.id, predicate, deadline: activeDeadline)
                    )
                }
                leaf.phase = .observing(evaluated, dispatch: dispatch)
                running.activeLeaf = .action(leaf)
                return wait()
            }
            leaf.phase = .observing(evaluated, dispatch: dispatch)
            return finish(action: leaf, exitPosition: .current)
        case .exploring(let current, let dispatch):
            let evaluated = expectation(
                current,
                evaluating: event
            )
            leaf.phase = .exploring(evaluated, dispatch: dispatch)
            guard evaluated.result == .satisfied else {
                running.activeLeaf = .action(leaf)
                return wait()
            }
            return finish(action: leaf, exitPosition: .current)
        case .finishingObservation(let current, let dispatch, _, _):
            guard case .noChange = event else {
                leaf.phase = .observing(current, dispatch: dispatch)
                return observe(action: leaf, event: event)
            }
            return wait()
        case .committingObservation:
            return wait()
        case .beginningObservation:
            return wait()
        }
    }

    mutating func completeDispatch(
        action leaf: HeistExecution.ActionLeaf,
        expectation: Expectation,
        dispatch: TheSafecracker.ActionDispatchResult
    ) -> HeistExecution.Decision {
        var leaf = leaf
        leaf.phase = .observing(expectation, dispatch: dispatch)
        guard dispatch.success else {
            return finish(action: leaf, exitPosition: .current)
        }
        guard let predicate = leaf.expectation.authoredPredicate,
              !predicate.isNotification,
              predicate.resolved.watchTarget != nil else {
            running.activeLeaf = .action(leaf)
            return wait()
        }
        leaf.phase = .exploring(expectation, dispatch: dispatch)
        return update(
            .action(leaf),
            performing: .explore(leaf.id, predicate, deadline: activeDeadline)
        )
    }

    mutating func finish(
        wait leaf: HeistExecution.WaitLeaf,
        exitPosition: Navigation.ViewportExitPosition
    ) -> HeistExecution.Decision {
        beginObservationClose(
            wait: leaf,
            source: .request,
            capture: .coverage,
            exitPosition: exitPosition
        )
    }

    mutating func sampleDeadlineClose(
        wait leaf: HeistExecution.WaitLeaf
    ) -> HeistExecution.Decision {
        beginObservationClose(
            wait: leaf,
            source: .deadline,
            capture: .nextCycle,
            exitPosition: .current
        )
    }

    mutating func beginObservationClose(
        wait leaf: HeistExecution.WaitLeaf,
        source: HeistExecution.ObservationCloseSource,
        capture: HeistExecution.ObservationCloseCapture,
        exitPosition: Navigation.ViewportExitPosition
    ) -> HeistExecution.Decision {
        var leaf = leaf
        guard let expectation = leaf.phase.expectation else {
            guard source == .deadline else {
                preconditionFailure("A wait expectation exists after observation begins")
            }
            return wait()
        }
        let effectID = nextID()
        leaf.phase = .finishingObservation(
            expectation: expectation,
            source: source,
            didCaptureDeadlineStability: false
        )
        return update(
            .wait(leaf),
            performing: .sampleObservationClose(
                effectID: effectID,
                observationID: leaf.id,
                exitPosition: exitPosition,
                capture: capture,
                source: source
            )
        )
    }

    mutating func observe(
        wait leaf: HeistExecution.WaitLeaf,
        event: Observation.Event
    ) -> HeistExecution.Decision {
        var leaf = leaf
        switch leaf.phase {
        case .finishingObservation(let current, _, _):
            guard case .noChange = event else {
                leaf.phase = .observing(current)
                return observe(wait: leaf, event: event)
            }
            return wait()
        case .committingObservation:
            return wait()
        case .observing(let current):
            let evaluated = expectation(current, evaluating: event)
            guard evaluated.result == .satisfied else {
                if !evaluated.isWaitingOnlyForNoChange,
                   shouldExplore(after: event, for: leaf.predicate) {
                    leaf.phase = .exploring(evaluated)
                    return update(
                        .wait(leaf),
                        performing: .explore(leaf.id, leaf.predicate, deadline: activeDeadline)
                    )
                }
                leaf.phase = .observing(evaluated)
                running.activeLeaf = .wait(leaf)
                return wait()
            }
            leaf.phase = .observing(evaluated)
            return finish(wait: leaf, exitPosition: .current)
        case .exploring(let current):
            let evaluated = expectation(current, evaluating: event)
            leaf.phase = .exploring(evaluated)
            guard evaluated.result == .satisfied else {
                running.activeLeaf = .wait(leaf)
                return wait()
            }
            return finish(wait: leaf, exitPosition: .current)
        case .beginningObservation:
            return wait()
        }
    }

    mutating func update(
        _ leaf: HeistExecution.ActiveLeaf,
        performing effect: HeistExecution.Effect
    ) -> HeistExecution.Decision {
        running.activeLeaf = leaf
        return perform(effect)
    }

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
        _ leaf: HeistExecution.ActiveLeaf,
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
