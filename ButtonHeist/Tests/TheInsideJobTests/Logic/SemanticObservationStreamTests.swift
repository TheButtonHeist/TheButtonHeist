#if canImport(UIKit)
#if DEBUG
import Foundation
import XCTest

@testable import TheInsideJob
@testable import TheScore

@MainActor
final class SemanticObservationStreamTests: XCTestCase {
    private var vault: TheVault!
    private let signalWindow = NSObject()

    override func setUp() async throws {
        vault = TheVault(tripwire: TheTripwire(), pulseIngress: .injected)
    }

    override func tearDown() async throws {
        vault.semanticObservationStream.stop()
        vault = nil
    }

    func testIdleStreamDoesNotReadAccessibility() {
        let source = VisibleObservationSourceFixture(observation: .empty)
        let tripwire = TheTripwire()
        let idleVault = TheVault(
            tripwire: tripwire,
            visibleObservationSource: source.capture,
            pulseIngress: .injected
        )
        defer {
            idleVault.semanticObservationStream.stop()
        }
        idleVault.semanticObservationStream.start()

        idleVault.semanticObservationStream.deliver(pulse(tick: 1))
        idleVault.semanticObservationStream.deliver(pulse(tick: 2))

        XCTAssertEqual(source.captureCount, 0)
    }

    func testExplicitPulseDeliveryCommitsOneObservationCycleWithoutReadingLiveSignal() async {
        let source = VisibleObservationSourceFixture(observation: .empty)
        let tripwire = TheTripwire()
        let demandedVault = TheVault(
            tripwire: tripwire,
            visibleObservationSource: source.capture,
            pulseIngress: .injected
        )
        defer {
            demandedVault.semanticObservationStream.stop()
        }
        let stream = demandedVault.semanticObservationStream
        stream.start()
        var liveSignalReadCount = 0
        stream.readTripwireSignal = {
            liveSignalReadCount += 1
            return .empty
        }
        let historyIndex = demandedVault.state.history.endIndex
        let subscription = stream.subscribe(scope: .visible)
        defer { subscription.cancel() }

        let reading = pulse(
            tick: 7,
            elapsed: .milliseconds(250),
            signal: tripwireSignal(sequence: 0)
        )
        stream.deliver(reading)
        let result = await stream.waitForObservation(
            after: historyIndex,
            scope: .visible,
            boundary: .observationCycle
        )

        guard case .observation(let current) = result else {
            return XCTFail("Expected one committed observation, got \(result)")
        }
        XCTAssertEqual(source.captureCount, 1)
        XCTAssertEqual(liveSignalReadCount, 0)
        XCTAssertEqual(
            current.snapshot.context.windowStack,
            [Observation.WindowContext(index: 0, level: 3, isKeyWindow: true)]
        )
        XCTAssertEqual(reading, pulse(
            tick: 7,
            elapsed: .milliseconds(250),
            signal: tripwireSignal(sequence: 0)
        ))
        XCTAssertNotEqual(
            reading,
            pulse(
                tick: 8,
                elapsed: .milliseconds(250),
                signal: tripwireSignal(sequence: 0)
            )
        )
    }

    func testSubscriptionPublishesVaultHistoryInAuthoredOrder() async throws {
        let stream = vault.semanticObservationStream
        let beforeReceipt = await capturePublication(in: vault) {
            await stream.commitVisibleObservationForTesting(.empty)
        }
        let before = beforeReceipt.publication
        var received: [Observation.Event] = []

        let installation = stream.subscribePositioned(
            scope: .visible,
            replayingAfter: 0,
            receive: { received.append($0.event) }
        )
        let subscription = installation.subscription
        received.append(contentsOf: try installation.replay.get().map(\.event))
        stream.discardCurrentObservation()
        let duringReceipt = await capturePublication(in: vault) {
            await stream.commitVisibleObservationForTesting(.empty)
        }
        let during = duringReceipt.publication
        let expected = before.events + during.events
        let current = vault.state.current
        let history = try stream.events(after: 0).get()

        XCTAssertEqual(received, expected)
        XCTAssertEqual(
            duringReceipt.historyRange,
            beforeReceipt.historyRange.upperBound..<(beforeReceipt.historyRange.upperBound + during.events.count)
        )
        XCTAssertEqual(current, during.current)
        XCTAssertEqual(history, expected)

        subscription.cancel()
        let afterCancellation = await stream.commitVisibleObservationForTesting(.empty)
        let currentAfterCancellation = vault.state.current
        let historyAfterCancellation = try stream.events(after: 0).get()

        XCTAssertEqual(received, expected)
        XCTAssertEqual(currentAfterCancellation, afterCancellation.current)
        XCTAssertEqual(historyAfterCancellation, expected + afterCancellation.events)
    }

    private func pulse(
        tick: UInt64,
        elapsed: Duration = .zero,
        signal: TheTripwire.TripwireSignal = .empty
    ) -> TheTripwire.PulseReading {
        TheTripwire.PulseReading(
            tick: tick,
            elapsed: elapsed,
            tripwireSignal: signal
        )
    }

    private func tripwireSignal(sequence: UInt64) -> TheTripwire.TripwireSignal {
        TheTripwire.TripwireSignal(
            topmostVC: nil,
            navigation: .empty,
            windowStack: TheTripwire.WindowStackSignal(windows: [
                TheTripwire.WindowSignal(
                    id: ObjectIdentifier(signalWindow),
                    level: 3,
                    isKeyWindow: true
                ),
            ]),
            accessibilityNotificationSequence: sequence
        )
    }
}
#endif // DEBUG
#endif // canImport(UIKit)
