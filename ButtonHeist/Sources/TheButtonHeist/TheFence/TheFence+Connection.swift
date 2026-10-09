import Foundation
import TheScore

extension TheFence {

    /// Connect to a device and optionally enable auto-reconnect.
    public func start() async throws {
        if handoff.connectionLifecycle.isConnected {
            return
        }

        try await connect()
        if config.autoReconnect {
            handoff.setupAutoReconnect(target: config.connectionTarget)
        }
    }

    /// Disconnect and cancel all pending requests.
    public func stop() {
        clearClientSessionState(
            error: FenceError.diagnostic(DiagnosticFailure(disconnectReason: .localDisconnect))
        )
        handoff.disableAutoReconnect()
        handoff.disconnect()
        handoff.stopDiscovery()
    }

    func handleHandoffConnectionStateChanged(_ state: HandoffConnectionPhase) {
        switch state {
        case .failed(let failure):
            clearClientSessionState(error: sessionStateError(for: failure))
        case .disconnected:
            guard let failure = handoff.connectionLifecycle.diagnosticFailure,
                  case .disconnected = failure
            else { return }
            clearClientSessionState(error: sessionStateError(for: failure))
        case .reconnecting, .connecting, .connected:
            break
        }
    }

    func clearClientSessionState(error: Error) {
        cancelAllPendingRequests(error: error)
    }

    private func sessionStateError(for failure: HandoffConnectionError) -> Error {
        if case .disconnected(let reason) = failure {
            return FenceError.diagnostic(DiagnosticFailure(disconnectReason: reason))
        }
        return FenceError(failure)
    }

    private func connect() async throws {
        do {
            try await handoff.connect(
                target: config.connectionTarget,
                timeout: config.connectionTimeout
            )
        } catch let error as HandoffConnectionError {
            throw FenceError(error)
        }
    }
}
