import Foundation

import ThePlans
import TheScore

/// Centralized command dispatch layer. Both the CLI and MCP server are thin wrappers over TheFence.
@ButtonHeistActor
public final class TheFence {
    /// Connection and session configuration for TheFence.
    public struct Configuration {
        /// Substring filter for Bonjour device names. `nil` matches any device.
        var deviceFilter: String?
        /// Seconds to wait for initial connection before failing `start()`.
        var connectionTimeout: TimeInterval
        /// Auth token sent in the `authenticate` message after the server requests
        /// auth. Agents use the task slug.
        var token: SessionAuthToken?
        var driverID: DriverID?
        /// When true, TheHandoff re-establishes the connection on drop.
        var autoReconnect: Bool
        /// Resolved `.buttonheist.json` config (device filter, token, output paths).
        /// Supplied by the CLI/MCP entry points from discovered config files.
        var fileConfig: ButtonHeistFileConfig?
        /// Direct host:port target. Legacy configs may still carry a fingerprint.
        var directDevice: DiscoveredDevice?
        /// Test/config override for screenshot artifact storage root.
        var artifactBaseDirectory: URL?
        /// Session-owned defaults for action expectation budgets.
        public var actionExpectationTimeoutPolicy: ActionExpectationTimeoutPolicy
        /// Extra client-side headroom beyond a server-owned wait timeout.
        var postActionExpectationTimeoutBuffer: TimeInterval

        init(
            deviceFilter: String? = nil,
            connectionTimeout: TimeInterval = 30,
            token: SessionAuthToken? = nil,
            driverID: DriverID? = nil,
            autoReconnect: Bool = true,
            fileConfig: ButtonHeistFileConfig? = nil,
            directDevice: DiscoveredDevice? = nil,
            artifactBaseDirectory: URL? = nil,
            actionExpectationTimeoutPolicy: ActionExpectationTimeoutPolicy = .default,
            postActionExpectationTimeoutBuffer: TimeInterval = 5
        ) {
            self.deviceFilter = deviceFilter
            self.connectionTimeout = connectionTimeout
            self.token = token
            self.driverID = driverID
            self.autoReconnect = autoReconnect
            self.fileConfig = fileConfig
            self.directDevice = directDevice
            self.artifactBaseDirectory = artifactBaseDirectory
            self.actionExpectationTimeoutPolicy = actionExpectationTimeoutPolicy
            self.postActionExpectationTimeoutBuffer = postActionExpectationTimeoutBuffer
        }
    }

    /// Fires on informational status strings (e.g. `BUTTONHEIST_TOKEN=<value>`
    /// on server-generated token, connection events).
    public var onStatus: (@ButtonHeistActor (String) -> Void)? {
        didSet { handoff.onStatus = onStatus }
    }

    // Dependencies
    var config: Configuration
    let handoff = TheHandoff()
    let screenshotArtifacts: ScreenshotArtifactWriter
    let pendingRequests = PendingRequestRegistry()

    public init(configuration: Configuration) {
        self.config = configuration
        self.screenshotArtifacts = ScreenshotArtifactWriter(baseDirectory: configuration.artifactBaseDirectory)
        self.handoff.authToken = configuration.token
        self.handoff.driverID = configuration.driverID
        wireUpResponseCallbacks()
    }

    var sessionConnectionState: SessionConnectionState {
        switch handoff.connectionPhase {
        case .disconnected:
            return .disconnected(lastFailure: handoff.connectionLifecycle.diagnosticFailure.map(sessionFailurePayload(for:)))
        case .reconnecting, .connecting:
            return .connecting(lastFailure: handoff.connectionLifecycle.diagnosticFailure.map(sessionFailurePayload(for:)))
        case .connected(let session):
            return .connected(device: sessionDevicePayload(for: session.device))
        case .failed(let failure):
            return .failed(sessionFailurePayload(for: failure))
        }
    }

    private func sessionDevicePayload(for device: DiscoveredDevice) -> SessionDevicePayload {
        SessionDevicePayload(
            deviceName: handoff.displayName(for: device),
            appName: device.appName,
            connectionType: device.connectionType,
            shortId: device.shortId?.description
        )
    }

    private func sessionFailurePayload(for failure: HandoffConnectionError) -> SessionFailurePayload {
        SessionFailurePayload(
            details: failure.failureDetails,
            message: failure.errorDescription
        )
    }

    private func wireUpResponseCallbacks() {
        handoff.onServerMessage = { [weak self] message, requestId in
            self?.handleServerMessage(message, requestId: requestId)
        }

        handoff.onSendFailure = { [weak self] failure, requestId in
            self?.handleSendFailure(failure, requestId: requestId)
        }

        handoff.onConnectionStateChanged = { [weak self] state in
            self?.handleHandoffConnectionStateChanged(state)
        }
    }

    private func handleServerMessage(_ message: ServerMessage, requestId: RequestID?) {
        guard let requestId else { return }
        _ = pendingRequests.resolveTransientResponse(message, requestId: requestId)
    }

    private func handleSendFailure(_ failure: DeviceSendFailure, requestId: RequestID?) {
        guard let requestId else { return }
        pendingRequests.resolveTransientFailure(FenceError(failure), requestId: requestId)
    }

    // Expectation parsing (`parseExpectation` and its helpers) lives in
    // TheFence+ExpectationParsing.swift.

    // Heist execution (`handleRunHeist`, step-summary building,
    // and `currentSessionState`) lives in TheFence+RunHeist.swift.

    // MARK: - Config Target Conversion

    static func configTargetsAsDevices(_ config: ButtonHeistFileConfig) -> [DiscoveredDevice] {
        config.targets.compactMap { name, target in
            let deviceID = DiscoveryDeviceID(stringLiteral: "config-\(name.rawValue)")
            guard let device = DiscoveredDevice.fromHostPort(
                target.device,
                id: deviceID,
                name: name.rawValue
            ) else { return nil }
            return device
        }
    }

}
