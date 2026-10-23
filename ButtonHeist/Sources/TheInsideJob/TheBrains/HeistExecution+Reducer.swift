#if canImport(UIKit)
#if DEBUG
import ThePlans
@_spi(ButtonHeistInternals) import TheScore

/// Pure execution reducer for one complete heist.
internal struct HeistExecution {
    internal enum Root {
        case plan(SequenceContinuation)
        case action(ActionStep)
    }

    private enum State {
        case ready(Root)
        case running(Running)
        case awaitingFailureScreenshot(effect: Effect, children: HeistExecutedChildren)
        case cancelling(Effect)
        case complete(Completion)
    }

    internal struct Running {
        let root: Root
        var continuations: [Continuation]
        var activeLeaf: ActiveLeaf?
        var awaiting: WaitRequest?
        var pendingEffect: Effect?
        var nextEffectID: UInt64
        let executionDeadline: SemanticObservationDeadline
        var observationDeadline: SemanticObservationDeadline?
        var now: RuntimeElapsed.Instant
    }

    internal let failureCaptureMode: ScreenCaptureMode?
    internal let actionExpectationTimeoutPolicy: ActionExpectationTimeoutPolicy
    private var state: State
}

extension HeistExecution {
        internal init(
            plan: HeistPlan,
            argument: HeistArgument = .none,
            failureCaptureMode: ScreenCaptureMode? = nil,
            actionExpectationTimeoutPolicy: ActionExpectationTimeoutPolicy = .default
        ) throws {
            self.failureCaptureMode = failureCaptureMode
            self.actionExpectationTimeoutPolicy = actionExpectationTimeoutPolicy
            let environment = try HeistExecutionEnvironment.empty.binding(
                argument: argument,
                to: plan.parameter
            )
            state = .ready(.plan(.init(
                steps: plan.body,
                context: .init(
                    path: .body,
                    environment: environment,
                    scope: .init(plan: plan)
                ),
                nextIndex: 0,
                children: .empty
            )))
        }

        internal init(
            action: HeistActionCommand,
            failureCaptureMode: ScreenCaptureMode? = nil,
            actionExpectationTimeoutPolicy: ActionExpectationTimeoutPolicy = .default
        ) {
            self.failureCaptureMode = failureCaptureMode
            self.actionExpectationTimeoutPolicy = actionExpectationTimeoutPolicy
            state = .ready(.action(.init(command: action)))
        }

        internal mutating func start(
            at startedAt: RuntimeElapsed.Instant,
            timeout: HeistTimeout
        ) -> Decision {
            guard case .ready(let root) = state else { return unchangedDecision() }
            state = .running(Running(
                root: root,
                continuations: [],
                activeLeaf: nil,
                awaiting: nil,
                pendingEffect: nil,
                nextEffectID: 0,
                executionDeadline: .init(start: startedAt, timeout: .seconds(timeout.seconds)),
                observationDeadline: nil,
                now: startedAt
            ))
            switch root {
            case .plan(let sequence):
                running.continuations = [.sequence(sequence)]
                return advanceExecution()
            case .action(let action):
                return begin(action: action, path: .body.step(at: 0), environment: .empty)
            }
        }

        internal mutating func reduce(_ event: Event) -> Decision {
            if case .complete(let completion) = state {
                return .complete(completion)
            }
            if case .awaitingFailureScreenshot(let effect, let children) = state {
                if case .cancellationRequested = event {
                    return complete(steps: [], outcome: .cancelled)
                }
                guard case .failureScreenshotCaptured(_, let failureCapture, _) = event,
                      effect.admits(event) else {
                    return .perform(effect)
                }
                return complete(steps: children.values, failureCapture: failureCapture)
            }
            if case .cancelling(let effect) = state {
                guard case .cancellationCompleted = event,
                      effect.admits(event) else {
                    return .perform(effect)
                }
                return complete(steps: [], outcome: .cancelled)
            }
            guard admits(event) else { return unchangedDecision() }
            admit(event)
            switch event {
            case .deadlineElapsed:
                return reduceDeadline()
            case .cancellationRequested:
                return reduceCancellation()
            case .currentSnapshot, .observationBegan, .observation, .dispatchCompleted,
                 .explorationCompleted, .observationCloseSampled, .failureScreenshotCaptured,
                 .cancellationCompleted, .observationCloseCommitted:
                break
            }
            switch state {
            case .running(let running):
                if running.activeLeaf != nil {
                    return advanceActiveLeaf(event)
                }
                return advanceControlFlow(event)
            case .awaitingFailureScreenshot, .cancelling, .ready, .complete:
                return unchangedDecision()
            }
        }

        private mutating func unchangedDecision() -> Decision {
            switch state {
            case .ready:
                preconditionFailure("A reducer must start before it can suspend")
            case .running(let running):
                if let effect = running.pendingEffect {
                    return .perform(effect)
                }
                return wait()
            case .awaitingFailureScreenshot(let effect, _):
                return .perform(effect)
            case .cancelling(let effect):
                return .perform(effect)
            case .complete(let completion):
                return .complete(completion)
            }
        }

        internal var running: Running {
            get {
                guard case .running(let running) = state else {
                    preconditionFailure("Execution frames exist only while the reducer is running")
                }
                return running
            }
            set {
                state = .running(newValue)
            }
        }

