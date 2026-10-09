import Foundation
import ButtonHeistSupport
import TheScore

private let disconnectedDuringConnectionAttemptMessage =
    "Disconnected during connection attempt. The app may have been busy, suspended, or restarted before the handshake completed."

/// Owns connection and reconnect state, every lifecycle task, and all waiters
/// scoped to the current connection attempt. Reconnecting is a public view of
/// a disconnected runtime whose reconnect policy owns the active run.
@ButtonHeistActor
final class HandoffConnectionLifecycle {
    enum Effect {
        case disconnect(any DeviceConnecting)
    }

    private struct ConnectingRuntime {
        let attempt: HandoffConnectionAttempt
        let connection: any DeviceConnecting
        var waiters = WaiterStore<UUID, TimedOneShot<Result<Void, Error>>>()
    }

    private struct ConnectedRuntime {
        var session: HandoffConnectedSession
        let connection: any DeviceConnecting
    }

    private struct ReconnectRun {
        let attempt: HandoffReconnectAttempt
        let task: Task<Void, Never>
    }

    private enum ReconnectState {
        case disabled
        case armed(DeviceResolutionTarget)
        case running(ReconnectRun)
        case exhausted

        var activeRun: ReconnectRun? {
            guard case .running(let run) = self else { return nil }
            return run
        }
    }

    private enum RuntimePhase {
        case disconnected(failure: HandoffConnectionError?, reconnect: ReconnectState)
        case connecting(ConnectingRuntime, reconnect: ReconnectState, failure: HandoffConnectionError?)
        case connected(ConnectedRuntime, reconnect: ReconnectState)
        case failed(HandoffConnectionError, reconnect: ReconnectState)

        var projectedPhase: HandoffConnectionPhase {
            switch self {
            case .disconnected(_, let reconnect):
                if case .running(let run) = reconnect {
                    return .reconnecting(run.attempt)
                }
                return .disconnected
            case .connecting(let runtime, _, _):
                return .connecting(runtime.attempt)
            case .connected(let runtime, _):
                return .connected(runtime.session)
            case .failed(let failure, _):
                return .failed(failure)
            }
        }

        var reconnectState: ReconnectState {
            switch self {
            case .disconnected(_, let reconnect),
                 .connecting(_, let reconnect, _),
                 .connected(_, let reconnect),
                 .failed(_, let reconnect):
                return reconnect
            }
        }

        var activeAttemptID: UUID? {
            switch self {
            case .connecting(let runtime, _, _):
                return runtime.attempt.id
            case .connected(let runtime, _):
                return runtime.session.attemptID
            case .disconnected, .failed:
                return nil
            }
        }

        var activeConnection: (any DeviceConnecting)? {
            switch self {
            case .connecting(let runtime, _, _):
                return runtime.connection
            case .connected(let runtime, _):
                return runtime.connection
            case .disconnected, .failed:
                return nil
            }
        }

        var diagnosticFailure: HandoffConnectionError? {
            switch self {
            case .failed(let failure, _):
                return failure
            case .disconnected(let failure, _),
                 .connecting(_, _, let failure):
                return failure
            case .connected:
                return nil
            }
        }

        var isActiveConnection: Bool {
            switch self {
            case .connecting, .connected:
                return true
            case .disconnected, .failed:
                return false
            }
        }

        var connectedRuntime: ConnectedRuntime? {
            guard case .connected(let runtime, _) = self else { return nil }
            return runtime
        }

        var activeReconnectRun: ReconnectRun? {
            reconnectState.activeRun
        }

        func replacingReconnectState(_ reconnect: ReconnectState) -> RuntimePhase {
            switch self {
            case .disconnected(let failure, _):
                return .disconnected(failure: failure, reconnect: reconnect)
            case .connecting(let runtime, _, let failure):
                return .connecting(runtime, reconnect: reconnect, failure: failure)
            case .connected(let runtime, _):
                return .connected(runtime, reconnect: reconnect)
            case .failed(let failure, _):
                return .failed(failure, reconnect: reconnect)
            }
        }

        func connectionWaiterEffects(for next: RuntimePhase) -> [LifecycleEffect] {
            guard case .connecting(let current, _, _) = self else { return [] }
            if case .connecting(let nextRuntime, _, _) = next,
               nextRuntime.attempt.id == current.attempt.id {
                return []
            }

            let result: Result<Void, Error>
            if case .connected(let nextRuntime, _) = next,
               nextRuntime.session.attemptID == current.attempt.id {
                result = .success(())
            } else if case .failed(let failure, _) = next {
                result = .failure(failure)
            } else {
                result = .failure(
                    next.diagnosticFailure
                        ?? HandoffConnectionError.connectionFailed(disconnectedDuringConnectionAttemptMessage)
                )
            }

            var waiters = current.waiters
            return waiters.removeAll().map { .resolveConnectionWaiter($0, result) }
        }
    }

