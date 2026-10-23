#if canImport(UIKit)
#if DEBUG
import Foundation
import XCTest

@testable import TheInsideJob

@MainActor
final class SemanticObservationCycleTests: XCTestCase {
    func testStartAndStopOwnCompleteLifecycle() {
        var cycle = SemanticObservationCycle()

        XCTAssertFalse(cycle.isRunning)
        XCTAssertTrue(cycle.start())
        XCTAssertTrue(cycle.isRunning)
        XCTAssertFalse(cycle.start())
        XCTAssertNotNil(cycle.stop())
        XCTAssertFalse(cycle.isRunning)
        XCTAssertNil(cycle.stop())
    }

    func testStopInvalidatesActiveIdentityAndReturnsCancellationEffect() throws {
        var cycle = SemanticObservationCycle()
        XCTAssertTrue(cycle.start())
        _ = cycle.demand(scope: .visible, pulseDemand: .immediate)
        let identity = try XCTUnwrap(cycle.receive(pulse(tick: 1)) { _ in
            Task {}
        })

        let stop = try XCTUnwrap(cycle.stop())

        XCTAssertNotNil(stop.activeTask)
        XCTAssertNil(cycle.complete(identity))
        XCTAssertFalse(cycle.owns(identity))
    }

    func testStaleCompletionCannotAcknowledgeOrRearmReplacementCycle() throws {
        var cycle = SemanticObservationCycle()
        XCTAssertTrue(cycle.start())
        _ = cycle.demand(scope: .visible, pulseDemand: .immediate)
        let staleIdentity = try XCTUnwrap(cycle.receive(pulse(tick: 1)) { _ in
            Task {}
        })
        let staleStop = try XCTUnwrap(cycle.stop())
        staleStop.activeTask?.cancel()

        XCTAssertTrue(cycle.start())
        _ = cycle.demand(scope: .visible, pulseDemand: .immediate)
        let replacementIdentity = try XCTUnwrap(
            cycle.receive(pulse(tick: 10)) { _ in Task {} }
        )

        XCTAssertNotEqual(staleIdentity, replacementIdentity)
        XCTAssertNil(cycle.complete(staleIdentity))
        XCTAssertTrue(cycle.owns(replacementIdentity))
        XCTAssertNil(cycle.receive(pulse(tick: 11)) { _ in Task {} })

        XCTAssertEqual(
            cycle.complete(replacementIdentity),
            .visible
        )
        XCTAssertFalse(cycle.owns(replacementIdentity))
        XCTAssertNotNil(cycle.receive(pulse(tick: 12)) { _ in Task {} })
    }

    func testBusyPulsesAreDroppedAndOnlyLaterPulseStartsWork() throws {
        var cycle = SemanticObservationCycle()
        var startedTicks: [UInt64] = []
        XCTAssertTrue(cycle.start())
        XCTAssertEqual(
            cycle.demand(scope: .visible, pulseDemand: .immediate),
            .immediate
        )

        let firstIdentity = try XCTUnwrap(
            cycle.receive(pulse(tick: 1)) { request in
                startedTicks.append(request.pulse.tripwireSignal.accessibilityNotificationSequence)
                return Task {}
            }
        )
        XCTAssertNil(cycle.receive(pulse(tick: 2)) { _ in Task {} })
        XCTAssertNil(cycle.receive(pulse(tick: 3)) { _ in Task {} })
        XCTAssertEqual(startedTicks, [1])

        XCTAssertNotNil(cycle.complete(firstIdentity))
        XCTAssertNotNil(cycle.receive(pulse(tick: 4)) { request in
            startedTicks.append(request.pulse.tripwireSignal.accessibilityNotificationSequence)
            return Task {}
        })
        XCTAssertEqual(startedTicks, [1, 4])
    }

    func testCompletionRearmsOnlyWhenDemandRemains() throws {
        var cycle = SemanticObservationCycle()
        XCTAssertTrue(cycle.start())
        _ = cycle.demand(scope: .visible, pulseDemand: .immediate)
        let identity = try XCTUnwrap(
            cycle.receive(pulse(tick: 1)) { _ in Task {} }
        )

        XCTAssertNil(cycle.demand(scope: nil, pulseDemand: .immediate))
        XCTAssertNotNil(cycle.complete(identity))
        XCTAssertNil(cycle.receive(pulse(tick: 2)) { _ in Task {} })

        XCTAssertEqual(
            cycle.demand(scope: .discovery, pulseDemand: .ambient),
            .ambient
        )
        let followUpIdentity = try XCTUnwrap(
            cycle.receive(pulse(tick: 3)) { request in
                XCTAssertEqual(request.scope, .discovery)
                return Task {}
            }
        )
        XCTAssertTrue(cycle.owns(followUpIdentity))
    }

    private func pulse(tick: UInt64) -> TheTripwire.PulseReading {
        TheTripwire.PulseReading(
            frameDuration: .milliseconds(16),
            tripwireSignal: .empty.recordingAccessibilityNotifications(through: tick)
        )
    }
}
#endif // DEBUG
#endif // canImport(UIKit)
