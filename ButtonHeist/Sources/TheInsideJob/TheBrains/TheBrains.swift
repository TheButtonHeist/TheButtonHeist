#if canImport(UIKit)
#if DEBUG
import Foundation
import TheScore

/// The brains of the operation — plans the play, sequences the crew.
///
/// TheBrains takes a command and works it through to a result by coordinating
/// TheVault (the screen value), TheSafecracker (gestures), and TheTripwire
/// (timing). Command dispatch, scroll/explore, action handlers, and
/// action evidence are internal components with separate owners.
@MainActor
final class TheBrains {

    // User-facing copy for the typed accessibility-tree-unavailable result.
    nonisolated static let treeUnavailableMessage = "Could not access accessibility tree: no traversable app windows"
    nonisolated static let runtimeInactiveMessage = "ButtonHeist runtime is not active; start TheInsideJob before executing commands"

    let vault: TheVault
    let safecracker: TheSafecracker
    let tripwire: TheTripwire
    let navigation: Navigation
    let actions: Actions
    let failureEvidencePolicy: FailureEvidencePolicy
    private let requestExecutor: InteractionRequestExecutor

    var semanticObservationIsActive: Bool {
        vault.semanticObservationStream.isActive
    }

    func notifications() -> [Observation.Notification] {
        vault.state.notifications
    }

    enum InterfaceQueryFailure: Error, Equatable {
        case rootViewUnavailable
        case inactiveRuntime
        case selection(InterfaceSelectionError)

        var message: String {
            switch self {
            case .rootViewUnavailable:
                return "Could not access root view"
            case .inactiveRuntime:
                return TheBrains.runtimeInactiveMessage
            case .selection(let error):
                return error.message
            }
        }

        var actionFailureKind: ActionFailure.Kind {
            switch self {
            case .rootViewUnavailable, .inactiveRuntime:
                return .accessibilityTreeUnavailable
            case .selection:
                return .validationError
            }
        }
    }

    init(
        tripwire: TheTripwire,
        fingerprintsEnabled: Bool = true,
        failureEvidencePolicy: FailureEvidencePolicy = .screenshot,
        keyboardInput: SafecrackerKeyboardInput = SafecrackerKeyboardInput(),
        visibleObservationSource: @escaping TheVault.VisibleObservationSource = TheVault.captureVisibleObservation,
        notificationIngress: AccessibilityNotificationIngress = .process,
        pulseIngress: Observation.Stream.PulseIngress = .displayLink,
        observationSchedulingBoundary: Observation.Stream.SchedulingBoundary = .immediate
    ) {
        self.tripwire = tripwire
        self.failureEvidencePolicy = failureEvidencePolicy
        self.requestExecutor = InteractionRequestExecutor()
        let safecracker = TheSafecracker(
            fingerprintsEnabled: fingerprintsEnabled,
            keyboardInput: keyboardInput
        )
        let vault = TheVault(
            tripwire: tripwire,
            visibleObservationSource: visibleObservationSource,
            keyboardVisibilitySource: { safecracker.isKeyboardVisible },
            notificationIngress: notificationIngress,
            pulseIngress: pulseIngress,
            observationSchedulingBoundary: observationSchedulingBoundary
        )
        self.vault = vault
        self.safecracker = safecracker
        let navigation = Navigation(
            vault: vault,
            safecracker: safecracker
        )
        self.navigation = navigation
        self.actions = Actions(
            vault: vault,
            safecracker: safecracker,
            tripwire: tripwire,
            navigation: navigation
        )
    }

    func runtimeInactiveResult(payload: ActionResult.Payload) -> ActionResult {
        .failure(
            payload: payload,
            failureKind: .actionFailed,
            message: TheBrains.runtimeInactiveMessage
        )
    }

    func observeInterface(_ query: InterfaceQuery) async -> Result<Interface, InterfaceQueryFailure> {
        guard semanticObservationIsActive else {
            return .failure(.inactiveRuntime)
        }
        // Require visible semantic truth before exploration starts fresh.
        let deadline = SemanticObservationDeadline(
            start: RuntimeElapsed.now,
            timeoutSeconds: 2
        )
        guard await vault.semanticObservationStream.admittedVisibleObservation(
            boundary: .externalDeadline(deadline)
        ) != nil,
              let exploration = await navigation.fullGraph(
                deadline: deadline,
                observationBoundary: .externalDeadline(deadline),
                maxScrollsPerContainer: query.maxScrollsPerContainer?.value,
                maxScrollsPerDiscovery: query.maxScrollsPerDiscovery?.value
              ) else {
            return .failure(.rootViewUnavailable)
        }

        do {
            let interface = try vault.selectInterface(query)
            let diagnostics = exploration.progress.interfaceDiagnostics(
                for: vault.interfaceTree,
                includedElementCount: interface.projectedElements.count
            )
            return .success(interface
                .withDiagnostics(diagnostics)
                .withScreenActions(actions.availableScreenActions()))
        } catch {
            return .failure(.selection(error))
        }
    }

