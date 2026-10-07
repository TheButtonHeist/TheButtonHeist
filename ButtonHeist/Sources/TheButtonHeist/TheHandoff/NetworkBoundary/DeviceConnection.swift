import Foundation
import ButtonHeistSupport
import Network
import os.log

import TheScore

let deviceConnectionLogger = ButtonHeistLog.logger(.handoff(.connection))

/// Single ordered event emitted from an NWConnection's network-queue
/// callbacks. Routing both state updates and receive callbacks through one
/// stream means a `.cancelled` cannot land on the actor before a `.ready`
/// for the same connection — a race the prior per-event Task bridge could
/// lose during reconnect.
enum DeviceConnectionEvent: Sendable {
    case state(NWConnection.State, sessionID: UUID, connection: NWConnection)
    case received(DeviceReceiveEvent, sessionID: UUID, connection: NWConnection)
    case sendFailed(NWError, requestId: RequestID?, sessionID: UUID, connection: NWConnection)
}

/// Connection client using Network framework.
@ButtonHeistActor
final class DeviceConnection: DeviceConnecting, TransportReachabilityConnecting {
    enum DisconnectEvent {
        case local
        case failure(DisconnectReason)
    }

    private let device: DiscoveredDevice

    var onEvent: (@ButtonHeistActor (ConnectionEvent) -> Void)?
    var onTransportReady: (@ButtonHeistActor () -> Void)?
    var sendContent: (
        @Sendable (
            _ connection: NWConnection,
            _ content: Data,
            _ completion: NWConnection.SendCompletion
        ) -> Void
    ) = { connection, content, completion in
        connection.send(content: content, completion: completion)
    }

    private let token: SessionAuthToken?

    struct RuntimeSession {
        let id: UUID
        let connection: NWConnection
        var receiveFramer: NewlineDelimitedFramer

        /// Single consumer Task driving NW callbacks into the actor in order.
        /// Replaced on each `connect()`; cancelled when the owning session exits.
        var eventConsumerTask: Task<Void, Never>?

        /// Ordered callback bridge tied to this connection attempt.
        let eventStream: DeviceConnectionEventStream

        init(
            id: UUID = UUID(),
            connection: NWConnection,
            receiveFramer: NewlineDelimitedFramer = NewlineDelimitedFramer(),
            eventConsumerTask: Task<Void, Never>? = nil,
            eventStream: DeviceConnectionEventStream = DeviceConnectionEventStream()
        ) {
            self.id = id
            self.connection = connection
            self.receiveFramer = receiveFramer
            self.eventConsumerTask = eventConsumerTask
            self.eventStream = eventStream
        }

        func invalidate() {
            connection.stateUpdateHandler = nil
            eventStream.finish()
            eventConsumerTask?.cancel()
            connection.cancel()
        }
    }

    enum RuntimePhase {
        case disconnected
        case connecting(RuntimeSession)
        case connected(RuntimeSession)

        var session: RuntimeSession? {
            switch self {
            case .disconnected:
                return nil
            case .connecting(let session), .connected(let session):
                return session
            }
        }

        var sessionID: UUID? { session?.id }
        var connection: NWConnection? { session?.connection }

        func invalidate() {
            session?.invalidate()
        }
    }

    var runtimePhase: RuntimePhase = .disconnected

    init(device: DiscoveredDevice, token: SessionAuthToken? = nil) {
        self.device = device
        self.token = token
    }

