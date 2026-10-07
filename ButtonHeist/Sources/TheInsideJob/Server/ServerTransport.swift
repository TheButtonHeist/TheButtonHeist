import Foundation
import Network

import ButtonHeistSupport
import TheScore

/// Ordered transport-level event emitted by `ServerTransport`.
enum TransportEvent: Sendable {
    case clientConnected(clientId: Int, remoteAddress: String?)
    case clientDisconnected(clientId: Int)
    case dataReceived(clientId: Int, data: Data, respond: SocketResponseHandler)
    case backlogOverflow(maxEvents: Int)
}

/// TLS-gated TCP transport plus one ordered event stream.
final class ServerTransport {
    enum Failure: Error, LocalizedError, Equatable, Sendable {
        case alreadyRunning
        case stopped

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "Server transport is already running."
            case .stopped:
                return "Server transport stopped before startup completed."
            }
        }
    }

    private struct StopOperation: Equatable, Sendable {
        let id: UUID
        let task: Task<Void, Never>

        static func == (lhs: StopOperation, rhs: StopOperation) -> Bool {
            lhs.id == rhs.id
        }
    }

    private struct StartOperation: Equatable {
        let id: UUID
        let completion: CompletionSignal

        static func == (lhs: StartOperation, rhs: StartOperation) -> Bool {
            lhs.id == rhs.id
        }
    }

    private enum Operation: Equatable {
        case none
        case start(StartOperation)
        case stop(StopOperation)
    }

    /// Maximum ordered transport events buffered while the consumer is busy.
    ///
    /// Backlog overflow is a transport failure, not a signal to keep allocating:
    /// the server stops and the caller can restart from a clean session.
    nonisolated static let eventStreamBufferLimit = 512

    /// The underlying TCP server (actor-isolated).
    nonisolated let server: SimpleSocketServer

    /// Token used to derive TLS pre-shared key material.
    private nonisolated let token: SessionAuthToken

    /// Tracks only in-flight transport operations. Listener state and resources
    /// belong to `SocketListenerRuntime`.
    @MainActor private var operation = Operation.none

    /// Bonjour advertisement lifecycle and TXT record state.
    @MainActor private let advertisement = BonjourAdvertisement()

    // MARK: - Event Stream

    /// Ordered event stream. Only one consumer should iterate it.
    nonisolated let transportEvents: Events
    private nonisolated let eventStream: EventStream

    /// The port the server is listening on (0 if not started).
    nonisolated var listeningPort: UInt16 {
        server.listeningPort
    }

    // MARK: - Init

    nonisolated init(
        token: SessionAuthToken,
        allowedScopes: Set<ConnectionScope> = ConnectionScope.all,
        serverDependencies: SimpleSocketServer.Dependencies = SimpleSocketServer.Dependencies()
    ) {
        self.token = token
        let eventStream = EventStream(bufferLimit: Self.eventStreamBufferLimit)
        self.eventStream = eventStream
        self.transportEvents = eventStream.events
        self.server = SimpleSocketServer(
            allowedScopes: allowedScopes,
            callbacks: eventStream.makeCallbacks(),
            dependencies: serverDependencies
        )
    }

    // No deinit needed: ServerTransport is owned by the TheInsideJob singleton
    // (which never deallocates). All cleanup runs through stop(). NWListener and
    // NWConnection self-clean when references are released.

    // MARK: - Lifecycle

    @MainActor
    @discardableResult
    func start(
        port: UInt16 = 0,
        bindToLoopback: Bool = false,
        addressFamily: ListenerAddressFamily = .dualStack
    ) async throws -> UInt16 {
        if case .stop(let attempt) = operation {
            await attempt.task.value
        }

        switch operation {
        case .none:
            break
        case .start:
            throw Failure.alreadyRunning
        case .stop:
            throw Failure.stopped
        }

        let params = ButtonHeistTLSPreSharedKey.networkParameters(from: token.description)
        let attempt = StartOperation(
            id: UUID(),
            completion: CompletionSignal()
        )
        operation = .start(attempt)
        defer { finishStarting(attempt) }

        do {
            guard operation == .start(attempt) else {
                throw Failure.stopped
            }
            let actualPort = try await server.startAsync(
                port: port,
                bindToLoopback: bindToLoopback,
                addressFamily: addressFamily,
                tlsParameters: params
            )
            guard operation == .start(attempt) else {
                await server.stop()
                throw Failure.stopped
            }
            return actualPort
        } catch SimpleSocketServer.StartupError.alreadyRunning {
            throw Failure.alreadyRunning
        } catch {
            if case .stop = operation, error is CancellationError {
                throw Failure.stopped
            }
            throw error
        }
    }

    @MainActor
    internal func makeCallbacks() -> SocketServerCallbacks {
        eventStream.makeCallbacks()
    }

    /// Stop the TCP server and any Bonjour advertisement.
    @MainActor
    func stop() async {
        advertisement.stop()

        let stopOperation: StopOperation
        switch operation {
        case .start(let startOperation):
            stopOperation = beginStopping(waitingFor: startOperation.completion)
        case .stop(let existingOperation):
            stopOperation = existingOperation
        case .none:
            stopOperation = beginStopping(waitingFor: nil)
        }
        await stopOperation.task.value
    }

    @MainActor
    private func finishStarting(_ startOperation: StartOperation) {
        startOperation.completion.finish()
        guard case .start(let currentOperation) = operation,
              currentOperation == startOperation
        else { return }
        operation = .none
    }

    @MainActor
    @discardableResult
    private func beginStopping(
        waitingFor startCompletion: CompletionSignal?
    ) -> StopOperation {
        let id = UUID()
        let task = Task { @MainActor [weak self, server] in
            await server.stop()
            if let startCompletion {
                await startCompletion.wait()
            }
            self?.finishStopping(id: id)
        }
        let stopOperation = StopOperation(id: id, task: task)
        operation = .stop(stopOperation)
        return stopOperation
    }

    @MainActor
    private func finishStopping(id: UUID) {
        guard case .stop(let stopOperation) = operation,
              stopOperation.id == id
        else { return }
        operation = .none
    }

    // MARK: - Bonjour Advertisement

    @MainActor
    func advertise(
        serviceName: String,
        simulatorUDID: String? = nil,
        installationId: String? = nil,
        instanceId: String? = nil,
        additionalTXT: [String: String] = [:]
    ) {
        advertisement.publish(
            serviceName: serviceName,
            port: server.listeningPort,
            simulatorUDID: simulatorUDID,
            installationId: installationId,
            instanceId: instanceId,
            additionalTXT: additionalTXT
        )
    }

    @MainActor
    func updateTXTRecord(_ entries: [String: String]) {
        advertisement.updateTXTRecord(entries)
    }

    @MainActor
    var isAdvertisingForTesting: Bool {
        advertisement.isAdvertising
    }

}
