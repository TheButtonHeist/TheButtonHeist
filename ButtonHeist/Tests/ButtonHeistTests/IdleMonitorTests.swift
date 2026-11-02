import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist

final class IdleMonitorTests: XCTestCase {

    @ButtonHeistActor
    func testActivitySuspendsTimerUntilLastActivityFinishes() async {
        let monitor = IdleMonitor(timeout: 60) { XCTFail("Active work must not expire") }
        defer { monitor.stop() }
        monitor.resetTimer()

        await monitor.withActivity {
            XCTAssertFalse(monitor.hasPendingTimer)
            await monitor.withActivity {
                monitor.resetTimer()
                XCTAssertFalse(monitor.hasPendingTimer)
            }
            XCTAssertFalse(monitor.hasPendingTimer)
        }

        XCTAssertTrue(monitor.hasPendingTimer)
    }

    @ButtonHeistActor
    func testThrowingActivityRearmsTimerButStopDoesNot() async {
        let monitor = IdleMonitor(timeout: .greatestFiniteMagnitude) { XCTFail("Unexpected expiry") }
        defer { monitor.stop() }
        do {
            try await monitor.withActivity { throw CancellationError() }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(monitor.hasPendingTimer)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await monitor.withActivity { monitor.stop() }
        XCTAssertFalse(monitor.hasPendingTimer)
    }

    @ButtonHeistActor
    func testTimeoutFiresAfterInactivity() async throws {
        let expectation = XCTestExpectation(description: "timeout fires")
        let monitor = IdleMonitor(timeout: 0.1) {
            expectation.fulfill()
        }
        monitor.resetTimer()
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    @ButtonHeistActor
    func testResetKeepsTimerPendingAndStopClearsIt() async {
        let monitor = IdleMonitor(timeout: 60) { /* never fires within test */ }

        monitor.resetTimer()
        XCTAssertTrue(monitor.hasPendingTimer, "First reset should schedule a timer")

        monitor.resetTimer()
        XCTAssertTrue(monitor.hasPendingTimer, "Second reset should schedule a new timer")

        monitor.stop()
        XCTAssertFalse(monitor.hasPendingTimer, "stop() should cancel the timer")
    }

    @ButtonHeistActor
    func testZeroTimeoutNeverSchedulesTimer() async {
        // With timeout == 0, resetTimer() short-circuits and never creates a
        // task. No need to wait — assert directly on the monitor's state.
        let monitor = IdleMonitor(timeout: 0) {
            XCTFail("Should not fire when timeout is zero")
        }
        monitor.resetTimer()
        XCTAssertFalse(monitor.hasPendingTimer, "Zero timeout must not schedule a task")
    }

}