    private enum LifecycleEffect {
        case cancelTask(Task<Void, Never>)
        case phaseChanged(HandoffConnectionPhase)
        case resolveConnectionWaiter(
            TimedOneShot<Result<Void, Error>>,
            Result<Void, Error>
        )
    }

    private var runtimePhase: RuntimePhase = .disconnected(failure: nil, reconnect: .disabled)

    var onPhaseChanged: (@ButtonHeistActor (HandoffConnectionPhase) -> Void)?

    var phase: HandoffConnectionPhase {
        runtimePhase.projectedPhase
    }

    var activeAttemptID: UUID? {
        runtimePhase.activeAttemptID
    }

    var activeConnection: (any DeviceConnecting)? {
        runtimePhase.activeConnection
    }

    var isConnected: Bool {
        if case .connected = runtimePhase { return true }
        return false
    }

    var isReconnectRunning: Bool {
        runtimePhase.activeReconnectRun != nil
    }

    var diagnosticFailure: HandoffConnectionError? {
        runtimePhase.diagnosticFailure
    }

    var connectedDevice: DiscoveredDevice? {
        guard case .connected(let runtime, _) = runtimePhase else { return nil }
        return runtime.session.device
    }

    var serverInfo: ServerInfo? {
        guard case .connected(let runtime, _) = runtimePhase else { return nil }
        return runtime.session.serverInfo
    }

    var missedPongCount: Int {
        guard case .connected(let runtime, _) = runtimePhase else { return 0 }
        return runtime.session.missedPongCount
    }

    func isActiveAttempt(_ attemptID: UUID) -> Bool {
        activeAttemptID == attemptID
    }

    // MARK: - Reconnect lifecycle

    func setup(target: DeviceResolutionTarget) -> Bool {
        if case .armed(let currentTarget) = runtimePhase.reconnectState,
           currentTarget == target {
            return false
        }
        transition(to: runtimePhase.replacingReconnectState(.armed(target)))
        return true
    }

    func disable() -> Bool {
        let wasRunning = isReconnectRunning
        transition(to: runtimePhase.replacingReconnectState(.disabled))
        return wasRunning
    }

    func cancelReconnectAttempt() -> Bool {
        guard let run = runtimePhase.activeReconnectRun else { return false }
        transition(to: runtimePhase.replacingReconnectState(.armed(run.attempt.target.resolutionTarget)))
        return true
    }

    func targetForDisconnectedDevice(_ disconnectedDevice: DiscoveredDevice) -> HandoffReconnectTarget? {
        guard case .armed(let target) = runtimePhase.reconnectState else { return nil }
        return HandoffReconnectTarget(resolutionTarget: target, device: disconnectedDevice)
    }

    @discardableResult
    func run(
        target: HandoffReconnectTarget,
        operation: @escaping @ButtonHeistActor (HandoffReconnectAttempt) async -> Void
    ) -> HandoffReconnectAttempt? {
        guard case .armed(let resolutionTarget) = runtimePhase.reconnectState,
              resolutionTarget == target.resolutionTarget,
              !runtimePhase.isActiveConnection
        else { return nil }

        let attempt = HandoffReconnectAttempt(id: UUID(), target: target)
        let task = Task<Void, Never> { @ButtonHeistActor [weak self, attempt] in
            guard let self, self.isCurrentReconnectAttempt(attempt) else { return }
            await operation(attempt)
        }
        let run = ReconnectRun(attempt: attempt, task: task)
        transition(to: .disconnected(
            failure: runtimePhase.diagnosticFailure,
            reconnect: .running(run)
        ))
        return attempt
    }

    func isCurrentReconnectAttempt(_ attempt: HandoffReconnectAttempt) -> Bool {
        guard !Task.isCancelled, let activeRun = runtimePhase.activeReconnectRun else { return false }
        return activeRun.attempt == attempt
    }

    func finishSuccess(_ attempt: HandoffReconnectAttempt) -> Bool {
        guard isCurrentReconnectAttempt(attempt) else { return false }
        let next = runtimePhase.replacingReconnectState(.armed(attempt.target.resolutionTarget))
        transition(to: next, cancelDepartedReconnectRun: false)
        return true
    }

    func finishFailure(
        _ attempt: HandoffReconnectAttempt,
        failure: HandoffConnectionError
    ) -> Bool {
        guard isCurrentReconnectAttempt(attempt) else { return false }
        transition(
            to: .failed(
                failure,
                reconnect: .exhausted
            ),
            cancelDepartedReconnectRun: false
        )
        return true
    }

