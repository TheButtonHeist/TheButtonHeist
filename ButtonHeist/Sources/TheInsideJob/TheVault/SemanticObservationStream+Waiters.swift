#if canImport(UIKit)
#if DEBUG
import ButtonHeistSupport
import TheScore

internal enum SemanticObservationWaitBoundary: Sendable, Equatable {
    case cancellation
    case cancellableObservationCycle
    case observationCycle
    case externalDeadline(SemanticObservationDeadline)

    var completesObservationCycle: Bool {
        switch self {
        case .cancellableObservationCycle, .observationCycle:
            true
        case .cancellation, .externalDeadline:
            false
        }
    }
}

internal enum SemanticObservationWaitResult: Sendable, Equatable {
    case observation(TheVault.State.Current)
    case cycleCompletedWithoutObservation
    case deadlineReached
    case cancelled
    case unavailable(Observation.History.ReadError)
}

internal struct SemanticObservationWaiter: Sendable {
    let historyIndex: Int
    let scope: SemanticObservationScope
    let boundary: SemanticObservationWaitBoundary
    let oneShot: TimedOneShot<SemanticObservationWaitResult>
}

@MainActor
extension Observation.Stream {
    internal func waitForObservation(
        after historyIndex: Int,
        scope: SemanticObservationScope,
        boundary: SemanticObservationWaitBoundary
    ) async -> SemanticObservationWaitResult {
        guard isActive else { return .cancelled }
        if Task.isCancelled,
           boundary != .observationCycle {
            return .cancelled
        }
        if case .externalDeadline(let deadline) = boundary,
           !deadline.hasTimeRemaining(at: RuntimeElapsed.now) {
            return .deadlineReached
        }

        let waiterID = observationWaiters.reserveID()
        let oneShot = TimedOneShot<SemanticObservationWaitResult>()
        let subscription = subscribe(scope: scope)
        defer { subscription.cancel() }

        let result: SemanticObservationWaitResult
        if case .observationCycle = boundary {
            result = await withCheckedContinuation { continuation in
                guard oneShot.register(continuation) else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                registerObservationWaiter(
                    oneShot,
                    id: waiterID,
                    historyIndex: historyIndex,
                    scope: scope,
                    boundary: boundary
                )
            }
        } else {
            result = await oneShot.wait(
                cancellationValue: .cancelled,
                onRegistered: { oneShot in
                    registerObservationWaiter(
                        oneShot,
                        id: waiterID,
                        historyIndex: historyIndex,
                        scope: scope,
                        boundary: boundary
                    )
                },
                onFinished: {
                    observationWaiters.remove(id: waiterID)?.oneShot.cancelTimeout()
                }
            )
        }
        return result
    }

    private func registerObservationWaiter(
        _ oneShot: TimedOneShot<SemanticObservationWaitResult>,
        id: UInt64,
        historyIndex: Int,
        scope: SemanticObservationScope,
        boundary: SemanticObservationWaitBoundary
    ) {
        observationWaiters.insert(SemanticObservationWaiter(
            historyIndex: historyIndex,
            scope: scope,
            boundary: boundary,
            oneShot: oneShot
        ), id: id)
        schedulingBoundary.waiterRegistered()
        Task { @MainActor in
            resolveObservationWaiterIfAvailable(id)
        }
        armObservationDeadline(boundary, waiterID: id, oneShot: oneShot)
    }

    internal func nextObservation(
        scope: SemanticObservationScope,
        after historyIndex: Int?,
        boundary: SemanticObservationWaitBoundary
    ) async -> TheVault.State.Current? {
        if boundary.completesObservationCycle {
            guard isActive else { return nil }
            if scope != .discovery {
                return admittedObservation(
                    scope: scope,
                    after: historyIndex
                )
            }
        }
        var cursor: Int
        if let historyIndex {
            cursor = historyIndex
        } else {
            cursor = vault.state.history.endIndex
        }
        while true {
            switch await waitForObservation(
                after: cursor,
                scope: scope,
                boundary: boundary
            ) {
            case .observation:
                if let latest = admittedObservation(
                    scope: scope,
                    after: cursor
                ) {
                    return latest
                }
                cursor = vault.state.history.endIndex
            case .cycleCompletedWithoutObservation:
                return nil
            case .deadlineReached, .cancelled, .unavailable:
                return nil
            }
        }
    }

    func completeObservationWaiters(
        completedScope: SemanticObservationScope? = nil,
        observationCommitted: Bool? = nil
    ) {
        var candidates: [(UInt64, SemanticObservationWaiter)] = []
        observationWaiters.updateAll { id, waiter in
            candidates.append((id, waiter))
        }
        for (id, waiter) in candidates {
            guard let result = observationWaitResult(
                for: waiter,
                completedScope: completedScope,
                observationCommitted: observationCommitted
            ) else { continue }
            resolveObservationWaiter(id, with: result)
        }
    }

    func cancelObservationWaiters() {
        for waiter in observationWaiters.removeAll() {
            waiter.oneShot.resolve(returning: .cancelled)
        }
    }

    private func resolveObservationWaiterIfAvailable(
        _ waiterID: UInt64,
        completedScope: SemanticObservationScope? = nil,
        observationCommitted: Bool? = nil
    ) {
        guard let waiter = observationWaiters[waiterID],
              let result = observationWaitResult(
                for: waiter,
                completedScope: completedScope,
                observationCommitted: observationCommitted
              )
        else { return }
        resolveObservationWaiter(waiterID, with: result)
    }

    private func observationWaitResult(
        for waiter: SemanticObservationWaiter,
        completedScope: SemanticObservationScope?,
        observationCommitted: Bool?
    ) -> SemanticObservationWaitResult? {
        switch vault.state.current(
            after: waiter.historyIndex,
            scope: waiter.scope
        ) {
        case .success(.some(let current)):
            return .observation(current)
        case .failure(let error):
            return .unavailable(error)
        case .success(nil):
            if waiter.boundary.completesObservationCycle,
               let completedScope,
               observationCommitted == false,
               completedScope >= waiter.scope {
                return .cycleCompletedWithoutObservation
            }
            return nil
        }
    }

    private func resolveObservationWaiter(
        _ waiterID: UInt64,
        with result: SemanticObservationWaitResult
    ) {
        guard let waiter = observationWaiters.remove(id: waiterID) else { return }
        waiter.oneShot.resolve(returning: result)
    }

    private func armObservationDeadline(
        _ boundary: SemanticObservationWaitBoundary,
        waiterID: UInt64,
        oneShot: TimedOneShot<SemanticObservationWaitResult>
    ) {
        guard case .externalDeadline(let deadline) = boundary else { return }
        let remaining = deadline.remainingSeconds()
        guard remaining > 0 else {
            resolveObservationWaiter(waiterID, with: .deadlineReached)
            return
        }
        oneShot.armTimeout(after: .saturatingSeconds(remaining)) { [weak self] in
            await self?.resolveObservationWaiter(waiterID, with: .deadlineReached)
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
