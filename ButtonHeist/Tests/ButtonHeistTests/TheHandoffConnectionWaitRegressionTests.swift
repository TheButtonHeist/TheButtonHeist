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

    @ButtonHeistActor
    func testRepeatedDisconnectAfterFailureKeepsDisconnectedFastPath() async throws {
        let handoff = TheHandoff()
        let serverError = ServerError(kind: .general, message: "boom")

        // Drive into .failed (server error) — this is a terminal phase.
        handoff.handleServerMessage(
            .error(serverError),
            requestId: nil
        )
        assertFailed(handoff.connectionPhase, failure: .serverFailure(serverError))

        handoff.disconnect()
        assertDisconnected(handoff.connectionPhase)

        handoff.disconnect()
        assertDisconnected(handoff.connectionPhase)

        do {
            try await handoff.waitForConnectionResult(timeout: 30)
            XCTFail("Expected fast-path throw on .disconnected")
        } catch is HandoffConnectionError {
            // Expected.
        }
    }

}
