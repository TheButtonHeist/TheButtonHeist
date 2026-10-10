#if canImport(UIKit)
#if DEBUG
import ButtonHeistSupport
import Foundation
import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension HeistExecution {
    @MainActor
    internal final class Host {
        internal struct RuntimeBoundary {
            let now: @MainActor () -> RuntimeElapsed.Instant
            let wait: @MainActor (Duration) async -> Bool
            let dispatch: @MainActor (ResolvedHeistActionCommand, SemanticObservationDeadline) async -> TheSafecracker.ActionDispatchResult
            let explore: @MainActor (ResolvedAccessibilityTarget?, SemanticObservationDeadline) async -> Navigation.ViewportExit.Outcome
            let captureFailure: @MainActor (HeistExecutionPath, ScreenCaptureMode) async -> HeistFailureCapture

            static func live(brains: TheBrains) -> Self {
                .init(
                    now: { RuntimeElapsed.now },
                    wait: { await Task.cancellableSleep(for: $0) },
                    dispatch: { await brains.dispatchRuntimeAction($0, deadline: $1) },
                    explore: { target, deadline in
                        await brains.navigation.exploreForWait(target: target, deadline: deadline, stopWhen: { false })
                    },
                    captureFailure: { _, mode in
                        switch await brains.captureScreenPayload(mode: mode, observationBoundary: .cancellableObservationCycle) {
                        case .success(let payload): .captured(payload)
                        case .failure(let failure): .unavailable(kind: failure.actionFailureKind, message: failure.message)
                        }
                    }
                )
            }
        }

        private struct Lifetime {
            let subscription: SemanticObservationLease<UInt64>
            let demand: SemanticObservationLease<Void>
            let notifications: AccessibilityNotificationScopeLease
        }

        private struct ObservationResource {
            let id: RequestID
            let boundary: TheVault.State.HistoryBoundary
            let subscription: SemanticObservationLease<UInt64>
            let notifications: AccessibilityNotificationScopeLease
            let deadline: SemanticObservationDeadline
            var lastTreeChangeAt: RuntimeElapsed.Instant?
        }

        private struct Runtime {
            var execution: HeistExecution
            var observation: ObservationResource?
            var historyIndex: Int
        }

        private let brains: TheBrains
        private let runtimeBoundary: RuntimeBoundary

        internal init(brains: TheBrains, runtimeBoundary: RuntimeBoundary? = nil) {
            self.brains = brains
            self.runtimeBoundary = runtimeBoundary ?? .live(brains: brains)
        }

        internal func execute(
            _ plan: HeistPlan,
            argument: HeistArgument = .none,
            timeout: HeistTimeout,
            actionExpectationTimeoutPolicy: ActionExpectationTimeoutPolicy = .default
        ) async throws -> Completion {
            try await execute(
                try HeistExecution(
                    plan: plan,
                    argument: argument,
                    failureCaptureMode: brains.failureEvidencePolicy.captureMode,
                    actionExpectationTimeoutPolicy: actionExpectationTimeoutPolicy
                ),
                timeout: timeout
            )
        }

        internal func execute(_ action: HeistActionCommand, timeout: HeistTimeout) async throws -> Completion {
            try await execute(
                HeistExecution(action: action, failureCaptureMode: brains.failureEvidencePolicy.captureMode),
                timeout: timeout
            )
        }

        private func execute(_ execution: HeistExecution, timeout: HeistTimeout) async throws -> Completion {
            let stream = brains.vault.semanticObservationStream
            let inbox = ObservationInbox(waitUntilDeadline: runtimeBoundary.wait)
            guard let admission = stream.admitExecutionBoundary(receive: { inbox.yield($0) }) else {
                try Task.checkCancellation()
                throw Failure.runtimeUnavailable
            }
            let lifetime = Lifetime(
                subscription: admission.subscription,
                demand: admission.demand,
                notifications: brains.vault.accessibilityNotifications.beginHeistScope()
            )
            var runtime = Runtime(execution: execution, observation: nil, historyIndex: admission.retainedHistoryIndex)
            defer { release(lifetime, runtime: &runtime) }

            var baseline: Observation.Stream.ExecutionAdmission? = admission
            var decision = runtime.execution.start(at: runtimeBoundary.now(), timeout: timeout)
            while true {
                switch decision {
                case .complete(let completion):
                    if completion.outcome == .cancelled {
                        throw CancellationError()
                    }
                    let cursor = brains.vault.accessibilityNotifications.cursor()
                    guard await admitTerminalNotifications(lifetime.notifications, after: cursor) else {
                        throw Failure.accessibilityTreeUnavailable
                    }
                    return completion

                case .perform(let effect):
                    guard !Task.isCancelled || isCancellationCleanup(effect) else {
                        decision = runtime.execution.reduce(.cancellationRequested(at: runtimeBoundary.now()))
                        continue
                    }
                    let event = await execute(
                        effect,
                        runtime: &runtime,
                        baseline: &baseline,
                        inbox: inbox
                    )
                    decision = Task.isCancelled && !isCancellationCleanup(effect)
                        ? runtime.execution.reduce(.cancellationRequested(at: runtimeBoundary.now()))
                        : runtime.execution.reduce(event)

                case .wait(let request):
                    let event: Event
                    switch await inbox.wait(for: request, at: runtimeBoundary.now()) {
                    case .event(let observation):
                        event = .observation(request.id, observation, at: runtimeBoundary.now())
                    case .deadline:
                        event = .deadlineElapsed(request.id, at: runtimeBoundary.now())
                    case .cancelled:
                        event = .cancellationRequested(at: runtimeBoundary.now())
                    }
                    record(event, runtime: &runtime)
                    decision = runtime.execution.reduce(event)
                }
            }
        }

        private func execute(
            _ effect: Effect,
            runtime: inout Runtime,
            baseline: inout Observation.Stream.ExecutionAdmission?,
            inbox: ObservationInbox
        ) async -> Event {
            switch effect {
            case .currentSnapshot(let id, let scope, let deadline):
                let current: TheVault.State.Current? = switch scope {
                case .visible:
                    await brains.vault.semanticObservationStream
                        .admittedVisibleObservation(boundary: .externalDeadline(deadline))
                case .discovery: await brains.navigation.fullGraph(deadline: deadline)?.current
                }
                return .currentSnapshot(id, current?.snapshot, at: runtimeBoundary.now())

            case .beginObservation(let id, let scope, let deadline):
                return await beginObservation(
                    id: id,
                    scope: scope,
                    deadline: deadline,
                    runtime: &runtime,
                    baseline: &baseline,
                    inbox: inbox
                )

            case .dispatch(let id, let command, let deadline):
                let result = await runtimeBoundary.dispatch(command, deadline)
                inbox.advanceNoChange(to: brains.vault.state.history.endIndex)
                return .dispatchCompleted(id, result, at: runtimeBoundary.now())

            case .explore(let id, let predicate, let deadline):
                let outcome = await runtimeBoundary.explore(predicate.resolved.watchTarget, deadline)
                return .viewportExited(id, outcome, at: runtimeBoundary.now())

            case .sampleObservationClose(let requestID, let observationID, let exitPosition, let capture, let source):
                return await sampleObservationClose(
                    requestID: requestID,
                    observationID: observationID,
                    exitPosition: exitPosition,
                    capture: capture,
                    source: source,
                    runtime: &runtime
                )

            case .commitObservationClose(let id, let observationID):
                return await commitObservation(id: id, observationID: observationID, runtime: &runtime)

            case .captureFailureScreenshot(let id, let path, let mode):
                return await captureFailure(id: id, path: path, mode: mode)

            case .cancelObservation(let id, let observationID):
                if let resource = runtime.observation,
                   observationID == resource.id {
                    runtime.observation = nil
                    release(resource, runtime: &runtime)
                }
                return .cancellationCompleted(id, at: runtimeBoundary.now())
            }
        }

        private func captureFailure(
            id: RequestID,
            path: HeistExecutionPath,
            mode: ScreenCaptureMode
        ) async -> Event {
            let completion = TimedOneShot<HeistFailureCapture?>()
            var captureTask: Task<Void, Never>?
            let capture = await completion.wait(
                cancellationValue: nil,
                onRegistered: { completion in
                    captureTask = Task { @MainActor [runtimeBoundary] in
                        let capture = await runtimeBoundary.captureFailure(path, mode)
                        completion.resolve(returning: capture)
                    }
                }
            )
            captureTask?.cancel()
            guard let capture else {
                return .cancellationRequested(at: runtimeBoundary.now())
            }
            return .failureScreenshotCaptured(id, capture, at: runtimeBoundary.now())
        }

        private func isCancellationCleanup(_ effect: Effect) -> Bool {
            if case .cancelObservation = effect { return true }
            return false
        }

        private func beginObservation(
            id: RequestID,
            scope: SemanticObservationScope,
            deadline: SemanticObservationDeadline,
            runtime: inout Runtime,
            baseline: inout Observation.Stream.ExecutionAdmission?,
            inbox: ObservationInbox
        ) async -> Event {
            let stream = brains.vault.semanticObservationStream
            let subscription = stream.subscribe(scope: scope)
            let boundary: TheVault.State.HistoryBoundary
            let captured: TheVault.State.Current?
            switch scope {
            case .visible:
                if let initial = baseline {
                    baseline = nil
                    let admitted = await stream.admitExecutionBaseline(initial, deadline: deadline)
                    captured = admitted.current
                    boundary = admitted.boundary
                } else {
                    captured = await stream.admittedVisibleObservation(boundary: .externalDeadline(deadline))
                    boundary = .init(baseline: captured?.snapshot, historyIndex: stream.executionHistoryIndex(reusing: captured))
                }
            case .discovery:
                captured = nil
                _ = await brains.navigation.fullGraph(deadline: deadline)
                boundary = stream.observationBoundary(scope: scope)
            }
            inbox.advance(to: boundary)
            let resource = ObservationResource(
                id: id,
                boundary: boundary,
                subscription: subscription,
                notifications: brains.vault.accessibilityNotifications.beginActionWindow(),
                deadline: deadline,
                lastTreeChangeAt: nil
            )
            precondition(runtime.observation == nil, "An execution owns one active observation")
            runtime.observation = resource
            if runtime.historyIndex < boundary.historyIndex {
                stream.advanceHistoryProtection(from: runtime.historyIndex, to: boundary.historyIndex)
                runtime.historyIndex = boundary.historyIndex
            }
            return .observationBegan(id, baseline: captured?.snapshot, at: runtimeBoundary.now())
        }

        private func sampleObservationClose(
            requestID: RequestID,
            observationID: RequestID,
            exitPosition: Navigation.ViewportExitPosition,
            capture: ObservationCloseCapture,
            source: ObservationCloseSource,
            runtime: inout Runtime
        ) async -> Event {
            guard let resource = runtime.observation else {
                preconditionFailure("The reducer requested an observation close sample without an active observation")
            }
            precondition(
                resource.id == observationID,
                "The reducer requested an observation close sample for a different observation"
            )
            let viewportExit: Navigation.ViewportExit.Outcome? = if case .origin = exitPosition {
                await brains.navigation.fullGraph(deadline: resource.deadline)?.viewportExit
            } else { nil }
            var captureAvailable = false
            _ = await resource.notifications.admitCausallyCovered { coverage -> Void? in
                captureAvailable = switch capture {
                case .coverage:
                    await self.brains.vault.semanticObservationStream
                        .visibleObservation(covering: coverage) != nil
                case .refresh:
                    if case .committed = await self.brains.vault.semanticObservationStream
                        .refreshedVisibleObservation(boundary: .externalDeadline(resource.deadline)) {
                        true
                    } else {
                        false
                    }
                case .nextCycle:
                    await self.brains.vault.semanticObservationStream
                        .visibleObservationAfterNextCycle(covering: coverage) != nil
                }
                return nil
            }
            let evidence = evidence(after: resource.boundary, captureAvailable: captureAvailable)
            let endedAt = runtimeBoundary.now()
            return .observationCloseSampled(
                requestID, source: source, observationID: observationID, evidence: evidence,
                close: .init(
                    captureAvailable: captureAvailable,
                    viewportExit: viewportExit,
                    lastTreeChangeAt: resource.lastTreeChangeAt
                ), at: endedAt
            )
        }

        private func record(_ event: Event, runtime: inout Runtime) {
            guard case .observation(_, let observation, let at) = event,
                  observation.changesInterface else { return }
            runtime.observation?.lastTreeChangeAt = at
        }

        private func commitObservation(
            id: RequestID,
            observationID: RequestID,
            runtime: inout Runtime
        ) async -> Event {
            guard let resource = runtime.observation else {
                preconditionFailure("The reducer requested an observation close commit without an active observation")
            }
            precondition(
                resource.id == observationID,
                "The reducer requested an observation close commit for a different observation"
            )
            runtime.observation = nil
            _ = await resource.notifications.admitCausallyCovered { _ in true }
            release(resource, runtime: &runtime)
            return .observationCloseCommitted(id, at: runtimeBoundary.now())
        }

        private func evidence(after boundary: TheVault.State.HistoryBoundary, captureAvailable: Bool) -> Observation.Evidence {
            let evidence = brains.vault.state.evidence(after: boundary)
            guard !captureAvailable, evidence.coverage == .complete else { return evidence }
            return .init(baseline: evidence.baseline, events: evidence.events, current: evidence.current, coverage: .incomplete(.captureUnavailable))
        }

        private func release(_ resource: ObservationResource, runtime: inout Runtime) {
            resource.subscription.cancel()
            resource.notifications.cancel()
            let nextHistoryIndex = brains.vault.semanticObservationStream
                .executionHistoryIndex(reusing: brains.vault.state.current)
            brains.vault.semanticObservationStream.advanceHistoryProtection(
                from: runtime.historyIndex,
                to: nextHistoryIndex
            )
            runtime.historyIndex = nextHistoryIndex
        }

        private func release(_ lifetime: Lifetime, runtime: inout Runtime) {
            if let resource = runtime.observation {
                runtime.observation = nil
                release(resource, runtime: &runtime)
            }
            lifetime.subscription.cancel()
            lifetime.demand.cancel()
            lifetime.notifications.cancel()
            brains.vault.semanticObservationStream.releaseHistory(from: runtime.historyIndex)
        }

        private func admitTerminalNotifications(_ lease: AccessibilityNotificationScopeLease, after cursor: AccessibilityNotificationCursor) async -> Bool {
            await lease.admitCausallyCovered { [brains] coverage in
                let terminal = AccessibilityNotificationCoverage(
                    after: cursor,
                    through: coverage.through,
                    scopedScreenChangedThrough: coverage.scopedScreenChangedThrough > cursor.sequence ? coverage.scopedScreenChangedThrough : 0
                )
                guard terminal.requiresObservation else { return true }
                return await brains.vault.semanticObservationStream.visibleObservationThroughCausalCycles(covering: terminal) != nil
            } != nil
        }
    }
}

