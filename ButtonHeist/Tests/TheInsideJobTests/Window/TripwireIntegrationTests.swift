#if canImport(UIKit)
// Integration tests for TheTripwire that require a live UIWindowScene test host.
import XCTest
@testable import TheInsideJob

@MainActor
final class TripwireIntegrationTests: XCTestCase {

    private var tripwire: TheTripwire!

    override func setUp() async throws {
        tripwire = TheTripwire()
        tripwire.startPulse()
    }

    override func tearDown() async throws {
        tripwire.stopPulse()
        tripwire = nil
    }

    func testObservationDemandDeliversPulseAndRestoresAmbientRate() async throws {
        let context = try XCTUnwrap(tripwire.runningContext)
        let ambientRate = try XCTUnwrap(context.displayFrameRateRange)
        let observed = expectation(description: "observation pulse")
        var fulfilled = false
        tripwire.observePulses { _ in
            guard !fulfilled else { return }
            fulfilled = true
            observed.fulfill()
        }
        tripwire.setObservationPulseDemand(.immediate)
        XCTAssertNotEqual(context.displayFrameRateRange, ambientRate)

        await fulfillment(of: [observed], timeout: 1)
        tripwire.setObservationPulseDemand(nil)
        tripwire.stopObservingPulses()
        XCTAssertEqual(context.displayFrameRateRange, ambientRate)
    }

    func testImmediateTickRateIsCappedBelowScreenMaximum() {
        let range = TheTripwire.activeDisplayFrameRateRange(maximumFramesPerSecond: 120)

        XCTAssertEqual(range.minimum, 30)
        XCTAssertEqual(range.maximum, 30)
        XCTAssertEqual(range.preferred, 30)
    }

    // MARK: - Pulse produces readings

    func testPulseProducesReadingAfterStart() async throws {
        let reading = try await observeTick()
        XCTAssertGreaterThan(reading.frameDuration, .zero)
    }

    func testPulseReadingHasVisibleWindowSignal() async throws {
        let reading = try await observeTick()
        XCTAssertFalse(reading.tripwireSignal.windowStack.windows.isEmpty)
    }

    func testPulseReadingTracksVCIdentity() async throws {
        let reading = try await observeTick()
        // Test host should have a VC
        XCTAssertNotNil(reading.tripwireSignal.topmostVC)
    }

    private func observeTick() async throws -> TheTripwire.PulseReading {
        let observed = expectation(description: "observation pulse")
        var reading: TheTripwire.PulseReading?
        tripwire.observePulses { pulse in
            guard reading == nil else { return }
            reading = pulse
            observed.fulfill()
        }
        tripwire.setObservationPulseDemand(.ambient)
        await fulfillment(of: [observed], timeout: 1)
        tripwire.setObservationPulseDemand(nil)
        tripwire.stopObservingPulses()
        return try XCTUnwrap(reading, "The running display link should emit a pulse")
    }

}

#endif // canImport(UIKit)