        internal mutating func nextID() -> EffectID {
            running.nextEffectID += 1
            return EffectID(rawValue: running.nextEffectID)
        }

        internal mutating func wait() -> Decision {
            guard case .running(var running) = state else {
                return unchangedDecision()
            }
            if let awaiting = running.awaiting {
                return .wait(awaiting)
            }
            let request = WaitRequest(
                id: nextID(),
                deadline: activeDeadline
            )
            running.awaiting = request
            state = .running(running)
            return .wait(request)
        }

        private func admits(_ event: Event) -> Bool {
            guard case .running(let running) = state else {
                return false
            }
            switch event {
            case .observation(let id, _, _), .deadlineElapsed(let id, _):
                return running.awaiting?.id == id
            case .cancellationRequested:
                return true
            case .failureScreenshotCaptured, .cancellationCompleted:
                return false
            case .currentSnapshot, .observationBegan, .dispatchCompleted,
                 .explorationCompleted, .observationCloseSampled, .observationCloseCommitted:
                return running.pendingEffect?.admits(event) == true
            }
        }

        private mutating func reduceDeadline() -> Decision {
            guard case .running = state else { return unchangedDecision() }
            if let activeLeaf = running.activeLeaf {
                if let observed = activeLeaf.observed {
                    return sampleDeadlineClose(observed)
                }
                if let action = activeLeaf.action {
                    return resume(afterCompletedLeaf: HeistExecution.ResultProjector.heistTimeout(action: action))
                }
            }
            if !running.executionDeadline.hasTimeRemaining(at: running.now) {
                return finishAfterHeistTimeout()
            }
            return wait()
        }

        private mutating func reduceCancellation() -> Decision {
            let effectID = nextID()
            let effect = Effect.cancelObservation(
                effectID,
                observationID: running.activeLeaf?.id
            )
            state = .cancelling(effect)
            return .perform(effect)
        }

        internal mutating func perform(_ effect: Effect) -> Decision {
            running.pendingEffect = effect
            return .perform(effect)
        }

        private mutating func admit(_ event: Event) {
            guard case .running(var running) = state else { return }
            running.now = event.time
            running.awaiting = nil
            running.pendingEffect = nil
            state = .running(running)
        }

        internal func observationDeadline(_ timeout: Duration) -> SemanticObservationDeadline {
            .init(start: running.now, timeout: timeout)
        }

        internal var activeDeadline: SemanticObservationDeadline {
            (running.observationDeadline ?? running.executionDeadline)
                .earlier(than: running.executionDeadline)
        }

        internal mutating func finish(
            children: HeistExecutedChildren
        ) -> Decision {
            guard let failedPath = children.abortedAtPath,
                  let failureCaptureMode else {
                return complete(
                    steps: children.values
                )
            }
            let id = nextID()
            let effect = Effect.captureFailureScreenshot(
                id,
                failedPath: failedPath,
                mode: failureCaptureMode
            )
            state = .awaitingFailureScreenshot(effect: effect, children: children)
            return .perform(effect)
        }

        private mutating func complete(
            steps: [HeistExecutionStepResult],
            failureCapture: HeistFailureCapture? = nil,
            outcome: Completion.Outcome = .completed
        ) -> Decision {
            let completion = Completion(
                steps: steps,
                failureCapture: failureCapture,
                outcome: outcome
            )
            state = .complete(completion)
            return .complete(completion)
        }
}

private extension HeistExecution.Effect {
    func admits(_ event: HeistExecution.Event) -> Bool {
        switch (self, event) {
        case (.currentSnapshot(let expected, _, _), .currentSnapshot(let received, _, _)),
             (.beginObservation(let expected, _, _), .observationBegan(let received, _, _)),
             (.dispatch(let expected, _, _), .dispatchCompleted(let received, _, _)),
             (.explore(let expected, _, _), .explorationCompleted(let received, _, _)),
             (.commitObservationClose(let expected, _), .observationCloseCommitted(let received, _)),
             (.captureFailureScreenshot(let expected, _, _), .failureScreenshotCaptured(let received, _, _)),
             (.cancelObservation(let expected, _), .cancellationCompleted(let received, _)):
            expected == received
        case (
            .sampleObservationClose(let expectedRequest, let expectedObservation, _, _, let expectedSource),
            .observationCloseSampled(let receivedRequest, let receivedSource, let receivedObservation, _, _, _)
        ):
            expectedRequest == receivedRequest
                && expectedObservation == receivedObservation
                && expectedSource == receivedSource
        default:
            false
        }
    }
}

private extension HeistExecution.Event {
    var time: RuntimeElapsed.Instant {
        switch self {
        case .currentSnapshot(_, _, let time),
             .observationBegan(_, _, let time),
             .observation(_, _, let time),
             .dispatchCompleted(_, _, let time),
             .explorationCompleted(_, _, let time),
             .observationCloseSampled(_, _, _, _, _, let time),
             .failureScreenshotCaptured(_, _, let time),
             .deadlineElapsed(_, let time),
             .cancellationRequested(let time),
             .cancellationCompleted(_, let time),
             .observationCloseCommitted(_, let time):
            time
        }
    }
}

extension HeistExecution {
    internal mutating func advanceExecution() -> HeistExecution.Decision {
        guard !running.continuations.isEmpty else {
            preconditionFailure("A running execution completes when its root sequence resumes")
        }
        return advanceTopContinuation()
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