extension HeistExecution.Host {
    @MainActor
    internal final class ObservationInbox {
        internal enum Outcome: Equatable {
            case event(Observation.Event)
            case deadline
            case cancelled
        }

        private struct Waiter {
            let id: UInt64
            let continuation: CheckedContinuation<Outcome, Never>
            var deadline: Task<Void, Never>?
        }

        private let waitUntilDeadline: @MainActor (Duration) async -> Bool
        private var events: ArraySlice<Observation.Publication.Entry> = []
        private var leafHistoryIndex = 0
        private var noChangeHistoryIndex: Int?
        private var nextWaiterID: UInt64 = 0
        private var waiter: Waiter?

        internal init(
            waitUntilDeadline: @escaping @MainActor (Duration) async -> Bool
        ) {
            self.waitUntilDeadline = waitUntilDeadline
        }

        internal func yield(_ entry: Observation.Publication.Entry) {
            guard admits(entry) else { return }
            guard let waiter else {
                events.append(entry)
                return
            }
            resolve(waiter.id, with: .event(entry.event))
        }

        /// Opens a new observation window after its baseline was captured.
        ///
        /// The execution-level subscription remains installed across leaves.
        /// History position, rather than arrival time, decides whether a queued
        /// event belongs to the leaf that begins after this baseline.
        internal func advance(to boundary: TheVault.State.HistoryBoundary) {
            precondition(
                waiter == nil,
                "An observation baseline cannot advance while a wait is pending"
            )
            leafHistoryIndex = boundary.historyIndex
            noChangeHistoryIndex = nil
            discardUnadmittedEvents()
        }

