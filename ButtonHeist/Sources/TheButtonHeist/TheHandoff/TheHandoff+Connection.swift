import Foundation
import os.log

import TheScore

private let handoffConnectionLogger = ButtonHeistLog.logger(.handoff(.connection))

@ButtonHeistActor
extension TheHandoff {
    @discardableResult
    func connect(to device: DiscoveredDevice) -> UUID {
        disconnectForReplacement()
        return openConnection(to: device)
    }

    @discardableResult
    func openConnection(to device: DiscoveredDevice) -> UUID {
        let connection = makeConnection?(device) ?? DeviceConnection(
            device: device,
            token: serverMessageRouter.authToken
        )
        let attemptID = connectionLifecycle.beginConnecting(device: device, connection: connection)
        connection.onEvent = { [weak self, attemptID] event in
            self?.handleConnectionEvent(event, attemptID: attemptID, device: device)
        }

        connection.connect()
        return attemptID
    }

    func handleServerMessage(_ message: ServerMessage, requestId: RequestID?) {
        applyServerMessageRoute(serverMessageRouter.route(message, requestId: requestId))
    }

    func disconnect() {
        _ = connectionLifecycle.disable()
        tearDownConnection()
    }

    func disconnectForReplacement() {
        tearDownConnection(replacementReason: .localDisconnect)
    }

    /// Tear down an in-flight connection attempt after its owner reaches a setup
    /// terminal state (for example, discovery/direct-connect timeout). This
    /// intentionally does not schedule reconnect: there was no usable session
    /// drop, only a failed setup attempt.
    func abortConnectionAttempt(_ attemptID: UUID, failure: HandoffConnectionError) {
        execute(connectionLifecycle.abort(attemptID, failure: failure))
    }

    func disableAutoReconnect() {
        _ = connectionLifecycle.disable()
    }

    func waitForConnectionResult(timeout: TimeInterval) async throws {
        try await connectionLifecycle.waitForConnectionResult(timeout: timeout)
    }

    /// Force-close the connection. Use when a timeout suggests the connection
    /// is dead but TCP hasn't noticed yet.
    func forceDisconnect(expectedAttemptID: UUID? = nil) {
        if let expectedAttemptID,
           connectionLifecycle.activeAttemptID != expectedAttemptID {
            return
        }
        guard connectionLifecycle.isConnected else { return }
        let reconnectDevice = connectionLifecycle.connectedDevice
        tearDownConnection(replacementReason: .localDisconnect)
        if let reconnectDevice {
            scheduleAutoReconnectIfNeeded(disconnectedDevice: reconnectDevice)
        }
    }

    @discardableResult
    func send(_ message: ClientMessage, requestId: RequestID? = nil) -> DeviceSendOutcome {
        guard case .connected = connectionPhase,
              let connection = connectionLifecycle.activeConnection else {
            return .failed(.notConnected)
        }
        return connection.send(message, requestId: requestId)
    }

    @discardableResult
    func tickKeepalive(expectedAttemptID: UUID? = nil) -> Int {
        let missedPongCount = connectionLifecycle.recordKeepaliveTick(
            expectedAttemptID: expectedAttemptID
        )
        if missedPongCount > 0 {
            connectionLifecycle.activeConnection?.send(.ping, requestId: nil)
        }
        return missedPongCount
    }

    private func handleConnectionEvent(
        _ event: ConnectionEvent,
        attemptID: UUID,
        device: DiscoveredDevice
    ) {
        guard connectionLifecycle.isActiveAttempt(attemptID) else { return }

        switch event {
        case .connected:
            connectionLifecycle.markConnected(
                attemptID: attemptID,
                device: device,
                keepaliveTask: makeKeepaliveTask(attemptID: attemptID)
            )
        case .disconnected(let reason):
            handleDisconnectEvent(reason, attemptID: attemptID, device: device)
        case .sendFailed(let failure, let requestId):
            onSendFailure?(failure, requestId)
        case .message(let message, let requestId):
            handleServerMessage(message, requestId: requestId)
        }
    }

    private func handleDisconnectEvent(
        _ reason: DisconnectReason,
        attemptID: UUID,
        device: DiscoveredDevice
    ) {
        if case .failed = connectionPhase {
            return
        }
        guard connectionLifecycle.observeDisconnect(
            reason,
            expectedAttemptID: attemptID
        ) else { return }
        if reason.retryable {
            scheduleAutoReconnectIfNeeded(disconnectedDevice: device)
        }
    }

    private func applyServerMessageRoute(_ route: HandoffServerMessageRoute) {
        switch route {
        case .admission(let decision):
            applyAdmissionDecision(decision)
        case .serverInfo(let info):
            connectionLifecycle.recordServerInfo(info)
        case .forward(let message, let requestId):
            onServerMessage?(message, requestId)
        case .serverFailure(let serverError):
            failActiveConnection(.serverFailure(serverError))
        case .pong(let payload, let requestId):
            connectionLifecycle.markPongReceived()
            if let requestId {
                onServerMessage?(.pong(payload), requestId)
            }
        case .handled:
            break
        }
    }

    private func applyAdmissionDecision(_ decision: HandoffAdmissionDecision) {
        switch decision {
        case .send(let message):
            sendAdmissionMessage(message)
        case .terminalFailure(let failure):
            failActiveConnection(failure)
        }
    }

    private func failActiveConnection(_ failure: HandoffConnectionError) {
        execute(connectionLifecycle.fail(failure))
    }

    private func sendAdmissionMessage(_ message: ClientMessage) {
        guard let connection = connectionLifecycle.activeConnection else {
            execute(connectionLifecycle.fail(.connectionFailed(
                "Cannot send admission message without an active transport"
            )))
            return
        }
        let outcome = connection.send(message, requestId: nil)
        if case .failed(let failure) = outcome {
            failActiveConnection(.connectionFailed(failure.localizedDescription))
        }
    }

    private func tearDownConnection(replacementReason: DisconnectReason? = nil) {
        _ = connectionLifecycle.cancelReconnectAttempt()
        execute(connectionLifecycle.disconnect(reason: replacementReason))
    }

    private func execute(_ effect: HandoffConnectionLifecycle.Effect?) {
        if case .disconnect(let connection)? = effect {
            connection.disconnect()
        }
    }

    private func makeKeepaliveTask(attemptID: UUID) -> Task<Void, Never> {
        Task { @concurrent [weak self] in
            while !Task.isCancelled {
                guard await Task.cancellableSleep(for: Self.keepaliveInterval) else { break }
                guard !Task.isCancelled else { break }
                let count = await self?.tickKeepalive(expectedAttemptID: attemptID) ?? 0
                if count >= Self.maxMissedPongs {
                    handoffConnectionLogger.warning(
                        "No pong received for \(count) consecutive pings — forcing disconnect"
                    )
                    await self?.forceDisconnect(expectedAttemptID: attemptID)
                    break
                }
            }
        }
    }
}
