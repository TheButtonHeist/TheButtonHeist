#if canImport(UIKit)
#if DEBUG
import Foundation

import TheScore

/// Owns transport event consumption and request admission without depending on
/// the main actor. Only admitted app work crosses the main-actor stream.
actor TransportControlPlane {
    private static let maximumPendingMainActorDispatches =
        ClientRequestPipeline.maximumQueuedRequests
    static let mainActorEventBufferLimit = maximumPendingMainActorDispatches + 1

    enum MainActorEvent: Sendable {
        case controlChanged(delivery: ClientDelivery)
        case dispatch(
            AdmittedClientMessage,
            respond: SocketResponseHandler,
            lease: TransportClientLease,
            delivery: ClientDelivery
        )
    }

    struct ControlChanges: Sendable, Equatable {
        let endedLeases: Set<TransportClientLease>
        let backlogOverflowLimit: Int?
    }

    typealias Publish = @Sendable (
        sending MainActorEvent
    ) -> AsyncStream<MainActorEvent>.Continuation.YieldResult
    typealias Probe = @Sendable (
        MainThreadProbeRequest
    ) async throws -> MainThreadProbeResponse

    private struct ClientConnection {
        let lease: TransportClientLease
        let pipeline: ClientRequestPipeline
    }

    private enum State {
        case idle
        case running(Task<Void, Never>)
        case stopped
    }

    private let muscle: TheMuscle
    private let delivery: ClientDelivery
    private let pongPayload: PongPayload
    private let events: ServerTransport.Events
    private let probe: Probe
    private let publish: Publish

    private var state = State.idle
    private var clientConnections: [Int: ClientConnection] = [:]
    private var nextClientIncarnation: UInt64 = 1
    private var pendingMainActorDispatches = 0
    private var endedLeases: Set<TransportClientLease> = []
    private var backlogOverflowLimit: Int?
    private var isControlChangePublished = false

    @MainActor
    init(
        transport: ServerTransport,
        muscle: TheMuscle,
        delivery: ClientDelivery,
        pongPayload: PongPayload,
        probe: @escaping Probe,
        publish: @escaping Publish
    ) {
        self.events = transport.transportEvents
        self.muscle = muscle
        self.delivery = delivery
        self.pongPayload = pongPayload
        self.probe = probe
        self.publish = publish
    }

    func start() {
        guard case .idle = state else { return }
        state = .running(Task { [weak self] in
            guard let self else { return }
            for await event in self.events {
                guard !Task.isCancelled else { return }
                await self.observe(event)
            }
        })
    }

    func observe(_ event: TransportEvent) async {
        guard isRunning else { return }
        switch event {
        case .clientConnected(let clientId, let remoteAddress):
            connectClient(clientId)
            if let remoteAddress {
                await muscle.registerClientAddress(
                    clientId,
                    address: ClientNetworkAddress(remoteAddress),
                    delivery: delivery
                )
            }
            await muscle.sendServerHello(clientId: clientId, delivery: delivery)

        case .clientDisconnected(let clientId):
            endClientConnection(clientId)
            await muscle.handleClientDisconnected(clientId, delivery: delivery)

        case .dataReceived(let clientId, let data, let respond):
            await enqueueClientRequest(clientId: clientId, data: data, respond: respond)

        case .backlogOverflow(let maxEvents):
            endAllClientConnections()
            backlogOverflowLimit = max(backlogOverflowLimit ?? maxEvents, maxEvents)
            publishControlChange()
        }
    }

    func stop() async {
        let eventConsumer: Task<Void, Never>?
        switch state {
        case .idle:
            eventConsumer = nil
        case .running(let consumer):
            eventConsumer = consumer
        case .stopped:
            return
        }
        state = .stopped
        eventConsumer?.cancel()
        let pipelineConsumers = clientConnections.values.compactMap { $0.pipeline.stop() }
        clientConnections.removeAll()
        pendingMainActorDispatches = 0
        endedLeases.removeAll()
        backlogOverflowLimit = nil
        isControlChangePublished = false
        await eventConsumer?.value
        for consumer in pipelineConsumers {
            await consumer.value
        }
    }

    func consumeDispatch(for lease: TransportClientLease) -> Bool {
        guard pendingMainActorDispatches > 0 else { return false }
        pendingMainActorDispatches -= 1
        return isCurrent(lease)
    }

    func consumeControlChanges() -> ControlChanges {
        let changes = ControlChanges(
            endedLeases: endedLeases,
            backlogOverflowLimit: backlogOverflowLimit
        )
        endedLeases.removeAll()
        backlogOverflowLimit = nil
        isControlChangePublished = false
        return changes
    }

    func isCurrent(_ lease: TransportClientLease) -> Bool {
        isRunning && clientConnections[lease.clientId]?.lease == lease
    }

    func disconnect(_ lease: TransportClientLease) async {
        guard endClientConnection(lease) else { return }
        await muscle.disconnectClient(lease.clientId, delivery: delivery)
    }

    private var isRunning: Bool {
        guard case .running = state else { return false }
        return true
    }

    private func connectClient(_ clientId: Int) {
        endClientConnection(clientId)
        let lease = TransportClientLease(
            clientId: clientId,
            incarnation: nextClientIncarnation
        )
        nextClientIncarnation &+= 1
        let pipeline = ClientRequestPipeline { [weak self] request in
            await self?.executeClientRequest(request)
        }
        clientConnections[clientId] = ClientConnection(lease: lease, pipeline: pipeline)
    }

    private func endClientConnection(_ clientId: Int) {
        guard let connection = clientConnections.removeValue(forKey: clientId) else {
            return
        }
        connection.pipeline.stop()
        endedLeases.insert(connection.lease)
        publishControlChange()
    }

    private func endAllClientConnections() {
        for clientId in Array(clientConnections.keys) {
            endClientConnection(clientId)
        }
    }

    @discardableResult
    private func endClientConnection(_ lease: TransportClientLease) -> Bool {
        guard clientConnections[lease.clientId]?.lease == lease else { return false }
        endClientConnection(lease.clientId)
        return true
    }

    private func enqueueClientRequest(
        clientId: Int,
        data: Data,
        respond: @escaping SocketResponseHandler
    ) async {
        guard let connection = clientConnections[clientId] else { return }
        let lease = connection.lease
        let request = ClientTransportRequest(
            lease: lease,
            data: data,
            respond: respond
        )
        switch connection.pipeline.enqueue(request) {
        case .enqueued, .stopped:
            break
        case .overflowed:
            insideJobLogger.error(
                "Client \(clientId) request backlog exceeded \(ClientRequestPipeline.maximumQueuedRequests), disconnecting"
            )
            await disconnect(connection.lease)
        }
    }

    private func executeClientRequest(_ request: ClientTransportRequest) async {
        guard isCurrent(request.lease) else { return }
        let message = await muscle.admitClientMessage(
            request.clientId,
            data: request.data,
            respond: request.respond,
            delivery: delivery
        )
        guard !Task.isCancelled, isCurrent(request.lease) else { return }
        guard let message else { return }

        let envelope = message.envelope
        switch envelope.message {
        case .ping:
            await respond(
                .pong(pongPayload.withServerTimestamp()),
                to: envelope,
                using: request.respond
            )

        case .mainThreadProbe(let probeRequest):
            guard let response = try? await probe(probeRequest) else {
                return
            }
            await respond(
                .mainThreadProbe(response),
                to: envelope,
                using: request.respond
            )

        case .clientHello, .authenticate:
            break

        case .status,
             .requestInterface,
             .getPasteboard,
             .getNotifications,
             .requestScreen,
             .runtimeAction,
             .heistPlan:
            guard pendingMainActorDispatches < Self.maximumPendingMainActorDispatches else {
                insideJobLogger.error(
                    "Main-actor request backlog exceeded \(Self.maximumPendingMainActorDispatches), disconnecting client \(request.clientId)"
                )
                await disconnect(request.lease)
                return
            }
            pendingMainActorDispatches += 1
            guard case .enqueued = publish(.dispatch(
                message,
                respond: request.respond,
                lease: request.lease,
                delivery: delivery
            )) else {
                pendingMainActorDispatches -= 1
                await disconnect(request.lease)
                return
            }
        }
    }

    private func publishControlChange() {
        guard !isControlChangePublished else { return }
        isControlChangePublished = true
        guard case .enqueued = publish(.controlChanged(delivery: delivery)) else {
            isControlChangePublished = false
            return
        }
    }

    private func respond(
        _ message: ServerMessage,
        to envelope: RequestEnvelope,
        using respond: @escaping SocketResponseHandler
    ) async {
        await muscle.sendResponse(
            message,
            requestId: envelope.requestId,
            respond: respond,
            delivery: delivery
        )
    }
}
#endif // DEBUG
#endif // canImport(UIKit)
