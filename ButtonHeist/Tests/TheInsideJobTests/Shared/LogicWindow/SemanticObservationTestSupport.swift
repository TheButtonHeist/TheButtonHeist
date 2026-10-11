#if canImport(UIKit)
@testable import TheInsideJob

extension Observation.Stream {
    @discardableResult
    func commitVisibleObservationForTesting(
        _ observation: InterfaceObservation
    ) async -> Observation.Publication {
        await commitObservationCycleForTesting(
            observation,
            scope: .visible,
            lineage: .resting
        )
    }

    @discardableResult
    func commitVisibleObservationForTesting(
        _ observation: InterfaceObservation,
        notificationBatch: AccessibilityNotificationBatch
    ) async -> Observation.Publication {
        requireCommittedObservation(
            commitObservation(
                observation,
                tripwireSignal: currentTripwireSignal(),
                lineage: .resting,
                scope: .visible,
                notificationBatch: notificationBatch
            )
        )
    }

    @discardableResult
    func commitDiscoveryObservationForTesting(
        _ observation: InterfaceObservation
    ) async -> Observation.Publication {
        await commitObservationCycleForTesting(
            observation,
            scope: .discovery,
            lineage: .resting
        )
    }

    @discardableResult
    func commitDiscoveryObservationForTesting(
        _ observation: InterfaceObservation,
        notificationBatch: AccessibilityNotificationBatch
    ) async -> Observation.Publication {
        requireCommittedObservation(
            commitObservation(
                observation,
                tripwireSignal: currentTripwireSignal(),
                lineage: .resting,
                scope: .discovery,
                notificationBatch: notificationBatch
            )
        )
    }

    @discardableResult
    func commitDiscoveryObservationAfterViewportMovementForTesting(
        _ observation: InterfaceObservation
    ) async -> Observation.Publication {
        await commitObservationCycleForTesting(
            observation,
            scope: .discovery,
            lineage: .viewportMovement
        )
    }

    private func commitObservationCycleForTesting(
        _ observation: InterfaceObservation,
        scope: SemanticObservationScope,
        lineage: ScreenLineage
    ) async -> Observation.Publication {
        let claim = vault.accessibilityNotifications.freezeObservationCycleClaim()
        let publication = requireCommittedObservation(
            commitObservation(
                observation,
                tripwireSignal: currentTripwireSignal(),
                lineage: lineage,
                scope: scope,
                notificationBatch: claim.batch
            )
        )
        precondition(
            claim.acknowledgeObservationCycle(),
            "A test observation cycle must acknowledge its exact notification claim"
        )
        return publication
    }

    private func requireCommittedObservation(
        _ result: Result<Observation.Publication, Observation.CaptureFailure>
    ) -> Observation.Publication {
        switch result {
        case .success(let publication):
            publication
        case .failure(let failure):
            preconditionFailure("Test observation was rejected: \(failure.diagnostic)")
        }
    }
}

extension TheVault {
    func installObservationForTesting(_ observation: InterfaceObservation) async {
        await semanticObservationStream.commitVisibleObservationForTesting(observation)
    }
}

@MainActor
final class VisibleObservationSourceFixture {
    private var observationSequence: [InterfaceObservation?]?
    private var unavailableCapturesRemaining = 0

    var observation: InterfaceObservation?
    private(set) var captureCount = 0

    init(observation: InterfaceObservation?) {
        self.observation = observation
    }

    init(sequence: [InterfaceObservation?]) {
        precondition(!sequence.isEmpty, "A scripted observation sequence must contain one capture")
        observation = nil
        observationSequence = sequence
    }

    func capture(from _: TheVault) -> InterfaceObservation? {
        captureCount += 1
        if unavailableCapturesRemaining > 0 {
            unavailableCapturesRemaining -= 1
            return nil
        }
        guard var sequence = observationSequence else {
            return observation
        }
        guard !sequence.isEmpty else {
            preconditionFailure("Unexpected visible observation capture at index \(captureCount)")
        }
        let captured = sequence.removeFirst()
        observationSequence = sequence
        return captured
    }

    func failNextCapture() {
        unavailableCapturesRemaining = 1
    }
}

@MainActor
final class TripwireInvalidationFixture {
    private let continuation: AsyncStream<Void>.Continuation
    private let invalidation: Task<Void, Never>

    init(vault: TheVault) {
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation
        invalidation = Task {
            for await _ in stream {
                vault.semanticObservationStream.invalidateCurrentAdmission()
                break
            }
        }
    }

    func signal() {
        continuation.yield()
        continuation.finish()
    }

    func wait() async {
        await invalidation.value
    }

    deinit {
        continuation.finish()
        invalidation.cancel()
    }
}

#endif
