import ButtonHeistTestSupport
import Foundation
import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

final class TheHandoffConnectionWaitIsolationTests: XCTestCase {

    @ButtonHeistActor
    func testWaitForConnectionResultPropagatesCancellationError() async {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let mock = MockConnection()
        mock.connectEventsOverride = []  // Stays in .connecting until cancelled
        handoff.makeConnection = { _ in mock }

        handoff.connect(to: device)

        let waitTask = Task { @ButtonHeistActor in
            try await handoff.waitForConnectionResult(timeout: 30)
        }

        // Yield so the continuation registers before we cancel.
        await Task.yield()
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
    func testCancellingOneWaiterDoesNotCancelSiblingWaiter() async throws {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let mock = MockConnection()
        mock.connectEventsOverride = []
        handoff.makeConnection = { _ in mock }

        handoff.connect(to: device)

        let cancelledWaitTask = Task { @ButtonHeistActor in
            try await handoff.waitForConnectionResult(timeout: 30)
        }
        let liveWaitTask = Task { @ButtonHeistActor in
            try await handoff.waitForConnectionResult(timeout: 30)
        }
        await Task.yield()

        cancelledWaitTask.cancel()
        do {
            try await cancelledWaitTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        mock.onEvent?(.connected)

        try await liveWaitTask.value
        assertConnected(handoff.connectionPhase, device: device)
    }

    @ButtonHeistActor
    func testShortTimeoutWaiterDoesNotPoisonLongWaiter() async throws {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let mock = MockConnection()
        mock.connectEventsOverride = []
        handoff.makeConnection = { _ in mock }

        handoff.connect(to: device)

        let shortWaitTask = Task { @ButtonHeistActor in
            try await handoff.waitForConnectionResult(timeout: 0.05)
        }
        let longWaitTask = Task { @ButtonHeistActor in
            try await handoff.waitForConnectionResult(timeout: 30)
        }
        await Task.yield()

        do {
            try await shortWaitTask.value
            XCTFail("Expected timeout")
        } catch let error as HandoffConnectionError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Expected timeout, got \(error)")
        }

        assertConnecting(handoff.connectionPhase, device: device)
        mock.onEvent?(.connected)

        try await longWaitTask.value
        assertConnected(handoff.connectionPhase, device: device)
    }

    @ButtonHeistActor
    func testWaitForConnectionResultResumesOnFailedTransition() async {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let mock = MockConnection()
        mock.connectEventsOverride = []
        handoff.makeConnection = { _ in mock }

        handoff.connect(to: device)

        let waitTask = Task { @ButtonHeistActor in
            try await handoff.waitForConnectionResult(timeout: 30)
        }

        // Yield so the continuation registers.
        await Task.yield()

        // Drive into .failed via an auth-failure server error.
        handoff.handleServerMessage(
            .error(ServerError(kind: .authFailure, message: "bad token")),
            requestId: nil
        )

        do {
            try await waitTask.value
            XCTFail("Expected auth failure")
        } catch let error as HandoffConnectionError {
            guard case .disconnected(.authFailed(let reason, hint: _)) = error else {
                return XCTFail("Expected auth-failed disconnect, got \(error)")
            }
            XCTAssertEqual(reason, "bad token")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @ButtonHeistActor
    func testTerminalConnectionFailureResolvesAllLiveWaitersForAttempt() async {
        let handoff = TheHandoff()
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let mock = MockConnection()
        mock.connectEventsOverride = []
        handoff.makeConnection = { _ in mock }

        handoff.connect(to: device)

        let firstWaitTask = Task { @ButtonHeistActor in
            try await handoff.waitForConnectionResult(timeout: 30)
        }
        let secondWaitTask = Task { @ButtonHeistActor in
            try await handoff.waitForConnectionResult(timeout: 30)
        }
        await Task.yield()

        mock.onEvent?(.disconnected(.missingToken))
        assertDisconnected(handoff.connectionPhase)

        for waitTask in [firstWaitTask, secondWaitTask] {
            do {
                try await waitTask.value
                XCTFail("Expected disconnect failure")
            } catch let error as HandoffConnectionError {
                XCTAssertEqual(error, .disconnected(.missingToken))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
