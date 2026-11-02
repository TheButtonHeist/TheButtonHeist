import Foundation
import TheScore

@ButtonHeistActor
extension TheFence {

    // MARK: - Handler: List Devices

    func handleListDevices() async throws -> FenceResponse {
        var devices = await handoff.discoverReachableDevices()
        if let fileConfig = config.fileConfig {
            let configDevices = Self.configTargetsAsDevices(fileConfig)
            let existingIDs = Set(devices.map(\.id))
            for device in configDevices where !existingIDs.contains(device.id) {
                devices.append(device)
            }
        }
        return .devices(devices)
    }

    // MARK: - Handler: Connect

    private func establishSessionOnly() async throws -> FenceResponse {
        try await start()
        return .sessionState(payload: currentSessionState())
    }

    func handleConnect(_ request: ConnectRequest) async throws -> FenceResponse {
        guard case .replacement(let resolvedTarget, let authToken) = request else {
            if handoff.connectionLifecycle.isConnected || !config.connectionTarget.isAutomatic {
                return try await establishSessionOnly()
            }
            throw FenceError.invalidRequest(
                "Must specify 'target' (named config target), 'device' (host:port), or configure BUTTONHEIST_DEVICE/.buttonheist.json"
            )
        }

        stop()

        handoff.authToken = authToken
        config.connectionTarget = resolvedTarget
        config.token = authToken

        do {
            try await start()
        } catch let connectionFailure as FenceError {
            handoff.disableAutoReconnect()
            handoff.stopDiscovery()
            clearClientSessionState(error: connectionFailure)
            let diagnosticFailure = connectionFailure.diagnosticFailure
            return .error(DiagnosticFailure(
                message: "Connect failed; disconnected from previous target: \(diagnosticFailure.message)",
                details: diagnosticFailure.details
            ))
        }

        return .sessionState(payload: currentSessionState())
    }

    func handleListTargets() -> FenceResponse {
        guard let fileConfig = config.fileConfig else {
            return .targets([:], defaultTarget: nil)
        }
        return .targets(fileConfig.targets, defaultTarget: fileConfig.defaultTarget)
    }

}
