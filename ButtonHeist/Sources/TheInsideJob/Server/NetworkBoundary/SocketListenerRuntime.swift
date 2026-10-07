import Foundation
import Network
import os

import ButtonHeistSupport
import TheScore

protocol SocketListening: AnyObject, Sendable {
    var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)? { get set }
    var newConnectionHandler: (@Sendable (NWConnection) -> Void)? { get set }
    var port: NWEndpoint.Port? { get }

    func start(queue: DispatchQueue)
    func invalidate()
}

final class NetworkSocketListener: SocketListening, @unchecked Sendable {
    /// `@unchecked Sendable` justification: `NWListener` is the Network framework
    /// boundary object. `SocketListenerRuntime` owns listener lifecycle through
    /// one actor, and callback mutation is limited to the Network listener's
    /// documented queue-driven handlers.
    private let listener: NWListener
    private let isInvalidated = OSAllocatedUnfairLock(initialState: false)

    init(parameters: NWParameters) throws {
        listener = try NWListener(using: parameters)
    }

    var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)? {
        get { listener.stateUpdateHandler }
        set { listener.stateUpdateHandler = newValue }
    }

    var newConnectionHandler: (@Sendable (NWConnection) -> Void)? {
        get { listener.newConnectionHandler }
        set { listener.newConnectionHandler = newValue }
    }

    var port: NWEndpoint.Port? {
        listener.port
    }

    func start(queue: DispatchQueue) {
        listener.start(queue: queue)
    }

    func invalidate() {
        let shouldInvalidate = isInvalidated.withLock { isInvalidated in
            guard !isInvalidated else { return false }
            isInvalidated = true
            return true
        }
        guard shouldInvalidate else { return }
        let stateUpdateHandler = listener.stateUpdateHandler
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        stateUpdateHandler?(.cancelled)
        listener.cancel()
    }
}

typealias SocketListenerProvider = @Sendable (NWParameters) throws -> any SocketListening

struct SocketListenerGeneration: Equatable, Sendable {
    let attemptID: UUID
    let runtime: SocketListenerRuntime

    @discardableResult
    func spawnCallbackTask(
        _ operation: @escaping @Sendable () async -> Void
    ) -> TaskTracker.Admission {
        runtime.spawnCallbackTask(operation)
    }

    func own(_ connection: NWConnection) -> Bool {
        runtime.own(connection)
    }

    @discardableResult
    func cancelIfOwned(_ connection: NWConnection) -> Bool {
        runtime.cancelIfOwned(connection)
    }

    func transferToClientRegistry(_ connection: NWConnection) -> Bool {
        runtime.transferToClientRegistry(connection)
    }

}

private final class PendingSocketConnections: Sendable {
    /// `@unchecked Sendable` justification: the connection reference only crosses
    /// out of the lock so cancellation can run after the state transition.
    private struct OwnedConnection: @unchecked Sendable {
        let connection: NWConnection
    }

    private enum Phase {
        case accepting([ObjectIdentifier: NWConnection])
        case stopped
    }

    private let phase = OSAllocatedUnfairLock<Phase>(initialState: .accepting([:]))

    func own(_ connection: NWConnection) -> Bool {
        let accepted = phase.withLock { phase -> Bool in
            guard case .accepting(var connections) = phase else { return false }
            connections[ObjectIdentifier(connection)] = connection
            phase = .accepting(connections)
            return true
        }
        if !accepted {
            connection.cancel()
        }
        return accepted
    }

    func transfer(_ connection: NWConnection) -> Bool {
        phase.withLock { phase in
            guard case .accepting(var connections) = phase else { return false }
            let transferred = connections.removeValue(forKey: ObjectIdentifier(connection)) != nil
            phase = .accepting(connections)
            return transferred
        }
    }

    @discardableResult
    func cancelIfOwned(_ connection: NWConnection) -> Bool {
        let ownedConnection = phase.withLock { phase -> OwnedConnection? in
            guard case .accepting(var connections) = phase else { return nil }
            let owned = connections.removeValue(forKey: ObjectIdentifier(connection))
            phase = .accepting(connections)
            return owned.map(OwnedConnection.init(connection:))
        }
        ownedConnection?.connection.cancel()
        return ownedConnection != nil
    }

    func cancelAll() {
        let connections = phase.withLock { phase -> [OwnedConnection] in
            guard case .accepting(let connections) = phase else { return [] }
            phase = .stopped
            return connections.values.map(OwnedConnection.init(connection:))
        }
        connections.forEach { $0.connection.cancel() }
    }

}

