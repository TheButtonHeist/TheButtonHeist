import ButtonHeistSupport
import Foundation
import TheScore

// MARK: - Event Enums

/// Synchronous outcome for handing a client message to the transport.
enum DeviceSendOutcome: Equatable, Sendable {
    case enqueued
    case failed(DeviceSendFailure)
}

struct DeviceEncodingFailure: Error, LocalizedError, Equatable, Sendable, CustomStringConvertible {
    let underlyingDescription: String

    init(_ error: any Error) {
        self.underlyingDescription = String(describing: error)
    }

    var description: String {
        underlyingDescription
    }

    var errorDescription: String? {
        underlyingDescription
    }
}

enum DeviceSendFailure: Error, LocalizedError, Equatable, Sendable {
    case notConnected
    case encodingFailed(DeviceEncodingFailure)
    case transportFailed(NetworkTransportFailure)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Connection is closed"
        case .encodingFailed(let failure):
            return "Failed to encode request: \(failure.description)"
        case .transportFailed(let failure):
            return "Transport send failed: \(failure.description)"
        }
    }
}

/// Events emitted by a device connection during its lifecycle.
enum ConnectionEvent {
    case connected
    case disconnected(DisconnectReason)
    case sendFailed(DeviceSendFailure, requestId: RequestID?)
    case message(ServerMessage, requestId: RequestID?)
}

/// Events emitted by a device discovery session as services appear and disappear.
enum DiscoveryEvent {
    case found(DiscoveredDevice)
    case lost(DiscoveredDevice)
    case stateChanged(isReady: Bool)
    case failed(HandoffConnectionError)
}

// MARK: - Protocols

/// Manages a single connection to a discovered device, sending and receiving messages.
@ButtonHeistActor
protocol DeviceConnecting: AnyObject {
    var onEvent: (@ButtonHeistActor (ConnectionEvent) -> Void)? { get set }
    func connect()
    func disconnect()
    @discardableResult
    func send(_ message: ClientMessage, requestId: RequestID?) -> DeviceSendOutcome
}

/// Connection surface used by passive reachability probes. Raw socket
/// readiness is intentionally kept out of the authenticated lifecycle event
/// stream consumed by TheHandoff.
@ButtonHeistActor
protocol TransportReachabilityConnecting: AnyObject {
    var onEvent: (@ButtonHeistActor (ConnectionEvent) -> Void)? { get set }
    var onTransportReady: (@ButtonHeistActor () -> Void)? { get set }
    func connect()
    func disconnect()
}

/// Discovers Button Heist services on the local network via Bonjour or direct address.
@ButtonHeistActor
protocol DeviceDiscovering: AnyObject {
    var discoveredDevices: [DiscoveredDevice] { get }
    var isActive: Bool { get }
    var isReady: Bool { get }
    var onEvent: (@ButtonHeistActor (DiscoveryEvent) -> Void)? { get set }
    func start()
    func stop()
}