    func connect() {
        transitionToDisconnected(.local)

        guard let token else {
            deviceConnectionLogger.error("No TLS token available — refusing connection")
            transitionToDisconnected(.failure(.missingToken))
            return
        }

        let parameters = ButtonHeistTLSPreSharedKey.networkParameters(from: token.description)

        let conn = NWConnection(to: device.endpoint.nwEndpoint, using: parameters)
        let sessionID = UUID()

        // `connect` is idempotent: any prior consumer Task and event stream
        // are torn down so the new connection's events flow without crosstalk
        // from a previous attempt.
        let eventStream = DeviceConnectionEventStream()

        conn.stateUpdateHandler = { [weak conn] state in
            guard let conn else { return }
            eventStream.yield(.state(state, sessionID: sessionID, connection: conn))
        }

        let eventConsumerTask = Task { @ButtonHeistActor [weak self] in
            for await event in eventStream.events {
                guard let self else { return }
                switch event {
                case .state(let state, let sessionID, let connection):
                    self.handleStateChange(state, sessionID: sessionID, connection: connection)
                case .received(let receiveEvent, let sessionID, let connection):
                    self.handleReceive(receiveEvent, connection: connection, sessionID: sessionID)
                case .sendFailed(let error, let requestId, let sessionID, let connection):
                    self.handleSendFailure(
                        error,
                        requestId: requestId,
                        connection: connection,
                        sessionID: sessionID
                    )
                }
            }
            if eventStream.didOverflow {
                self?.handleEventStreamOverflow(connection: conn, sessionID: sessionID)
            }
        }

        setRuntimePhase(.connecting(RuntimeSession(
            id: sessionID,
            connection: conn,
            eventConsumerTask: eventConsumerTask,
            eventStream: eventStream
        )))
        conn.start(queue: .global())
    }

    func disconnect() {
        transitionToDisconnected(.local)
    }

    private func setRuntimePhase(_ nextPhase: RuntimePhase) {
        let previousPhase = runtimePhase
        runtimePhase = nextPhase
        if previousPhase.sessionID != nextPhase.sessionID {
            previousPhase.invalidate()
        }
    }

    func transitionToDisconnected(_ event: DisconnectEvent) {
        setRuntimePhase(.disconnected)
        switch event {
        case .local:
            break
        case .failure(let reason):
            onEvent?(.disconnected(reason))
        }
    }

    func isCurrentSession(
        _ sessionID: UUID?,
        connection suppliedConnection: NWConnection?
    ) -> Bool {
        if let sessionID, runtimePhase.sessionID != sessionID {
            return false
        }
        if let suppliedConnection {
            guard let current = runtimePhase.connection else { return false }
            if current !== suppliedConnection {
                return false
            }
        }
        return true
    }

    func connectedSession(
        matching sessionID: UUID?,
        connection suppliedConnection: NWConnection
    ) -> RuntimeSession? {
        guard case .connected(let session) = runtimePhase,
              session.connection === suppliedConnection,
              sessionID == nil || session.id == sessionID else {
            return nil
        }
        return session
    }

    func connectedSession(matching sessionID: UUID) -> RuntimeSession? {
        guard case .connected(let session) = runtimePhase,
              session.id == sessionID else {
            return nil
        }
        return session
    }

    func updateConnectedSession(_ session: RuntimeSession) {
        guard case .connected(let current) = runtimePhase,
              current.id == session.id,
              current.connection === session.connection else {
            return
        }
        setRuntimePhase(.connected(session))
    }

    var currentSessionID: UUID? {
        runtimePhase.sessionID
    }

    // MARK: - Private

    /// Internal for testing: state updates are normally dispatched by the
    /// AsyncStream consumer in `connect()`. Tests inject states directly.
    func handleStateChange(
        _ state: NWConnection.State,
        sessionID: UUID? = nil,
        connection: NWConnection? = nil
    ) {
        guard isCurrentSession(sessionID, connection: connection) else { return }
        switch state {
        case .ready:
            guard case .connecting(let session) = runtimePhase else { return }
            if let connection, session.connection !== connection { return }
            setRuntimePhase(.connected(session))
            onTransportReady?()
            startReceiving()
        case .failed(let error):
            deviceConnectionLogger.error("Connection failed: \(error)")
            transitionToDisconnected(.failure(.networkError(NetworkTransportFailure(error))))
        case .cancelled:
            // Client-initiated teardown paths (disconnect(), .failed, buffer overflow,
            // protocol/auth rejection) all set the runtime phase to disconnected before
            // the cancel callback reaches the actor, so wasActive is false and we stay
            // silent. A true wasActive means NWConnection cancelled while we still
            // believed we were live — treat that as an unsolicited server-side close.
            guard runtimePhase.sessionID != nil else { return }
            transitionToDisconnected(.failure(.serverClosed))
        default:
            break
        }
    }

}
