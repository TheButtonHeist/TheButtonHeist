#if canImport(UIKit)
#if DEBUG
import ButtonHeistSupport

import TheScore

@MainActor
enum AccessibilityNotificationIngress {
    case process
    case injected

    func start(deliveringTo bus: AccessibilityNotificationBus) {
        guard self == .process else { return }
        AccessibilityNotificationObserver.shared.attach(bus)
    }

    func stop(deliveringTo bus: AccessibilityNotificationBus) {
        guard self == .process else { return }
        AccessibilityNotificationObserver.shared.detach(bus)
    }
}

/// Coordinates semantic observation scheduling, capture, and delivery.
extension Observation {
@MainActor
internal final class Stream {
    struct SchedulingBoundary {
        let waiterRegistered: @MainActor () -> Void

        static let immediate = SchedulingBoundary(waiterRegistered: {})
    }

    enum PulseIngress {
        case displayLink
        case injected
    }

    enum EventDelivery {
        case all
        case noChangesUntilActivated
    }

    private struct EventReceiver {
        let subscriptionID: UInt64
        let receive: @MainActor (Publication.Entry) -> Void
        var delivery: EventDelivery
        var pending: [Publication.Entry]
        var nextIndex: Int
        var isDelivering: Bool
    }

    internal struct PositionedEventInstallation {
        internal let subscription: SemanticObservationSubscription
        internal let replay: Result<[Publication.Entry], History.ReadError>
    }

    internal struct ExecutionAdmission {
        internal let baseline: TheVault.State.Current?
        internal let retainedHistoryIndex: Int
        internal let subscription: SemanticObservationSubscription
        internal let demand: SemanticObservationDemand
    }

    private struct CycleResult {
        let claim: AccessibilityNotificationCycleClaim
        let observationCommitted: Bool
    }

    unowned let vault: TheVault
    let tripwire: TheTripwire
    var readTripwireSignal: @MainActor () -> TheTripwire.TripwireSignal
    private var cycle = SemanticObservationCycle()

    // MARK: - Observation Bookkeeping

    var scopePressure = SemanticObservationScopePressure()
    /// Whether Button Heist is the one moving the viewport right now.
    ///
    /// Screen identity is compared over the viewport, so a reading taken part
    /// way through a scroll can share no elements with the reading before it.
    /// A viewport transition holds this for as long as it drives the scroll,
    /// which is what lets an ambient reading state `.viewportMovement`.
    private var activeViewportMovementCount = 0
    var captureLineage: ScreenLineage {
        activeViewportMovementCount == 0 ? .resting : .viewportMovement
    }
    var observationWaiters = WaiterStore<UInt64, SemanticObservationWaiter>()
    let schedulingBoundary: SchedulingBoundary
    private var eventReceiver: EventReceiver?
    private let notificationIngress: AccessibilityNotificationIngress
    let pulseIngress: PulseIngress

    // MARK: - Subscriber-Facing Observation History

    internal var isActive: Bool {
        cycle.isRunning
    }

    internal var observationWaiterCount: Int {
        observationWaiters.count
    }

    internal var activeObservationDemandCount: Int {
        scopePressure.activeDemandCount
    }

    internal var hasActiveObservationDemand: Bool {
        scopePressure.hasActiveDemand
    }

    var pulseDemand: TheTripwire.TickDemand {
        hasActiveObservationDemand ? .immediate : .ambient
    }

    internal init(
        vault: TheVault,
        tripwire: TheTripwire,
        notificationIngress: AccessibilityNotificationIngress,
        pulseIngress: PulseIngress,
        schedulingBoundary: SchedulingBoundary
    ) {
        self.vault = vault
        self.tripwire = tripwire
        self.notificationIngress = notificationIngress
        self.pulseIngress = pulseIngress
        self.schedulingBoundary = schedulingBoundary
        self.readTripwireSignal = {
            tripwire.tripwireSignal().recordingAccessibilityNotifications(
                through: vault.accessibilityNotifications.latestSequence
            )
        }
    }

    internal func start() {
        guard cycle.start() else { return }
        vault.state.discardCurrentObservation()
        notificationIngress.start(deliveringTo: vault.accessibilityNotifications)
        if pulseIngress == .displayLink {
            tripwire.observePulses { [weak self] pulse in
                self?.deliver(pulse)
            }
        }
        updateCycleDemand()
    }

