#if canImport(UIKit)
#if DEBUG
import ButtonHeistTestSupport

@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import ThePlans
@_spi(ButtonHeistInternals) @testable import TheScore

struct ExecutionRunScript {
    var executionTimeout: HeistTimeout = .default
    var snapshots: [Observation.Snapshot?] = []
    var events: [Observation.Event] = []
    var dispatchResults: [TheSafecracker.ActionDispatchResult] = []
    var waitDispositions: [ExecutionWaitDisposition] = []
}

enum ExecutionWaitDisposition {
    case deadlineElapsed
    case cancellationRequested
    case captureUnavailable
}

struct SnapshotRequest {
    let id: HeistExecution.EffectID
    let scope: SemanticObservationScope
}

private struct ExecutionObservationStart {
    let baseline: Observation.Snapshot?
    let historyIndex: Int
}

struct HeistExecutionTestDriver {
    private(set) var execution: HeistExecution
    private(set) var history = Observation.History(retentionLimit: 256)
    private(set) var requests: [HeistExecution.Effect] = []
    private var script: ExecutionRunScript
    private var currentSnapshot: Observation.Snapshot?
    private var observationStarts: [HeistExecution.EffectID: ExecutionObservationStart] = [:]
    private var now = RuntimeElapsed.now
    private var pendingClose: HeistExecution.ObservationClose?

    init(
        plan: HeistPlan,
        argument: HeistArgument = .none,
        actionExpectationTimeoutPolicy: ActionExpectationTimeoutPolicy = .default,
        script: ExecutionRunScript = ExecutionRunScript()
    ) throws {
        execution = try HeistExecution(
            plan: plan,
            argument: argument,
            actionExpectationTimeoutPolicy: actionExpectationTimeoutPolicy
        )
        self.script = script
        currentSnapshot = nil
    }

    mutating func run(maximumTransitions: Int = 256) throws -> HeistExecution.Completion {
        var state = execution.start(at: now, timeout: script.executionTimeout)
        for _ in 0..<maximumTransitions {
            switch state {
            case .complete(let completion):
                return completion
            case .perform(let request):
                requests.append(request)
                state = try fulfill(request)
            case .wait(let request):
                if !script.events.isEmpty {
                    let event = script.events.removeFirst()
                    record(event)
                    state = execution.reduce(.observation(request.id, event, at: now))
                    continue
                }
                let disposition = nextWaitDisposition(default: .deadlineElapsed)
                switch disposition {
                case .cancellationRequested:
                    state = execution.reduce(.cancellationRequested(at: now))
                case .captureUnavailable:
                    pendingClose = .init(captureAvailable: false, viewportExit: nil, lastTreeChangeAt: nil)
                    state = execution.reduce(.observation(request.id, .noChange, at: now))
                case .deadlineElapsed:
                    now = request.deadline.start.advanced(by: .seconds(request.deadline.timeoutSeconds))
                    state = execution.reduce(.deadlineElapsed(request.id, at: now))
                }
            }
        }
        throw ExecutionDriverFailure.transitionLimitExceeded
    }

    private mutating func fulfill(
        _ request: HeistExecution.Effect
    ) throws -> HeistExecution.Decision {
        switch request {
        case .currentSnapshot(let id, _, _):
            let snapshot = nextSnapshot()
            return execution.reduce(.currentSnapshot(id, snapshot, at: now))

        case .beginObservation(let id, _, _):
            let start = ExecutionObservationStart(
                baseline: nextSnapshot(),
                historyIndex: history.endIndex
            )
            observationStarts[id] = start
            return execution.reduce(.observationBegan(id, baseline: start.baseline, at: now))

        case .dispatch(let id, let command, _):
            let result = script.dispatchResults.isEmpty
                ? .success(payload: .empty(for: command.type))
                : script.dispatchResults.removeFirst()
            return execution.reduce(.dispatchCompleted(id, result, at: now))

        case .explore(let id, _, _):
            return execution.reduce(.viewportExited(id, .retained, at: now))

        case .sampleObservationClose(
            let effectID,
            let observationID,
            _,
            let capture,
            let source
        ):
            guard let start = observationStarts[observationID] else {
                throw ExecutionDriverFailure.stalled
            }
            recordCaptureEvent(capture)
            let close = pendingClose ?? .init(
                captureAvailable: true,
                viewportExit: nil,
                lastTreeChangeAt: nil
            )
            return execution.reduce(.observationCloseSampled(
                effectID,
                source: source,
                observationID: observationID,
                evidence: evidence(since: start, captureAvailable: close.captureAvailable),
                close: close,
                at: now
            ))

        case .commitObservationClose(let id, _):
            return execution.reduce(.observationCloseCommitted(id, at: now))

        case .captureFailureScreenshot(let id, _, _):
            return execution.reduce(.failureScreenshotCaptured(
                id,
                .unavailable(kind: .actionFailed, message: "capture unavailable"),
                at: now
            ))

        case .cancelObservation(let id, _):
            return execution.reduce(.cancellationCompleted(id, at: now))
        }
    }

    private mutating func nextSnapshot() -> Observation.Snapshot? {
        if !script.snapshots.isEmpty {
            currentSnapshot = script.snapshots.removeFirst()
        }
        return currentSnapshot
    }

    private mutating func record(_ event: Observation.Event) {
        _ = history.record([event], protectedBy: nil)
        if case .elementsChanged(let snapshot) = event {
            currentSnapshot = snapshot
        }
    }

    private mutating func recordCaptureEvent(
        _ capture: HeistExecution.ObservationCloseCapture
    ) {
        switch capture {
        case .coverage:
            return
        case .refresh, .nextCycle:
            guard !script.events.isEmpty else { return }
            record(script.events.removeFirst())
        }
    }

    private func evidence(
        since start: ExecutionObservationStart,
        captureAvailable: Bool
    ) -> Observation.Evidence {
        let evidence = history.evidence(
            in: start.historyIndex..<history.endIndex,
            baseline: start.baseline,
            current: currentSnapshot
        )
        guard !captureAvailable, evidence.coverage == .complete else { return evidence }
        return .init(
            baseline: evidence.baseline,
            events: evidence.events,
            current: evidence.current,
            coverage: .incomplete(.captureUnavailable)
        )
    }

    private mutating func nextWaitDisposition(
        default defaultDisposition: ExecutionWaitDisposition
    ) -> ExecutionWaitDisposition {
        script.waitDispositions.isEmpty
            ? defaultDisposition
            : script.waitDispositions.removeFirst()
    }
}

enum ExecutionDriverFailure: Error {
    case stalled
    case transitionLimitExceeded
}

extension HeistExecution.Decision {
    var singleSnapshotRequest: SnapshotRequest? {
        guard case .perform(let request) = self,
              case .currentSnapshot(let id, let scope, _) = request else {
            return nil
        }
        return SnapshotRequest(id: id, scope: scope)
    }
}

extension HeistExecution.Effect {
    var dispatchedCommand: ResolvedHeistActionCommand? {
        guard case .dispatch(_, let command, _) = self else { return nil }
        return command
    }
}

func heistNotification(_ text: String) -> Observation.Event {
    guard let notification = Observation.Notification(text: text, element: nil) else {
        preconditionFailure("A textual notification is valid")
    }
    return .notification(notification)
}

#endif // DEBUG
#endif // canImport(UIKit)
