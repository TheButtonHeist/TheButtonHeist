#if canImport(UIKit)
#if DEBUG
import Network
import XCTest

import ButtonHeistSupport
@testable import TheInsideJob

@MainActor
final class SocketListenerRuntimeLifecycleTests: XCTestCase {
    func testRuntimeOwnsListenerLifecycle() async throws {
        let runtime = SocketListenerRuntime()
        let gate = ListenerRuntimeStartGate()
        let listeners = TestSocketListenerProvider { _ in
            await gate.enterAndWaitForRelease()
            return .ready(2468)
        }

        let startTask = Task { @MainActor in
            try await Self.start(runtime, with: listeners)
        }
        await gate.waitUntilEntered()
        let acceptsWhileStarting = await runtime.isAcceptingConnections()

        gate.release()
        let port = try await startTask.value
        let acceptsWhileListening = await runtime.isAcceptingConnections()

        await runtime.stop()
        let acceptsAfterStop = await runtime.isAcceptingConnections()

        XCTAssertFalse(acceptsWhileStarting)
        XCTAssertEqual(port, 2468)
        XCTAssertTrue(acceptsWhileListening)
        XCTAssertFalse(acceptsAfterStop)
    }

    func testRepeatedStartStopInvalidatesCallbacksAndReleasesListeners() async throws {
        let listeners = TestSocketListenerProvider(port: 2468)

        for iteration in 1...3 {
            let runtime = SocketListenerRuntime()
            _ = try await Self.start(runtime, with: listeners)
            await runtime.stop()
            XCTAssertEqual(listeners.cancellationCount, iteration)
            XCTAssertEqual(listeners.retainedListenerCount, 0)
        }
    }