    internal func stop() {
        guard let stop = cycle.stop() else { return }
        if pulseIngress == .displayLink {
            tripwire.stopObservingPulses()
        }
        stop.activeTask?.cancel()
        cancelObservationWaiters()
        notificationIngress.stop(deliveringTo: vault.accessibilityNotifications)
    }

    /// Raises the scope the vault reads at, without listening.
    ///
    /// Holding a scope is how a caller says how hard to look; the vault reads at
    /// the widest scope anyone holds. Event delivery is a separate question, and
    /// only the running heist asks for it.
    internal func subscribe(scope: SemanticObservationScope) -> SemanticObservationSubscription {
        let id = scopePressure.addSubscription(scope: scope)
        updateCycleDemand()
        return SemanticObservationSubscription(id: id, scope: scope, stream: self)
    }

    /// Raises the scope and atomically installs positioned live delivery beside
    /// replay. History owns positions; this stream carries them to consumers.
    internal func subscribePositioned(
        scope: SemanticObservationScope,
        replayingAfter historyIndex: Int,
        delivery: EventDelivery = .all,
        receive: @escaping @MainActor (Publication.Entry) -> Void
    ) -> PositionedEventInstallation {
        precondition(
            eventReceiver == nil,
            "Only one observation event consumer may be active"
        )
        let subscription = subscribe(scope: scope)
        let replay = events(after: historyIndex).map { events in
            events.enumerated().map { offset, event in
                Publication.Entry(
                    historyIndex: historyIndex + offset,
                    event: event
                )
            }
        }
        eventReceiver = EventReceiver(
            subscriptionID: subscription.id,
            receive: receive,
            delivery: delivery,
            pending: [],
            nextIndex: 0,
            isDelivering: false
        )
        return PositionedEventInstallation(subscription: subscription, replay: replay)
    }

    internal func removeSubscription(_ id: UInt64) {
        scopePressure.removeSubscription(id)
        if eventReceiver?.subscriptionID == id {
            eventReceiver = nil
        }
        updateCycleDemand()
    }

    func publish(_ publication: Publication) {
        guard var receiver = eventReceiver else { return }
        receiver.pending.append(contentsOf: publication.entries.filter {
            if receiver.delivery == .all { return true }
            if case .noChange = $0.event { return true }
            return false
        })
        eventReceiver = receiver
        drain(subscriptionID: receiver.subscriptionID)
    }

    internal func activateExecutionDelivery(_ subscription: SemanticObservationSubscription) {
        guard var receiver = eventReceiver,
              receiver.subscriptionID == subscription.id
        else { return }
        receiver.delivery = .all
        eventReceiver = receiver
    }

    private func drain(subscriptionID: UInt64) {
        guard var receiver = eventReceiver,
              receiver.subscriptionID == subscriptionID,
              !receiver.isDelivering
        else { return }
        receiver.isDelivering = true
        eventReceiver = receiver
        while let current = eventReceiver,
              current.subscriptionID == subscriptionID,
              current.isDelivering {
            guard current.nextIndex < current.pending.count else {
                receiver = current
                receiver.pending = []
                receiver.nextIndex = 0
                receiver.isDelivering = false
                eventReceiver = receiver
                return
            }
            let event = current.pending[current.nextIndex]
            receiver = current
            receiver.nextIndex += 1
            eventReceiver = receiver
            current.receive(event)
        }
    }

    /// Keeps committed semantic truth readable while requiring a fresh
    /// observation before it can be admitted to a waiter.
    func invalidateCurrentAdmission() {
        vault.state.invalidateCurrentAdmission()
    }

    /// Runs `movement` with every reading taken during it attributed to the
    /// viewport movement it drives. A movement reached from inside another one
    /// is already covered, and the claim ends where the outermost one does.
    internal func movingViewport<Value>(_ movement: () async -> Value) async -> Value {
        activeViewportMovementCount += 1
        defer { activeViewportMovementCount -= 1 }
        return await movement()
    }

    internal func beginActiveObservationDemand() -> SemanticObservationDemand {
        let demand = SemanticObservationDemand(
            id: scopePressure.addActiveDemand(),
            stream: self
        )
        updateCycleDemand()
        return demand
    }