    func markReconnecting(target: HandoffReconnectTarget, attemptID: UUID) {
        guard !runtimePhase.isActiveConnection,
              let run = runtimePhase.activeReconnectRun,
              run.attempt.id == attemptID,
              run.attempt.target == target
        else { return }
        transition(to: .disconnected(
            failure: runtimePhase.diagnosticFailure,
            reconnect: .running(run)
        ))
    }

    // MARK: - Connection lifecycle

    func beginConnecting(device: DiscoveredDevice, connection: any DeviceConnecting) -> UUID {
        let attempt = HandoffConnectionAttempt(id: UUID(), device: device)
        transition(to: .connecting(
            ConnectingRuntime(attempt: attempt, connection: connection),
            reconnect: runtimePhase.reconnectState,
            failure: nil
        ))
        return attempt.id
    }

    @discardableResult
    func markConnected(
        attemptID: UUID,
        device: DiscoveredDevice,
        keepaliveTask: Task<Void, Never>
    ) -> Bool {
        guard case .connecting(let runtime, let reconnect, _) = runtimePhase,
              runtime.attempt.id == attemptID
        else {
            keepaliveTask.cancel()
            return false
        }
        transition(to: .connected(
            ConnectedRuntime(
                session: HandoffConnectedSession(
                    attemptID: attemptID,
                    device: device,
                    keepaliveTask: keepaliveTask
                ),
                connection: runtime.connection
            ),
            reconnect: reconnect
        ))
        return true
    }

    func fail(_ failure: HandoffConnectionError) -> Effect? {
        let effects = disconnectEffect
        transition(to: .failed(failure, reconnect: runtimePhase.reconnectState))
        return effects
    }

    @discardableResult
    func observeDisconnect(
        _ reason: DisconnectReason,
        expectedAttemptID: UUID? = nil
    ) -> Bool {
        if let expectedAttemptID, activeAttemptID != expectedAttemptID { return false }

        let wasActive = runtimePhase.isActiveConnection
        let failure = wasActive ? HandoffConnectionError.disconnected(reason) : runtimePhase.diagnosticFailure
        transition(to: .disconnected(failure: failure, reconnect: runtimePhase.reconnectState))
        return wasActive
    }

    func disconnect(reason: DisconnectReason? = nil) -> Effect? {
        let effects = disconnectEffect
        let failure = runtimePhase.isActiveConnection ? reason.map(HandoffConnectionError.disconnected) : nil
        transition(to: .disconnected(failure: failure, reconnect: runtimePhase.reconnectState))
        return effects
    }

    func abort(_ attemptID: UUID, failure: HandoffConnectionError) -> Effect? {
        guard activeAttemptID == attemptID else { return nil }
        let effects = disconnectEffect
        transition(to: .disconnected(failure: failure, reconnect: runtimePhase.reconnectState))
        return effects
    }

    func recordAttemptFailure(_ failure: HandoffConnectionError) {
        switch runtimePhase {
        case .disconnected(_, let reconnect):
            transition(to: .disconnected(failure: failure, reconnect: reconnect))
        case .connecting(let runtime, let reconnect, _):
            transition(to: .connecting(runtime, reconnect: reconnect, failure: failure))
        case .connected, .failed:
            break
        }
    }

    func recordServerInfo(_ info: ServerInfo) {
        updateConnectedSession { $0.serverInfo = info }
    }

    func markPongReceived() {
        updateConnectedSession { $0.missedPongCount = 0 }
    }

    @discardableResult
    func recordKeepaliveTick(expectedAttemptID: UUID? = nil) -> Int {
        guard case .connected(var runtime, let reconnect) = runtimePhase else { return 0 }
        if let expectedAttemptID, runtime.session.attemptID != expectedAttemptID { return 0 }
        runtime.session.missedPongCount += 1
        let count = runtime.session.missedPongCount
        transition(to: .connected(runtime, reconnect: reconnect))
        return count
    }

    private func updateConnectedSession(_ body: (inout HandoffConnectedSession) -> Void) {
        guard case .connected(var runtime, let reconnect) = runtimePhase else { return }
        body(&runtime.session)
        transition(to: .connected(runtime, reconnect: reconnect))
    }

    private var disconnectEffect: Effect? {
        activeConnection.map(Effect.disconnect)
    }

    // MARK: - Connection result waiting