    func executeInAppRequest<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> Value
    ) async -> InteractionRequestExecutor.Outcome<Value> {
        await requestExecutor.executeInApp(operation)
    }

    @discardableResult
    func submitTransportRequest(
        lease: TransportClientLease,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) -> InteractionRequestExecutor.Admission {
        requestExecutor.submit(
            owner: .transportClient(lease),
            operation: operation,
            completion: { _ in }
        )
    }

    func cancelTransportRequests(lease: TransportClientLease) {
        requestExecutor.cancel(owner: .transportClient(lease))
    }

    func stopInteractionRequests() async {
        await requestExecutor.drain()
    }

}

@MainActor
final class InteractionRequestExecutor {
    nonisolated static let maximumPendingRequests = 64
    nonisolated static let cleanupTimeout: Duration = .seconds(5)

    typealias CleanupDeadlineScheduler = @MainActor @Sendable (
        _ deadlineReached: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never>

    enum Owner: Equatable, Sendable {
        case inApp
        case transportClient(TransportClientLease)
    }

    enum Rejection: Equatable, Sendable {
        case busy(capacity: Int)
        case cleanupTimedOut
        case stopping
    }

    enum Admission: Equatable, Sendable {
        case accepted
        case rejected(Rejection)
    }

    enum Outcome<Value: Sendable>: Sendable {
        case completed(Value)
        case cancelled
        case rejected(Rejection)
    }

    private struct PendingRequest {
        let id: UUID
        let owner: Owner
        let operation: @MainActor @Sendable () async -> Void
        let cancel: @MainActor @Sendable () -> Void
    }

    private struct ActiveRequest {
        let request: PendingRequest
        let task: Task<Void, Never>
    }

    private struct CancellationState {
        let active: ActiveRequest
        var pending: [PendingRequest]
        var deadlineTask: Task<Void, Never>?
        var drainWaiters: [CheckedContinuation<Void, Never>]
        var deadlineExpired: Bool
    }

    private enum Phase {
        case idle
        case running(active: ActiveRequest, pending: [PendingRequest])
        case cancelling(CancellationState)
    }

    private var phase = Phase.idle
    convenience init() {
        self.init(cleanupDeadlineScheduler: Self.scheduleCleanupDeadline)
    }

    init(cleanupDeadlineScheduler: @escaping CleanupDeadlineScheduler) {
        self.cleanupDeadlineScheduler = cleanupDeadlineScheduler
    }

    private let cleanupDeadlineScheduler: CleanupDeadlineScheduler

    private static func scheduleCleanupDeadline(
        _ deadlineReached: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: cleanupTimeout)
            guard !Task.isCancelled else { return }
            deadlineReached()
        }
    }

    func executeInApp<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> Value
    ) async -> Outcome<Value> {
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                submit(
                    requestID: requestID,
                    owner: .inApp,
                    operation: operation,
                    completion: { continuation.resume(returning: $0) }
                )
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancel(requestID: requestID)
            }
        }
    }

    @discardableResult
    func submit<Value: Sendable>(
        owner: Owner,
        operation: @escaping @MainActor @Sendable () async -> Value,
        completion: @escaping @MainActor @Sendable (Outcome<Value>) -> Void
    ) -> Admission {
        submit(
            requestID: UUID(),
            owner: owner,
            operation: operation,
            completion: completion
        )
    }

    @discardableResult
    private func submit<Value: Sendable>(
        requestID: UUID,
        owner: Owner,
        operation: @escaping @MainActor @Sendable () async -> Value,
        completion: @escaping @MainActor @Sendable (Outcome<Value>) -> Void
    ) -> Admission {
        let resolver = RequestResolver(completion)
        guard !Task.isCancelled else {
            resolver.resolve(.cancelled)
            return .accepted
        }

        let request = PendingRequest(
            id: requestID,
            owner: owner,
            operation: {
                guard !Task.isCancelled else {
                    resolver.resolve(.cancelled)
                    return
                }
                resolver.resolve(.completed(await operation()))
            },
            cancel: { resolver.resolve(.cancelled) }
        )
        let admission = enqueue(request)
        if case .rejected(let rejection) = admission {
            resolver.resolve(.rejected(rejection))
        }
        return admission
    }

    func cancel(owner: Owner) {
        cancel { $0.owner == owner }
    }

    private func cancel(requestID: UUID) {
        cancel { $0.id == requestID }
    }

    private func cancel(where matches: (PendingRequest) -> Bool) {
        let pendingToCancel: [PendingRequest]
        let activeToCancel: ActiveRequest?
        switch phase {
        case .idle:
            return
        case .running(let active, let pending):
            let cancelled = pending.filter(matches)
            let retained = pending.filter { !matches($0) }
            pendingToCancel = cancelled
            if matches(active.request) {
                beginCancellation(active: active, pending: retained)
                activeToCancel = active
            } else {
                phase = .running(active: active, pending: retained)
                activeToCancel = nil
            }
        case .cancelling(var state):
            let cancelled = state.pending.filter(matches)
            state.pending.removeAll(where: matches)
            phase = .cancelling(state)
            pendingToCancel = cancelled
            activeToCancel = nil
        }
        resolveCancellation(for: pendingToCancel)
        if let activeToCancel {
            resolveCancellation(for: activeToCancel)
        }
    }

    func drain() async {
        guard case .idle = phase else {
            await withCheckedContinuation { continuation in
                beginDrain(continuation: continuation)
            }
            return
        }
    }

    private func enqueue(_ request: PendingRequest) -> Admission {
        switch phase {
        case .idle:
            start(request, pending: [])
            return .accepted
        case .running(let active, var pending):
            guard pending.count < Self.maximumPendingRequests else {
                return .rejected(.busy(capacity: Self.maximumPendingRequests))
            }
            pending.append(request)
            phase = .running(active: active, pending: pending)
            return .accepted
        case .cancelling(var state):
            guard state.drainWaiters.isEmpty else {
                return .rejected(.stopping)
            }
            guard !state.deadlineExpired else {
                return .rejected(.cleanupTimedOut)
            }
            guard state.pending.count < Self.maximumPendingRequests else {
                return .rejected(.busy(capacity: Self.maximumPendingRequests))
            }
            state.pending.append(request)
            phase = .cancelling(state)
            return .accepted
        }
    }

    private func start(_ request: PendingRequest, pending: [PendingRequest]) {
        let task = Task { @MainActor [weak self] in
            await request.operation()
            self?.complete(expected: request.id)
        }
        phase = .running(
            active: ActiveRequest(request: request, task: task),
            pending: pending
        )
    }

    private func complete(expected requestID: UUID) {
        switch phase {
        case .idle:
            return
        case .running(let active, var pending):
            guard active.request.id == requestID else { return }
            guard !pending.isEmpty else {
                phase = .idle
                return
            }
            start(pending.removeFirst(), pending: pending)
        case .cancelling(let state):
            guard state.active.request.id == requestID else { return }
            state.deadlineTask?.cancel()
            if !state.drainWaiters.isEmpty {
                finishDrain(state.drainWaiters)
            } else if state.deadlineExpired || state.pending.isEmpty {
                phase = .idle
            } else {
                var pending = state.pending
                start(pending.removeFirst(), pending: pending)
            }
        }
    }

    private func beginDrain(
        continuation: CheckedContinuation<Void, Never>
    ) {
        switch phase {
        case .idle:
            continuation.resume()
        case .running(let active, let pending):
            resolveCancellation(for: pending)
            beginCancellation(active: active, pending: [], drainWaiters: [continuation])
            resolveCancellation(for: active)
        case .cancelling(var state):
            let pending = state.pending
            state.pending.removeAll()
            state.drainWaiters.append(continuation)
            phase = .cancelling(state)
            resolveCancellation(for: pending)
            if state.deadlineExpired {
                releaseExpiredDrain(state)
            }
        }
    }

    private func beginCancellation(
        active: ActiveRequest,
        pending: [PendingRequest],
        drainWaiters: [CheckedContinuation<Void, Never>] = []
    ) {
        phase = .cancelling(CancellationState(
            active: active,
            pending: pending,
            deadlineTask: nil,
            drainWaiters: drainWaiters,
            deadlineExpired: false
        ))
        let requestID = active.request.id
        let deadlineTask = cleanupDeadlineScheduler { [weak self] in
            self?.cleanupDeadlineReached(expected: requestID)
        }
        guard case .cancelling(var state) = phase,
              state.active.request.id == requestID else {
            deadlineTask.cancel()
            return
        }
        state.deadlineTask = deadlineTask
        phase = .cancelling(state)
    }

    private func cleanupDeadlineReached(expected requestID: UUID) {
        guard case .cancelling(var state) = phase,
              state.active.request.id == requestID,
              !state.deadlineExpired else { return }
        let pending = state.pending
        state.pending.removeAll()
        state.deadlineTask = nil
        state.deadlineExpired = true
        phase = .cancelling(state)
        resolveCancellation(for: pending)
        if !state.drainWaiters.isEmpty {
            releaseExpiredDrain(state)
        }
    }

    private func releaseExpiredDrain(_ state: CancellationState) {
        var state = state
        let waiters = state.drainWaiters
        state.drainWaiters.removeAll()
        phase = .cancelling(state)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func finishDrain(_ waiters: [CheckedContinuation<Void, Never>]) {
        phase = .idle
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resolveCancellation(for active: ActiveRequest) {
        active.request.cancel()
        active.task.cancel()
    }

    private func resolveCancellation(for pending: [PendingRequest]) {
        pending.forEach { $0.cancel() }
    }

    @MainActor
    private final class RequestResolver<Value: Sendable> {
        private var completion: (@MainActor @Sendable (Outcome<Value>) -> Void)?

        init(_ completion: @escaping @MainActor @Sendable (Outcome<Value>) -> Void) {
            self.completion = completion
        }

        func resolve(_ outcome: Outcome<Value>) {
            guard let completion else { return }
            self.completion = nil
            completion(outcome)
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
