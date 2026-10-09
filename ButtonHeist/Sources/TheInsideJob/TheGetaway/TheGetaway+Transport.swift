#if canImport(UIKit)
#if DEBUG
import Foundation

import TheScore

extension TheGetaway {

    // MARK: - Transport Wiring

    func wireTransport(
        _ transport: ServerTransport,
        onBacklogOverflow: @escaping @MainActor @Sendable (Int) async -> Void
    ) async -> TransportWiringOutcome {
        let attempt = TransportWiringAttempt(
            transport: transport,
            delivery: clientDelivery(for: transport)
        )
        let replacedDelivery = transportWiring.delivery
        let cleanup = replacementCleanup()
        transportWiring = .wiring(attempt, cleanup: cleanup)
        if let replacedDelivery {
            await replacedDelivery.invalidate()
        }
        await cleanup?.value
        guard transportWiring.admits(attempt) else {
            return await rejectTransportWiring(attempt)
        }

        await transportWiringBoundary.beforeControlPlaneAdmission(attempt)
        guard transportWiring.admits(attempt) else {
            return await rejectTransportWiring(attempt)
        }
        return await wireControlPlane(for: attempt, onBacklogOverflow: onBacklogOverflow)
    }

    private func clientDelivery(for transport: ServerTransport) -> ClientDelivery {
        let server = transport.server
        let sendToClient: @Sendable (Data, Int) async -> ServerSendOutcome = { data, clientId in
            await server.send(data, to: clientId)
        }
        let disconnect: @Sendable (Int) async -> Void = { clientId in
            await server.removeClient(clientId)
        }
        let onAuthenticated: @MainActor @Sendable (
            ClientDelivery,
            Int,
            @escaping SocketResponseHandler
        ) async -> Void = { [weak self] delivery, _, respond in
            await self?.sendServerInfo(respond: respond, delivery: delivery)
        }
        return ClientDelivery(callbacks: ClientDelivery.Callbacks(
            sendToClient: sendToClient,
            disconnectClient: disconnect,
            onClientAuthenticated: onAuthenticated
        ))
    }

    private func wireControlPlane(
        for attempt: TransportWiringAttempt,
        onBacklogOverflow: @escaping @MainActor @Sendable (Int) async -> Void
    ) async -> TransportWiringOutcome {
        let transport = attempt.transport
        let delivery = attempt.delivery
        let mainActorStream = AsyncStream<TransportControlPlane.MainActorEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(TransportControlPlane.mainActorEventBufferLimit)
        )
        let controlPlane = TransportControlPlane(
            transport: transport,
            muscle: muscle,
            delivery: delivery,
            pongPayload: pongPayload,
            probe: mainThreadProbe,
            publish: { event in
                mainActorStream.continuation.yield(event)
            }
        )
        let events = mainActorStream.stream
        let mainActorConsumer = Task { @MainActor [weak self, events, onBacklogOverflow] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                await self.executeMainActorEvent(event, onBacklogOverflow: onBacklogOverflow)
            }
        }
        let wiring = WiredTransport(
            attempt: attempt,
            controlPlane: controlPlane,
            mainActorEvents: mainActorStream.continuation,
            mainActorConsumer: mainActorConsumer
        )
        transportWiring = .wired(wiring)
        await controlPlane.start()
        guard transportWiring.admitsEvent(delivery: delivery) else {
            mainActorStream.continuation.finish()
            mainActorConsumer.cancel()
            await controlPlane.stop()
            return await rejectTransportWiring(attempt)
        }
        return .admitted(attempt)
    }

    private func rejectTransportWiring(
        _ attempt: TransportWiringAttempt
    ) async -> TransportWiringOutcome {
        if transportWiring.admits(attempt) {
            transportWiring = .unwired
        }
        await attempt.delivery.invalidate()
        return .rejected
    }

    private func replacementCleanup() -> Task<Void, Never>? {
        switch transportWiring {
        case .unwired:
            return nil
        case .wiring(_, let cleanup):
            return cleanup
        case .wired(let wiring):
            return Task { @MainActor [weak self] in
                guard let self else { return }
                await self.stopWiring(wiring)
            }
        }
    }

    private func stopWiring(_ wiring: WiredTransport?) async {
        guard let wiring else { return }
        wiring.mainActorEvents.finish()
        wiring.mainActorConsumer.cancel()
        await wiring.controlPlane.stop()
        await brains.stopInteractionRequests()
        await wiring.mainActorConsumer.value
    }

    func tearDown() async {
        let wiring = transportWiring.wired
        let cleanup = transportWiring.cleanup
        let delivery = transportWiring.delivery
        transportWiring = .unwired
        wiring?.mainActorEvents.finish()
        wiring?.mainActorConsumer.cancel()
        if let delivery {
            await delivery.invalidate()
        }
        await cleanup?.value
        await stopWiring(wiring)
    }

    func tearDownIfWired(to expectedTransport: ServerTransport) async {
        guard transport === expectedTransport else { return }
        await tearDown()
    }

    private func executeMainActorEvent(
        _ event: TransportControlPlane.MainActorEvent,
        onBacklogOverflow: @escaping @MainActor @Sendable (Int) async -> Void
    ) async {
        switch event {
        case .controlChanged(let delivery):
            guard case .wired(let wiring) = transportWiring,
                  wiring.attempt.delivery === delivery
            else { return }
            let changes = await wiring.controlPlane.consumeControlChanges()
            for lease in changes.endedLeases {
                brains.cancelTransportRequests(lease: lease)
            }
            if let maxEvents = changes.backlogOverflowLimit {
                await onBacklogOverflow(maxEvents)
            }

        case .dispatch(let message, let respond, let lease, let delivery):
            guard case .wired(let wiring) = transportWiring,
                  wiring.attempt.delivery === delivery,
                  await wiring.controlPlane.consumeDispatch(for: lease)
            else { return }
            let clientId = message.clientId
            let controlPlane = wiring.controlPlane
            let submission = brains.submitTransportRequest(lease: lease) { [weak self] in
                guard !Task.isCancelled,
                      let self,
                      self.transportWiring.admitsEvent(delivery: delivery),
                      await controlPlane.isCurrent(lease)
                else { return }
                await self.executeClientMessage(
                    message,
                    respond: respond,
                    delivery: delivery
                )
            }
            if case .rejected(let rejection) = submission {
                guard case .wired(let wiring) = transportWiring,
                      wiring.attempt.delivery === delivery
                else { return }
                insideJobLogger.error(
                    "Client \(clientId) interaction submission rejected: \(String(describing: rejection))"
                )
                brains.cancelTransportRequests(lease: lease)
                await wiring.controlPlane.disconnect(lease)
            }

        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