    func waitForConnectionResult(timeout: TimeInterval) async throws {
        let attemptID: UUID
        switch runtimePhase {
        case .connected:
            return
        case .failed(let failure, _):
            throw failure
        case .disconnected(let failure, _):
            if let failure { throw failure }
            throw HandoffConnectionError.connectionFailed(Self.disconnectedDuringAttemptMessage)
        case .connecting(let runtime, _, _):
            attemptID = runtime.attempt.id
        }

        let waiterID = UUID()
        let timeoutDuration: Duration = .seconds(max(timeout, 0))
        let completion = TimedOneShot<Result<Void, Error>>()

        let result = await completion.wait(
            cancellationValue: .failure(CancellationError()),
            onRegistered: { completion in
                guard registerConnectionWaiter(
                    completion,
                    id: waiterID,
                    attemptID: attemptID
                ) else {
                    completion.resolve(returning: .failure(HandoffConnectionError.connectionFailed(
                        Self.disconnectedDuringAttemptMessage
                    )))
                    return
                }
                completion.armTimeout(after: timeoutDuration) { [weak self] in
                    await self?.failConnectionWaiter(
                        id: waiterID,
                        attemptID: attemptID,
                        with: .timeout
                    )
                }
            },
            onFinished: {
                removeConnectionWaiter(id: waiterID, attemptID: attemptID)
            }
        )
        try result.get()
    }

    private func registerConnectionWaiter(
        _ waiter: TimedOneShot<Result<Void, Error>>,
        id: UUID,
        attemptID: UUID
    ) -> Bool {
        guard case .connecting(var runtime, let reconnect, let failure) = runtimePhase,
              runtime.attempt.id == attemptID
        else { return false }
        runtime.waiters.insert(waiter, for: id)
        transition(to: .connecting(runtime, reconnect: reconnect, failure: failure))
        return true
    }

    @discardableResult
    private func removeConnectionWaiter(
        id: UUID,
        attemptID: UUID
    ) -> TimedOneShot<Result<Void, Error>>? {
        guard case .connecting(var runtime, let reconnect, let failure) = runtimePhase,
              runtime.attempt.id == attemptID,
              let waiter = runtime.waiters.remove(id)
        else { return nil }
        transition(to: .connecting(runtime, reconnect: reconnect, failure: failure))
        return waiter
    }

    private func failConnectionWaiter(
        id: UUID,
        attemptID: UUID,
        with failure: HandoffConnectionError
    ) {
        guard let waiter = removeConnectionWaiter(id: id, attemptID: attemptID) else { return }
        perform([.resolveConnectionWaiter(waiter, .failure(failure))])
    }

    // MARK: - Transition reducer and effects

    private func transition(
        to nextPhase: RuntimePhase,
        cancelDepartedReconnectRun: Bool = true
    ) {
        let previousPhase = runtimePhase
        let effects = Self.effects(
            from: previousPhase,
            to: nextPhase,
            cancelDepartedReconnectRun: cancelDepartedReconnectRun
        )
        runtimePhase = nextPhase
        perform(effects)
    }

    private static func effects(
        from previousPhase: RuntimePhase,
        to nextPhase: RuntimePhase,
        cancelDepartedReconnectRun: Bool
    ) -> [LifecycleEffect] {
        var effects: [LifecycleEffect] = []

        if let previousConnected = previousPhase.connectedRuntime,
           nextPhase.connectedRuntime?.session.attemptID != previousConnected.session.attemptID {
            effects.append(.cancelTask(previousConnected.session.keepaliveTask))
        }

        if cancelDepartedReconnectRun,
           let previousRun = previousPhase.activeReconnectRun,
           nextPhase.activeReconnectRun?.attempt.id != previousRun.attempt.id {
            effects.append(.cancelTask(previousRun.task))
        }

        let previousProjection = previousPhase.projectedPhase
        let nextProjection = nextPhase.projectedPhase
        if !isSameConnectionPhase(previousProjection, nextProjection) {
            effects.append(.phaseChanged(nextProjection))
        }

        effects.append(contentsOf: previousPhase.connectionWaiterEffects(for: nextPhase))
        return effects
    }

    private func perform(_ effects: [LifecycleEffect]) {
        for effect in effects {
            switch effect {
            case .cancelTask(let task):
                task.cancel()
            case .phaseChanged(let phase):
                onPhaseChanged?(phase)
            case .resolveConnectionWaiter(let waiter, let result):
                waiter.resolve(returning: result)
            }
        }
    }

    private static func isSameConnectionPhase(
        _ lhs: HandoffConnectionPhase,
        _ rhs: HandoffConnectionPhase
    ) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected),
             (.failed, .failed):
            return true
        case (.reconnecting(let lhsRun), .reconnecting(let rhsRun)):
            return lhsRun == rhsRun
        default:
            return false
        }
    }

    fileprivate static let disconnectedDuringAttemptMessage = disconnectedDuringConnectionAttemptMessage
}