    internal func removeActiveObservationDemand(_ id: UInt64) {
        scopePressure.removeActiveDemand(id)
        updateCycleDemand()
    }

    internal func currentTripwireSignal() -> TheTripwire.TripwireSignal {
        readTripwireSignal()
    }

    private func updateCycleDemand() {
        let scope = cycle.isRunning
            ? scopePressure.demandedObservationScope
            : nil
        tripwire.setObservationPulseDemand(
            cycle.demand(scope: scope, pulseDemand: pulseDemand)
        )
    }

    /// Delivers one already-sampled pulse into the semantic observation cycle.
    ///
    /// This boundary owns no UIKit traversal or clock sampling; production
    /// receives display-link readings and deterministic callers author the same
    /// value directly.
    internal func deliver(_ pulse: TheTripwire.PulseReading) {
        let pulse = TheTripwire.PulseReading(
            tick: pulse.tick,
            elapsed: pulse.elapsed,
            tripwireSignal: pulse.tripwireSignal.recordingAccessibilityNotifications(
                through: vault.accessibilityNotifications.latestSequence
            )
        )
        cycle.receive(pulse) { [weak self] request in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.performObservationCycle(request)
                self.finishCycle(request.identity, result: result)
            }
        }
    }

    private func finishCycle(
        _ identity: SemanticObservationCycle.Identity,
        result: CycleResult?
    ) {
        guard let completedScope = cycle.complete(identity) else {
            return
        }
        let observationCommitted = result?.observationCommitted == true
        if observationCommitted, let result {
            precondition(
                result.claim.acknowledgeObservationCycle(),
                "A committed observation must acknowledge its exact notification claim"
            )
        }
        completeObservationWaiters(
            completedScope: completedScope,
            observationCommitted: observationCommitted
        )
    }

    private func performObservationCycle(
        _ request: SemanticObservationCycle.Request
    ) async -> CycleResult? {
        guard cycle.owns(request.identity) else {
            return nil
        }
        let claim = vault.accessibilityNotifications.freezeObservationCycleClaim()
        let committed = await observeSemanticState(
            scope: request.scope,
            pulse: request.pulse,
            notificationBatch: claim.batch
        )
        return CycleResult(
            claim: claim,
            observationCommitted: committed && cycle.owns(request.identity)
        )
    }

    /// One pulse, one reading, committed either way.
    ///
    /// Returning early when the admitted observation still holds looks free and
    /// is not: "nothing changed" is the answer stillness waits for, and skipping
    /// the read makes it unobtainable. The next reading only arrives when the
    /// tree moves, so a tree that reached the asked-for state and stayed there
    /// would never say so, and every expectation with a drained predicate would
    /// time out waiting for the tree to stop changing.
    private func observeSemanticState(
        scope: SemanticObservationScope,
        pulse: TheTripwire.PulseReading,
        notificationBatch: AccessibilityNotificationBatch
    ) async -> Bool {
        invalidateAdmissionIfSignalChanged(to: pulse.tripwireSignal)
        guard !Task.isCancelled else { return false }
        return await commitCurrentInterfaceObservation(
            tripwireSignal: pulse.tripwireSignal,
            scope: scope,
            notificationBatch: notificationBatch
        ).isCommitted
    }

    func invalidateAdmissionIfSignalChanged(to signal: TheTripwire.TripwireSignal) {
        vault.state.invalidateAdmissionIfSignalChanged(to: signal)
    }

    internal func events(
        after historyIndex: Int
    ) -> Result<[Observation.Event], Observation.History.ReadError> {
        do {
            return .success(Array(
                try vault.state.history.events(after: historyIndex)
            ))
        } catch {
            return .failure(error)
        }
    }

    internal func observationBoundary(
        scope: SemanticObservationScope
    ) -> TheVault.State.HistoryBoundary {
        vault.state.observationBoundary(scope: scope)
    }

    internal func protectHistory(from index: Int) {
        vault.state.protectHistory(from: index)
    }

    internal func releaseHistory(from index: Int) {
        vault.state.releaseHistory(from: index)
    }

    internal func advanceHistoryProtection(
        from index: Int,
        to nextIndex: Int
    ) {
        vault.state.advanceHistoryProtection(from: index, to: nextIndex)
    }

}
}

#endif // DEBUG
#endif // canImport(UIKit)
