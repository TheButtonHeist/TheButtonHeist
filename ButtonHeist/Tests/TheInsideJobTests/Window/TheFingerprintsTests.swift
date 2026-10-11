#if canImport(UIKit)
// The fingerprint lifecycle owns a scene-attached overlay window.
import XCTest
@testable import TheInsideJob

@MainActor
final class TheFingerprintsTests: XCTestCase {

    func testTrackingLifecycleCarriesOnlyPhaseValidData() {
        let scheduler = ManualFingerprintScheduler()
        let fingerprints = TheFingerprints(isEnabled: true, scheduler: scheduler)

        XCTAssertEqual(fingerprints.lifecycleSnapshot, .detached)

        fingerprints.beginTracking(at: [
            CGPoint(x: 10, y: 20),
            CGPoint(x: 30, y: 40),
        ])
        XCTAssertEqual(
            fingerprints.lifecycleSnapshot,
            .tracking(activeFingerprintCount: 2, pendingRetirementCount: 0)
        )

        fingerprints.updateTracking(to: [CGPoint(x: 50, y: 60)])
        XCTAssertEqual(
            fingerprints.lifecycleSnapshot,
            .tracking(activeFingerprintCount: 1, pendingRetirementCount: 0)
        )

        fingerprints.endTracking()
        XCTAssertEqual(fingerprints.lifecycleSnapshot, .idle(pendingRetirementCount: 1))
        XCTAssertTrue(fingerprints.activeFingerprintCenters.isEmpty)

        scheduler.runAll()
        XCTAssertEqual(fingerprints.lifecycleSnapshot, .idle(pendingRetirementCount: 0))
    }

    func testRepeatedBeginReplacesActiveSessionAndRepeatedEndIsIdempotent() {
        let scheduler = ManualFingerprintScheduler()
        let fingerprints = TheFingerprints(isEnabled: true, scheduler: scheduler)

        fingerprints.beginTracking(at: [
            CGPoint(x: 10, y: 10),
            CGPoint(x: 20, y: 20),
        ])
        fingerprints.beginTracking(at: [CGPoint(x: 30, y: 30)])

        XCTAssertEqual(fingerprints.activeFingerprintCenters, [CGPoint(x: 30, y: 30)])
        XCTAssertEqual(
            fingerprints.lifecycleSnapshot,
            .tracking(activeFingerprintCount: 1, pendingRetirementCount: 0)
        )

        fingerprints.endTracking()
        fingerprints.endTracking()

        XCTAssertEqual(fingerprints.lifecycleSnapshot, .idle(pendingRetirementCount: 1))
        scheduler.runAll()
        XCTAssertEqual(fingerprints.lifecycleSnapshot, .idle(pendingRetirementCount: 0))
    }

    func testRetirementCompletesWithoutEndingNewTrackingSession() {
        let scheduler = ManualFingerprintScheduler()
        let fingerprints = TheFingerprints(isEnabled: true, scheduler: scheduler)

        fingerprints.show(at: CGPoint(x: 10, y: 20))
        fingerprints.beginTracking(at: [CGPoint(x: 30, y: 40)])

        XCTAssertEqual(
            fingerprints.lifecycleSnapshot,
            .tracking(activeFingerprintCount: 1, pendingRetirementCount: 1)
        )

        scheduler.runAll()

        XCTAssertEqual(
            fingerprints.lifecycleSnapshot,
            .tracking(activeFingerprintCount: 1, pendingRetirementCount: 0)
        )
        XCTAssertEqual(fingerprints.activeFingerprintCenters, [CGPoint(x: 30, y: 40)])
    }

    func testMinimumDisplayDelayUsesInjectedMonotonicTime() throws {
        let scheduler = ManualFingerprintScheduler()
        let fingerprints = TheFingerprints(isEnabled: true, scheduler: scheduler)

        fingerprints.beginTracking(at: [CGPoint(x: 10, y: 20)])
        scheduler.now = 0.4
        fingerprints.endTracking()

        let fadeDelay = try XCTUnwrap(scheduler.scheduledDelays.last)
        XCTAssertEqual(fadeDelay, 0.1, accuracy: 0.000_001)
    }

    func testCallbacksAfterInvalidationCannotRestoreDiscardedState() throws {
        let scheduler = ManualFingerprintScheduler()
        let fingerprints = TheFingerprints(isEnabled: true, scheduler: scheduler)

        fingerprints.beginTracking(at: [CGPoint(x: 10, y: 20)])
        fingerprints.endTracking()
        let window = try XCTUnwrap(fingerprints.fingerprintWindow)
        XCTAssertEqual(fingerprints.lifecycleSnapshot, .idle(pendingRetirementCount: 1))

        fingerprints.invalidate()
        XCTAssertEqual(fingerprints.lifecycleSnapshot, .detached)
        XCTAssertNil(fingerprints.fingerprintWindow)
        XCTAssertTrue(window.isHidden)
        XCTAssertNil(window.rootViewController)
        XCTAssertTrue(fingerprints.activeFingerprintCenters.isEmpty)

        scheduler.runAll()

        XCTAssertEqual(fingerprints.lifecycleSnapshot, .detached)
        XCTAssertTrue(fingerprints.activeFingerprintCenters.isEmpty)
    }

    func testPendingCallbacksDoNotRetainFingerprints() {
        let scheduler = ManualFingerprintScheduler()
        var fingerprints: TheFingerprints? = TheFingerprints(isEnabled: true, scheduler: scheduler)
        weak let weakFingerprints = fingerprints

        fingerprints?.beginTracking(at: [CGPoint(x: 10, y: 20)])
        fingerprints?.endTracking()
        fingerprints = nil

        XCTAssertNil(weakFingerprints)
        scheduler.runAll()
        XCTAssertNil(weakFingerprints)
    }

    func testEmptyUpdateEndsActivePhaseWithoutLeavingRetirementData() {
        let scheduler = ManualFingerprintScheduler()
        let fingerprints = TheFingerprints(isEnabled: true, scheduler: scheduler)

        fingerprints.beginTracking(at: [CGPoint(x: 10, y: 20)])
        fingerprints.updateTracking(to: [])

        XCTAssertEqual(fingerprints.lifecycleSnapshot, .idle(pendingRetirementCount: 0))
        XCTAssertTrue(fingerprints.activeFingerprintCenters.isEmpty)
    }
}

@MainActor
private final class ManualFingerprintScheduler {
    private struct ScheduledAction {
        let deadline: CFTimeInterval
        let action: @MainActor @Sendable () -> Void
    }

    var now: CFTimeInterval = 0
    private var scheduledActions: [ScheduledAction] = []

    var scheduledDelays: [TimeInterval] {
        scheduledActions.map { $0.deadline - now }
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        scheduledActions.append(ScheduledAction(deadline: now + delay, action: action))
    }

    func runAll() {
        while !scheduledActions.isEmpty {
            scheduledActions.sort { $0.deadline < $1.deadline }
            let next = scheduledActions.removeFirst()
            now = max(now, next.deadline)
            next.action()
        }
    }
}

private extension TheFingerprints {
    convenience init(isEnabled: Bool, scheduler: ManualFingerprintScheduler) {
        self.init(
            isEnabled: isEnabled,
            now: { scheduler.now },
            schedule: { delay, action in scheduler.schedule(after: delay, action: action) }
        )
    }
}
#endif
