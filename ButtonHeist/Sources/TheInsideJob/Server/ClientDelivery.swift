import Foundation
import os

import TheScore

let muscleLogger = ButtonHeistLog.logger(.insideJob(.auth))

/// The transport delivery capability owned by one wired session.
actor ClientDelivery {
    private enum Phase {
        case active
        case invalidated
    }

    struct Callbacks: Sendable {
        let sendToClient: @Sendable (_ data: Data, _ clientId: Int) async -> ServerSendOutcome
        let disconnectClient: @Sendable (_ clientId: Int) async -> Void
        let onClientAuthenticated: @MainActor @Sendable (
            _ delivery: ClientDelivery,
            _ clientId: Int,
            _ respond: @escaping SocketResponseHandler
        ) async -> Void
    }

    enum DeliveryOutcome: Equatable, Sendable {
        case delivered
        case rejected
    }

    private let callbacks: Callbacks
    private var phase = Phase.active

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
    }

    func invalidate() {
        phase = .invalidated
    }

    var isActive: Bool {
        guard case .active = phase else { return false }
        return true
    }

    func send(_ data: Data, toClient clientId: Int) async -> ServerSendOutcome {
        guard isActive else { return .failed(.transportUnavailable) }
        return await callbacks.sendToClient(data, clientId)
    }

    func respond(
        _ data: Data,
        using respond: @escaping SocketResponseHandler
    ) async -> ServerSendOutcome {
        guard isActive else { return .failed(.transportUnavailable) }
        return await respond(data)
    }

    @discardableResult
    func disconnect(_ clientId: Int) async -> DeliveryOutcome {
        guard isActive else { return .rejected }
        await callbacks.disconnectClient(clientId)
        return .delivered
    }

    @discardableResult
    func clientAuthenticated(
        _ clientId: Int,
        respond: @escaping SocketResponseHandler
    ) async -> DeliveryOutcome {
        guard isActive else { return .rejected }
        await callbacks.onClientAuthenticated(self, clientId, respond)
        return .delivered
    }
}
