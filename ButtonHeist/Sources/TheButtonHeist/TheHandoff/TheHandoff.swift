import Foundation
import ButtonHeistSupport
import TheScore

/// Client-side coordinator for device discovery, connection, admission, keepalive, and auto-reconnect.
///
/// TheFence owns a TheHandoff and delegates connection management here.
@ButtonHeistActor
final class TheHandoff {

    // MARK: - State

    let connectionLifecycle = HandoffConnectionLifecycle()
    let discovery: any DeviceDiscovering

    nonisolated static let keepaliveInterval: Duration = .seconds(5)
    nonisolated static let maxMissedPongs = 36

    // MARK: - Derived State

    var connectionPhase: HandoffConnectionPhase { connectionLifecycle.phase }
    // MARK: - Discovery Callbacks

    // All callbacks below fire on `@ButtonHeistActor`.

    /// A device matching the filter appeared on the network.
    var onDeviceFound: (@ButtonHeistActor (DiscoveredDevice) -> Void)?
    /// A previously-known device is no longer advertising.
    var onDeviceLost: (@ButtonHeistActor (DiscoveredDevice) -> Void)?

    // MARK: - Connection Callbacks

    /// Emits after each connection phase transition. Consumers derive lifecycle
    /// side effects from this state stream instead of one-off lifecycle hooks.
    var onConnectionStateChanged: (@ButtonHeistActor (HandoffConnectionPhase) -> Void)?
    /// Non-lifecycle server messages delivered to TheFence for request-tracker
    /// resolution. TheHandoff forwards these without retaining semantic state.
    var onServerMessage: (@ButtonHeistActor (ServerMessage, RequestID?) -> Void)?
    /// Transport send failures reported after Network.framework processes an enqueued write.
    var onSendFailure: (@ButtonHeistActor (DeviceSendFailure, RequestID?) -> Void)?
    // MARK: - Configuration

    var authToken: SessionAuthToken?
    /// Explicit driver ID override (e.g. from BUTTONHEIST_DRIVER_ID env var).
    /// When nil, a persistent auto-generated ID is used instead.
    var driverID: DriverID?

    // MARK: - Internal Reconnect Settings

    /// Interval between auto-reconnect attempts. Default is 1 second.
    var reconnectInterval: TimeInterval = 1.0
    /// Max attempts before reconnect becomes terminal. Internal so tests can
    /// drive bounded retries without waiting on the production limit.
    var reconnectMaxAttempts = 60
    /// Per-attempt connection timeout used by the reconnect runner.
    var reconnectAttemptTimeout: TimeInterval = 10
    var autoReconnectRecoveryPolicy: AutoReconnectRecoveryPolicy {
        AutoReconnectRecoveryPolicy(maxAttempts: reconnectMaxAttempts, baseInterval: reconnectInterval)
    }
    var reconnectSleeper: (TimeInterval) async -> Bool = { sleepDuration in
        await Task.cancellableSleep(for: .seconds(sleepDuration))
    }

    // MARK: - Injectable Closures

    var makeConnection: ((DiscoveredDevice) -> any DeviceConnecting)?

    // MARK: - Init

    init(discovery: any DeviceDiscovering = DeviceDiscovery()) {
        self.discovery = discovery
        connectionLifecycle.onPhaseChanged = { [weak self] phase in
            self?.onConnectionStateChanged?(phase)
        }
    }

    // MARK: - Session Management (discovery → connect → reconnect)

    /// Status callback for session management progress messages.
    var onStatus: (@ButtonHeistActor (String) -> Void)?
}
