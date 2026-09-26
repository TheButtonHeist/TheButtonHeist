import ButtonHeistTestSupport
import Foundation
import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

final class TheHandoffConnectionWaitRegressionTests: XCTestCase {

    /// Regression test: an early synchronous cancel — before any `Task.yield()`
    /// — must propagate `CancellationError`. Without the early-cancel guard
    /// inside the continuation body, the cancellation handler hops to the
    /// actor and finds an empty awaiter list, then the body runs and appends
    /// the now-orphaned continuation, which only resolves on phase transition
    /// or timeout.
    @ButtonHeistActor
    func testWaitForConnectionResultPropagatesEarlyCancellation() async {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let mock = MockConnection()
        mock.connectEventsOverride = []  // Stay in .connecting indefinitely
        handoff.makeConnection = { _ in mock }

        handoff.connect(to: device)

        let waitTask = Task { @ButtonHeistActor in
            try await handoff.waitForConnectionResult(timeout: 30)
        }
        // Cancel synchronously, before any yield, so the cancel races with
        // continuation registration.
        waitTask.cancel()

        do {
            try await waitTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    /// Regression test: an idempotent `transitionToDisconnected` (when phase
    /// was already `.disconnected` or `.failed`) must not resume awaiters.
    /// We verify this by reaching .failed (which under the previous
    /// implementation also resumed awaiters from any prior phase), then
    /// confirming a subsequent disconnect() preserves the failed-phase
    /// expectation rather than triggering a second resume cycle.
    @ButtonHeistActor
    func testWaitForConnectionResultIgnoresIdempotentDisconnect() async throws {
        let handoff = TheHandoff()
        let serverError = ServerError(kind: .general, message: "boom")

        // Drive into .failed (server error) — this is a terminal phase.
        handoff.handleServerMessage(
            .error(serverError),
            requestId: nil
        )
        assertFailed(handoff.connectionPhase, failure: .serverFailure(serverError))

        // Calling disconnect() now is a no-op transition (.failed → .disconnected
        // is technically a phase change but, importantly, awaiters from any
        // prior wait are not re-resumed). It must be safe.
        handoff.disconnect()
        assertDisconnected(handoff.connectionPhase)

        // A second idempotent disconnect (.disconnected → .disconnected) must
        // also be safe and must not resume any awaiter.
        handoff.disconnect()
        assertDisconnected(handoff.connectionPhase)

        // Now register an awaiter — it should fast-path-throw on .disconnected,
        // not get a stale resume from the prior idempotent transitions.
        do {
            try await handoff.waitForConnectionResult(timeout: 30)
            XCTFail("Expected fast-path throw on .disconnected")
        } catch is HandoffConnectionError {
            // Expected.
        }
    }

}