        /// Records the exact history position reached when dispatch returned.
        /// Transient evidence published during dispatch remains deliverable,
        /// while an earlier stillness event cannot settle the action afterward.
        internal func advanceNoChange(to historyIndex: Int) {
            precondition(
                waiter == nil,
                "Dispatch completion cannot advance stillness while a wait is pending"
            )
            precondition(
                historyIndex >= leafHistoryIndex,
                "Dispatch completion cannot precede its observation baseline"
            )
            noChangeHistoryIndex = historyIndex
            discardUnadmittedEvents()
        }

        internal func wait(
            for request: HeistExecution.WaitRequest,
            at now: RuntimeElapsed.Instant
        ) async -> Outcome {
            nextWaiterID += 1
            let id = nextWaiterID
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    install(
                        id: id,
                        deadline: request.deadline.remainingDuration(at: now),
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resolve(id, with: .cancelled)
                }
            }
        }

        private func install(
            id: UInt64,
            deadline: Duration,
            continuation: CheckedContinuation<Outcome, Never>
        ) {
            precondition(waiter == nil, "An observation inbox admits exactly one pending wait")
            if let event = popEvent() {
                continuation.resume(returning: .event(event))
                return
            }
            guard !Task.isCancelled else {
                continuation.resume(returning: .cancelled)
                return
            }
            waiter = Waiter(
                id: id,
                continuation: continuation,
                deadline: nil
            )
            let waitUntilDeadline = self.waitUntilDeadline
            let deadlineTask = Task { @MainActor [weak self] in
                let elapsed = await waitUntilDeadline(deadline)
                self?.resolve(id, with: elapsed ? .deadline : .cancelled)
            }
            guard waiter?.id == id else {
                deadlineTask.cancel()
                return
            }
            waiter?.deadline = deadlineTask
        }

        private func resolve(
            _ id: UInt64,
            with outcome: Outcome
        ) {
            guard let waiter, waiter.id == id else { return }
            self.waiter = nil
            waiter.deadline?.cancel()
            waiter.continuation.resume(returning: outcome)
        }

        private func popEvent() -> Observation.Event? {
            while let entry = events.popFirst() {
                guard admits(entry) else { continue }
                if events.isEmpty {
                    events = []
                }
                return entry.event
            }
            if events.isEmpty {
                events = []
            }
            return nil
        }

        private func discardUnadmittedEvents() {
            events = ArraySlice(events.filter { admits($0) })
        }

        private func admits(_ entry: Observation.Publication.Entry) -> Bool {
            guard entry.historyIndex >= leafHistoryIndex else { return false }
            guard case .noChange = entry.event,
                  let noChangeHistoryIndex
            else { return true }
            return entry.historyIndex >= noChangeHistoryIndex
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
