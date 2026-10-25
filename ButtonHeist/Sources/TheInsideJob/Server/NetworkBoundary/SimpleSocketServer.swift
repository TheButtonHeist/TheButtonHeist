import Foundation
import Network
import os

import ButtonHeistSupport
import TheScore

/// TCP server using Network framework.
/// Owns listener lifecycle and bridges Network callbacks into actor isolation.
/// Actor-isolated — all mutable state is protected by Swift concurrency.
private let logger = ButtonHeistLog.logger(.handoff(.server))

typealias SocketSendContent = @Sendable (
    _ connection: NWConnection,
    _ content: Data,
    _ completion: NWConnection.SendCompletion
) -> Void

actor SimpleSocketServer {
    struct Dependencies: Sendable {
        let sendContent: SocketSendContent
        let listenerProvider: SocketListenerProvider
        let listenerReadiness: @Sendable (isolated SocketListenerRuntime) async -> Bool

        init(
            sendContent: @escaping SocketSendContent = { connection, content, completion in
                connection.send(content: content, completion: completion)
            },
            listenerProvider: @escaping SocketListenerProvider = { parameters in
                try NetworkSocketListener(parameters: parameters)
            },
            listenerReadiness: @escaping @Sendable (isolated SocketListenerRuntime) async -> Bool = { runtime in
                runtime.isAcceptingConnections()
            }
        ) {
            self.sendContent = sendContent
            self.listenerProvider = listenerProvider
            self.listenerReadiness = listenerReadiness
        }
    }

    // MARK: - Actor-isolated mutable state

    private(set) var currentListener: SocketListenerGeneration?
    var clientRegistry = SocketClientRegistry()

    private let _syncListeningPort = OSAllocatedUnfairLock<UInt16>(initialState: 0)

    nonisolated var listeningPort: UInt16 {
        _syncListeningPort.withLock { $0 }
    }

    let callbacks: SocketServerCallbacks
    let dependencies: Dependencies

    /// Connection scopes the server will accept. Connections from disallowed scopes are rejected immediately.
    let allowedScopes: Set<ConnectionScope>

    private let queue = DispatchQueue(label: "com.buttonheist.thehandoff.server")
    init(
        allowedScopes: Set<ConnectionScope> = ConnectionScope.all,
        callbacks: SocketServerCallbacks = SocketServerCallbacks(),
        dependencies: Dependencies = Dependencies()
    ) {
        self.allowedScopes = allowedScopes
        self.callbacks = callbacks
        self.dependencies = dependencies
    }

    // MARK: - Public API (async, actor-isolated)

    /// Start the production server on the specified port with TLS.
    /// Uses structured concurrency to wait for the listener to become ready.
    /// - Parameters:
    ///   - port: Port to listen on (0 = any available)
    ///   - bindToLoopback: If true, bind to loopback only (simulator builds)
    ///   - addressFamily: Address family or families to bind.
    ///   - tlsParameters: Non-optional TLS parameters. Production startup must not fall back to plaintext.
    /// - Returns: Actual port number bound
    func startAsync(
        port: UInt16 = 0,
        bindToLoopback: Bool = false,
        addressFamily: ListenerAddressFamily = .dualStack,
        tlsParameters: NWParameters
    ) async throws -> UInt16 {
        return try await startListening(
            port: port,
            bindToLoopback: bindToLoopback,
            addressFamily: addressFamily,
            parameters: tlsParameters
        )
    }

    /// Start a plaintext listener for tests that exercise raw socket behavior.
    /// Production callers must use `startAsync(... tlsParameters:)`.
    func startPlaintext(
        port: UInt16 = 0,
        bindToLoopback: Bool = false,
        addressFamily: ListenerAddressFamily = .dualStack
    ) async throws -> UInt16 {
        try await startListening(
            port: port,
            bindToLoopback: bindToLoopback,
            addressFamily: addressFamily,
            parameters: .tcp
        )
    }

    private func startListening(
        port: UInt16,
        bindToLoopback: Bool,
        addressFamily: ListenerAddressFamily,
        parameters: NWParameters
    ) async throws -> UInt16 {
        guard currentListener == nil else {
            throw StartupError.alreadyRunning
        }

        let attemptID = UUID()
        let runtime = SocketListenerRuntime()
        let generation = SocketListenerGeneration(attemptID: attemptID, runtime: runtime)
        currentListener = generation

        do {
            let port = try await startListenerRuntime(
                generation: generation,
                port: port,
                bindToLoopback: bindToLoopback,
                addressFamily: addressFamily,
                parameters: parameters,
                queue: queue
            )

            guard await dependencies.listenerReadiness(runtime),
                  currentListener == generation
            else {
                throw CancellationError()
            }

            _syncListeningPort.withLock { $0 = port }
            return port
        } catch {
            if currentListener == generation {
                await clearListenerGenerationResources(generation)
            } else {
                await generation.runtime.stop()
            }
            if currentListener == generation {
                currentListener = nil
            }
            throw error
        }
    }

    private func startListenerRuntime(
        generation: SocketListenerGeneration,
        port: UInt16,
        bindToLoopback: Bool,
        addressFamily: ListenerAddressFamily,
        parameters: NWParameters,
        queue: DispatchQueue
    ) async throws -> UInt16 {
        let attemptID = generation.attemptID
        let runtime = generation.runtime
        return try await runtime.start(
            port: port,
            bindToLoopback: bindToLoopback,
            addressFamily: addressFamily,
            parameters: parameters,
            queue: queue,
            listenerProvider: dependencies.listenerProvider
        ) { [weak self, weak runtime, attemptID] connection in
            guard let runtime else {
                connection.cancel()
                return
            }
            let callbackGeneration = SocketListenerGeneration(
                attemptID: attemptID,
                runtime: runtime
            )
            guard callbackGeneration.own(connection) else { return }
            guard let self else {
                callbackGeneration.cancelIfOwned(connection)
                return
            }
            self.spawnTrackedTask(in: callbackGeneration) { server in
                await server.handleNewConnection(connection, generation: callbackGeneration)
            }
        }
    }

    /// Stop the server.
    func stop() async {
        guard let generation = currentListener else { return }
        await clearListenerGenerationResources(generation)
        if currentListener == generation {
            currentListener = nil
        }
    }

    private func clearListenerGenerationResources(_ generation: SocketListenerGeneration) async {
        _syncListeningPort.withLock { $0 = 0 }
        clientRegistry.cancelAll()
        await generation.runtime.stop()
    }

    /// Spawn a Task that bridges an `NWListener` / `NWConnection` callback
    /// into actor isolation, recording the handle so `stop()` can cancel
    /// it. The closure body runs on `SimpleSocketServer`'s actor.
    @discardableResult
    nonisolated func spawnTrackedTask(
        in generation: SocketListenerGeneration,
        _ body: @escaping @Sendable (SimpleSocketServer) async -> Void
    ) -> TaskTracker.Admission {
        generation.spawnCallbackTask { [weak self] in
            guard let self else { return }
            await body(self)
        }
    }

    // MARK: - Private

    private func handleNewConnection(
        _ connection: NWConnection,
        generation: SocketListenerGeneration
    ) async {
        guard await isCurrentListeningGeneration(generation) else {
            if !generation.cancelIfOwned(connection) {
                connection.cancel()
            }
            return
        }
        let admission = ConnectionAdmission()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            guard let self else {
                if !generation.cancelIfOwned(connection) {
                    connection.cancel()
                }
                return
            }
            switch state {
            case .ready:
                self.spawnTrackedTask(in: generation) { server in
                    guard admission.recordReady() == .accept else { return }
                    guard await server.revalidateReadyConnection(
                        connection,
                        generation: generation
                    ) else {
                        _ = admission.recordAcceptance(.rejected)
                        return
                    }
                    let acceptance = await server.acceptReadyConnection(
                        connection,
                        generation: generation
                    )
                    if case .removeRegisteredClient(let clientId) = admission.recordAcceptance(acceptance) {
                        await server.removeClient(clientId)
                    }
                }
            case .failed(let error):
                logger.error("Client connection failed: \(error)")
                generation.cancelIfOwned(connection)
                if case .removeRegisteredClient(let clientId) = admission.recordCancellation() {
                    self.spawnTrackedTask(in: generation) { server in await server.removeClient(clientId) }
                }
            case .cancelled:
                generation.cancelIfOwned(connection)
                if case .removeRegisteredClient(let clientId) = admission.recordCancellation() {
                    self.spawnTrackedTask(in: generation) { server in await server.removeClient(clientId) }
                }
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    func isCurrentListeningGeneration(_ generation: SocketListenerGeneration) async -> Bool {
        guard currentListener == generation else { return false }
        guard await generation.runtime.isAcceptingConnections() else { return false }
        return currentListener == generation
    }

    private func revalidateReadyConnection(
        _ connection: NWConnection,
        generation: SocketListenerGeneration
    ) async -> Bool {
        guard await isCurrentListeningGeneration(generation) else {
            if !generation.cancelIfOwned(connection) {
                connection.cancel()
            }
            return false
        }
        return true
    }

    // MARK: - Errors

    enum StartupError: Error, LocalizedError, Equatable {
        case failedToBindPort
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .failedToBindPort:
                return "Server failed to bind to a port"
            case .alreadyRunning:
                return "Server is already running"
            }
        }
    }
}
