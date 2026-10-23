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
        await observeTick()
        let reading = try XCTUnwrap(tripwire.latestReading)
        XCTAssertGreaterThan(reading.tick, 0)
    }

    func testPulseReadingHasVisibleWindowSignal() async throws {
        await observeTick()
        let reading = try XCTUnwrap(tripwire.latestReading, "No reading produced")
        XCTAssertFalse(reading.tripwireSignal.windowStack.windows.isEmpty)
    }

    func testPulseReadingTracksVCIdentity() async throws {
        await observeTick()
        let reading = try XCTUnwrap(tripwire.latestReading, "No reading produced")
        // Test host should have a VC
        XCTAssertNotNil(reading.tripwireSignal.topmostVC)
    }

    private func observeTick(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let observed = expectation(description: "observation pulse")
        var fulfilled = false
        tripwire.observePulses { _ in
            guard !fulfilled else { return }
            fulfilled = true
            observed.fulfill()
        }
        tripwire.setObservationPulseDemand(.ambient)
        await fulfillment(of: [observed], timeout: 1)
        tripwire.setObservationPulseDemand(nil)
        tripwire.stopObservingPulses()
        XCTAssertNotNil(
            tripwire.latestReading,
            "The running display link should emit a pulse; \(latestPulseDiagnostic())",
            file: file,
            line: line
        )
    }

    private func latestPulseDiagnostic() -> String {
        guard let reading = tripwire.latestReading else {
            return "pulseRunning=\(tripwire.isPulseRunning) latestReading=nil"
        }
        return [
            "pulseRunning=\(tripwire.isPulseRunning)",
            "tick=\(reading.tick)",
            "windowCount=\(reading.tripwireSignal.windowStack.windows.count)",
            "topmostVC=\(String(describing: reading.tripwireSignal.topmostVC))",
        ].joined(separator: " ")
    }

}

#endif // canImport(UIKit)