    func testRuntimeRejectsSecondStartWhileStarting() async throws {
        let runtime = SocketListenerRuntime()
        let gate = ListenerRuntimeStartGate()
        let listeners = TestSocketListenerProvider { _ in
            await gate.enterAndWaitForRelease()
            return .ready(2468)
        }
        let startTask = Task { @MainActor in
            try await Self.start(runtime, with: listeners)
        }
        await gate.waitUntilEntered()

        do {
            _ = try await Self.start(runtime, with: TestSocketListenerProvider(port: 9753))
            XCTFail("Expected the runtime to reject a second start")
        } catch is CancellationError {
            // The runtime has one irreversible lifecycle.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        gate.release()
        _ = try await startTask.value
        await runtime.stop()
    }

    func testStopDuringStartPreventsStaleListeningTransition() async {
        let runtime = SocketListenerRuntime()
        let gate = ListenerRuntimeStartGate()
        let listeners = TestSocketListenerProvider { _ in
            await gate.enterAndWaitForRelease()
            return .ready(2468)
        }
        let startTask = Task { @MainActor in
            try await Self.start(runtime, with: listeners)
        }
        await gate.waitUntilEntered()

        await runtime.stop()
        gate.release()

        do {
            _ = try await startTask.value
            XCTFail("Expected stopped startup to reject its stale completion")
        } catch is CancellationError {
            // Expected: only the runtime may transition itself to listening.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let isAcceptingConnections = await runtime.isAcceptingConnections()
        XCTAssertFalse(isAcceptingConnections)
    }

    func testStaleReadyCallbackCannotAttachToReplacementGeneration() async throws {
        let listeners = TestSocketListenerProvider(port: 24_680)
        let server = SimpleSocketServer(dependencies: .init(
            listenerProvider: listeners.listenerProvider
        ))

        _ = try await server.startPlaintext(addressFamily: .ipv4)
        let currentStaleGeneration = await server.currentListener
        let staleGeneration = try XCTUnwrap(currentStaleGeneration)
        let staleConnection = makeConnection()
        XCTAssertTrue(staleGeneration.own(staleConnection))

        await server.stop()
        _ = try await server.startPlaintext(addressFamily: .ipv4)
        let currentReplacementGeneration = await server.currentListener
        let replacementGeneration = try XCTUnwrap(currentReplacementGeneration)
        let acceptance = await server.acceptReadyConnection(
            staleConnection,
            generation: staleGeneration
        )
        let staleIsCurrent = await server.isCurrentListeningGeneration(staleGeneration)
        let replacementIsCurrent = await server.isCurrentListeningGeneration(replacementGeneration)
        let clientCount = await server.clientCountForTesting

        XCTAssertNotEqual(staleGeneration, replacementGeneration)
        XCTAssertEqual(acceptance, .rejected)
        XCTAssertFalse(staleIsCurrent)
        XCTAssertTrue(replacementIsCurrent)
        XCTAssertEqual(clientCount, 0)
        await server.stop()
    }

    func testConcurrentReadyConnectionsCannotExceedCapacity() async throws {
        let listeners = TestSocketListenerProvider(port: 24_680)
        let server = SimpleSocketServer(dependencies: .init(
            sendContent: { _, _, completion in
                guard case .contentProcessed(let handler) = completion else { return }
                handler(nil)
            },
            listenerProvider: listeners.listenerProvider
        ))
        _ = try await server.startPlaintext(addressFamily: .ipv4)
        let currentGeneration = await server.currentListener
        let generation = try XCTUnwrap(currentGeneration)
        let connections = (0...SimpleSocketServer.maxConnections).map { _ in makeConnection() }
        connections.forEach { XCTAssertTrue(generation.own($0)) }

        let acceptances = await withTaskGroup(
            of: ReadyConnectionAcceptance.self,
            returning: [ReadyConnectionAcceptance].self
        ) { group in
            for connection in connections {
                group.addTask {
                    await server.acceptReadyConnection(connection, generation: generation)
                }
            }
            var acceptances: [ReadyConnectionAcceptance] = []
            for await acceptance in group {
                acceptances.append(acceptance)
            }
            return acceptances
        }

        let registeredClientIds = acceptances.compactMap { acceptance -> Int? in
            guard case .registered(let clientId) = acceptance else { return nil }
            return clientId
        }
        XCTAssertEqual(registeredClientIds.count, SimpleSocketServer.maxConnections)
        XCTAssertEqual(Set(registeredClientIds).count, SimpleSocketServer.maxConnections)
        XCTAssertEqual(acceptances.filter { $0 == .rejected }.count, 1)
        let clientCount = await server.clientCountForTesting
        XCTAssertEqual(clientCount, SimpleSocketServer.maxConnections)
        await server.stop()
    }

    func testPartialDualListenerStartupFailureCleansPendingCallbacksAndConnections() async {
        let failureGate = ListenerRuntimeFailureGate()
        let listeners = TestSocketListenerProvider { invocation in
            guard invocation > 1 else { return .ready(24_680) }
            await failureGate.enterAndWaitForRelease()
            return .failed(.posix(.EADDRINUSE))
        }
        let pendingConnection = makeConnection()
        let admissionConnection = makeConnection()
        let server = SimpleSocketServer(dependencies: .init(
            listenerProvider: listeners.listenerProvider
        ))

        let startTask = Task { @MainActor in
            try await server.startPlaintext(bindToLoopback: true, addressFamily: .dualStack)
        }
        await failureGate.waitUntilEntered()
        guard let generation = await server.currentListener else {
            return XCTFail("Expected an active listener generation")
        }
        let ownsPendingConnection = generation.own(pendingConnection)
        let ownsAdmissionConnection = generation.own(admissionConnection)
        let acceptance = await server.acceptReadyConnection(
            admissionConnection,
            generation: generation
        )
        failureGate.release()

        do {
            _ = try await startTask.value
            XCTFail("Expected partial dual-listener startup to fail")
        } catch let error as NWError {
            XCTAssertEqual(error, .posix(.EADDRINUSE))
        } catch {
            XCTFail("Expected NWError, got \(error)")
        }

        let clientCount = await server.clientCountForTesting
        XCTAssertTrue(ownsPendingConnection)
        XCTAssertTrue(ownsAdmissionConnection)
        XCTAssertEqual(acceptance, .rejected)
        XCTAssertEqual(clientCount, 0)
    }

    private static func start(
        _ runtime: SocketListenerRuntime,
        with listeners: TestSocketListenerProvider
    ) async throws -> UInt16 {
        try await runtime.start(
            port: 0,
            bindToLoopback: true,
            addressFamily: .ipv4,
            parameters: .tcp,
            queue: DispatchQueue(label: "SocketListenerRuntimeLifecycleTests"),
            listenerProvider: listeners.listenerProvider,
            newConnectionHandler: { _ in }
        )
    }

    private func makeConnection() -> NWConnection {
        NWConnection(
            host: .ipv6(.loopback),
            port: NWEndpoint.Port(rawValue: 9)!,
            using: .tcp
        )
    }
}

private final class ListenerRuntimeStartGate: Sendable {
    private let entered = CompletionSignal()
    private let released = CompletionSignal()

    func enterAndWaitForRelease() async {
        entered.finish()
        await released.wait()
    }

    func waitUntilEntered() async {
        await entered.wait()
    }

    func release() {
        released.finish()
    }
}

private final class ListenerRuntimeFailureGate: Sendable {
    private let entered = CompletionSignal()
    private let released = CompletionSignal()

    func enterAndWaitForRelease() async {
        entered.finish()
        await released.wait()
    }

    func waitUntilEntered() async {
        await entered.wait()
    }

    func release() {
        released.finish()
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
