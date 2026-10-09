import Foundation
import ButtonHeistSupport

@ButtonHeistActor
extension TheHandoff {

    /// Resolve exactly one admitted target and connect to it.
    func connect(
        target: DeviceResolutionTarget,
        timeout: TimeInterval = 30
    ) async throws {
        disconnectForReplacement()
        if target.requiresDiscovery {
            onStatus?("Searching for iOS devices...")
        }
        let startedDiscovery = target.requiresDiscovery && !discoveryLifecycle.hasDiscoverySession
        if startedDiscovery { startDiscovery() }

        let resolutionTimeout = Self.connectionResolutionTimeout(for: timeout)
        let discoveryTimeout = UInt64(resolutionTimeout * 1_000_000_000)
        let device: DiscoveredDevice
        do {
            device = try await resolveTargetDevice(
                target: target,
                discoveryTimeout: discoveryTimeout
            )
            if !target.requiresDiscovery {
                try await admitDirectEndpoint(device, timeout: resolutionTimeout)
            }
        } catch {
            if startedDiscovery { stopDiscovery() }
            if let connectionError = error as? HandoffConnectionError {
                connectionLifecycle.recordAttemptFailure(connectionError)
            }
            throw error
        }

        if target.requiresDiscovery {
            onStatus?("Found: \(displayName(for: device))")
        }
        onStatus?("Connecting...")

        let attemptID = connect(to: device)
        do {
            try await waitForConnectionResult(timeout: timeout)
        } catch let error as HandoffConnectionError where error == .timeout {
            abortConnectionAttempt(attemptID, failure: .timeout)
            throw error
        }
        onStatus?("Connected to \(displayName(for: device))")
    }

    static func connectionResolutionTimeout(for timeout: TimeInterval) -> TimeInterval {
        min(max(timeout, 0.05), 2.0)
    }

    func setupAutoReconnect(target: DeviceResolutionTarget) {
        _ = connectionLifecycle.setup(target: target)
    }

    func scheduleAutoReconnectIfNeeded(disconnectedDevice: DiscoveredDevice) {
        guard let target = connectionLifecycle.targetForDisconnectedDevice(disconnectedDevice) else { return }
        guard connectionLifecycle.run(
            target: target,
            operation: { [weak self] attempt in
                await self?.runAutoReconnect(attempt: attempt)
            }
        ) != nil else { return }
    }

    /// Compute display name with disambiguation when multiple devices have the same app.
    func displayName(for device: DiscoveredDevice) -> String {
        device.displayName(among: discoveryLifecycle.discoveredDevices)
    }

    private func resolveTargetDevice(
        target: DeviceResolutionTarget,
        discoveryTimeout: UInt64
    ) async throws -> DiscoveredDevice {
        let resolver = DeviceResolver(
            target: target,
            discoveryTimeout: discoveryTimeout,
            getDiscoveredDevices: { [weak self] in self?.discoveryLifecycle.discoveredDevices ?? [] }
        )
        return try await resolver.resolve()
    }

    private func admitDirectEndpoint(
        _ device: DiscoveredDevice,
        timeout: TimeInterval
    ) async throws {
        switch await device.reachability(
            token: serverMessageRouter.authToken,
            timeout: timeout
        ) {
        case .reachable:
            return
        case .failed(let reason):
            throw HandoffConnectionError.disconnected(reason)
        case .unavailable:
            throw HandoffConnectionError.endpointUnreachable(device.name)
        }
    }

    private func runAutoReconnect(attempt: HandoffReconnectAttempt) async {
        let target = attempt.target
        let policy = autoReconnectRecoveryPolicy
        onStatus?("Device disconnected — watching for reconnection...")

        for _ in policy.attempts {
            guard connectionLifecycle.isCurrentReconnectAttempt(attempt) else { return }
            connectionLifecycle.markReconnecting(target: target, attemptID: attempt.id)

            let sleepDuration = policy.sleepDuration()
            guard await reconnectSleeper(sleepDuration) else { return }
            guard connectionLifecycle.isCurrentReconnectAttempt(attempt) else { return }

            let device = target.device
            onStatus?("Reconnecting to \(device.name)...")
            let attemptID = openConnection(to: device)
            do {
                try await waitForConnectionResult(timeout: reconnectAttemptTimeout)
            } catch let error as HandoffConnectionError where error == .timeout {
                abortConnectionAttempt(attemptID, failure: .timeout)
            } catch is CancellationError {
                return
            } catch {
                // The connection phase already recorded the attempt failure; keep retrying until the bounded policy expires.
            }

            guard connectionLifecycle.isCurrentReconnectAttempt(attempt) else { return }
            if connectionLifecycle.isConnected {
                guard connectionLifecycle.finishSuccess(attempt) else { return }
                onStatus?("Reconnected to \(device.name)")
                return
            }
        }

        let failure = policy.terminalFailure(targetDisplayName: target.device.name)
        onStatus?(failure.errorDescription ?? "Auto-reconnect gave up")
        _ = connectionLifecycle.finishFailure(attempt, failure: failure)
    }
}
