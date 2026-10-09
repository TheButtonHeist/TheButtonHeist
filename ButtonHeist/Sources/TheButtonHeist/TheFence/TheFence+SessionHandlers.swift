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
        let resolvedTarget: DeviceResolutionTarget
        let resolvedToken: String?

        if let device = request.device {
            resolvedTarget = DeviceResolutionTarget(filter: device)
            resolvedToken = request.token
        } else if let targetName = request.targetName {
            guard let fileConfig = config.fileConfig else {
                throw FenceError.invalidRequest(
                    "No config file loaded. Create .buttonheist.json or ~/.config/buttonheist/config.json"
                )
            }
            guard let target = fileConfig.targets[targetName] else {
                let available = fileConfig.targets.keys.map(\.rawValue).sorted()
                throw FenceError.invalidRequest(
                    "Unknown target '\(targetName.rawValue)'. Available: \(available.joined(separator: ", "))"
                )
            }
            resolvedTarget = DeviceResolutionTarget(config: target, named: targetName)
            resolvedToken = request.token ?? target.token
        } else if handoff.connectionLifecycle.isConnected || !config.connectionTarget.isAutomatic {
            return try await establishSessionOnly()
        } else {
            throw FenceError.invalidRequest(
                "Must specify 'target' (named config target), 'device' (host:port), or configure BUTTONHEIST_DEVICE/.buttonheist.json"
            )
        }

        stop()

        let authToken = try resolvedToken.map(SessionAuthToken.init(validating:))
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