actor SocketListenerRuntime: Equatable {
    private enum Phase {
        case idle
        case starting([any SocketListening])
        case listening([any SocketListening], port: UInt16)
        case stopped
    }

    nonisolated private let pendingConnections = PendingSocketConnections()
    nonisolated private let callbackTasks = TaskTracker()
    private let stopSignal = CompletionSignal()
    private var phase = Phase.idle

    nonisolated static func == (lhs: SocketListenerRuntime, rhs: SocketListenerRuntime) -> Bool {
        lhs === rhs
    }

    nonisolated fileprivate func own(_ connection: NWConnection) -> Bool {
        pendingConnections.own(connection)
    }

    @discardableResult
    nonisolated fileprivate func cancelIfOwned(_ connection: NWConnection) -> Bool {
        pendingConnections.cancelIfOwned(connection)
    }

    nonisolated fileprivate func transferToClientRegistry(_ connection: NWConnection) -> Bool {
        pendingConnections.transfer(connection)
    }

    nonisolated fileprivate func spawnCallbackTask(
        _ operation: @escaping @Sendable () async -> Void
    ) -> TaskTracker.Admission {
        callbackTasks.spawn(operation)
    }

    func stop() async {
        let listeners: [any SocketListening]
        switch phase {
        case .idle:
            listeners = []
        case .starting(let startingListeners), .listening(let startingListeners, _):
            listeners = startingListeners
        case .stopped:
            await stopSignal.wait()
            return
        }
        phase = .stopped
        pendingConnections.cancelAll()
        listeners.forEach { $0.invalidate() }
        await callbackTasks.drain()
        stopSignal.finish()
    }

    func isAcceptingConnections() -> Bool {
        guard case .listening = phase else { return false }
        return true
    }

    func start(
        port: UInt16,
        bindToLoopback: Bool,
        addressFamily: ListenerAddressFamily,
        parameters: NWParameters,
        queue: DispatchQueue,
        listenerProvider: SocketListenerProvider,
        newConnectionHandler: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> UInt16 {
        try beginStarting()

        let hosts = addressFamily.hosts(bindToLoopback: bindToLoopback)
        var requestedPort = port

        do {
            for host in hosts {
                let listener = try makeListener(
                    host: host,
                    port: requestedPort,
                    parameters: parameters,
                    allowEndpointReuse: hosts.count > 1,
                    listenerProvider: listenerProvider,
                    newConnectionHandler: newConnectionHandler
                )
                try append(listener)
                let actualPort = try await startAndWaitForReady(listener, queue: queue)
                try requireStarting()
                if requestedPort == 0 {
                    requestedPort = actualPort
                } else if actualPort != requestedPort {
                    throw SimpleSocketServer.StartupError.failedToBindPort
                }
            }

            guard requestedPort != 0 else {
                throw SimpleSocketServer.StartupError.failedToBindPort
            }
            try finishStarting(port: requestedPort)
            return requestedPort
        } catch {
            await stop()
            throw error
        }
    }

    private func beginStarting() throws {
        guard case .idle = phase else { throw CancellationError() }
        phase = .starting([])
    }

    private func finishStarting(port: UInt16) throws {
        guard case .starting(let listeners) = phase else { throw CancellationError() }
        phase = .listening(listeners, port: port)
    }

    private func append(_ listener: any SocketListening) throws {
        guard case .starting(var listeners) = phase else {
            listener.invalidate()
            throw CancellationError()
        }
        listeners.append(listener)
        phase = .starting(listeners)
    }

    private func requireStarting() throws {
        guard case .starting = phase else { throw CancellationError() }
    }

    private func makeListener(
        host: NWEndpoint.Host,
        port: UInt16,
        parameters: NWParameters,
        allowEndpointReuse: Bool,
        listenerProvider: SocketListenerProvider,
        newConnectionHandler: @escaping @Sendable (NWConnection) -> Void
    ) throws -> any SocketListening {
        let listenerParameters = parameters.copy()
        listenerParameters.allowLocalEndpointReuse = allowEndpointReuse
        listenerParameters.requiredLocalEndpoint = .hostPort(
            host: host,
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        let listener = try listenerProvider(listenerParameters)
        listener.newConnectionHandler = newConnectionHandler
        return listener
    }

    private func startAndWaitForReady(
        _ listener: any SocketListening,
        queue: DispatchQueue
    ) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    let shouldResume = resumed.withLock { flag -> Bool in
                        guard !flag else { return false }
                        flag = true
                        return true
                    }
                    guard shouldResume else { return }
                    if let port = listener?.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: SimpleSocketServer.StartupError.failedToBindPort)
                    }
                case .failed(let error):
                    let shouldResume = resumed.withLock { flag -> Bool in
                        guard !flag else { return false }
                        flag = true
                        return true
                    }
                    guard shouldResume else { return }
                    listener?.invalidate()
                    continuation.resume(throwing: error)
                case .cancelled:
                    let shouldResume = resumed.withLock { flag -> Bool in
                        guard !flag else { return false }
                        flag = true
                        return true
                    }
                    guard shouldResume else { return }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }
}

private extension ListenerAddressFamily {
    func hosts(bindToLoopback: Bool) -> [NWEndpoint.Host] {
        switch self {
        case .ipv4:
            return [bindToLoopback ? .ipv4(.loopback) : .ipv4(.any)]
        case .ipv6:
            return [bindToLoopback ? .ipv6(.loopback) : .ipv6(.any)]
        case .dualStack:
            if !bindToLoopback {
                // An all-interface Network listener is already dual-stack; a
                // second any-address listener on the same port collides.
                return [.ipv4(.any)]
            }
            return [
                .ipv4(.loopback),
                .ipv6(.loopback),
            ]
        }
    }
}
