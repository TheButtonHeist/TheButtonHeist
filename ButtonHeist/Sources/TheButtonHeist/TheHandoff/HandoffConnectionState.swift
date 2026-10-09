import Foundation
import os.log
import TheScore

private let driverIdentityLogger = ButtonHeistLog.logger(.handoff(.driverIdentity))

/// Why a connection attempt failed. TheFence maps this domain error at the boundary.
///
/// Also used as the associated value in `HandoffConnectionPhase.failed`, which
/// is why this enum is `Equatable`. Not every case can appear in `.failed`: the
/// phase-producing cases are `connectionFailed`, `serverFailure`, and
/// `disconnected`; auth and session-lock failures are disconnect causes. The
/// resolver/timeout cases are thrown directly from resolution/waiting paths and
/// never become a phase value.
enum HandoffConnectionError: Error, LocalizedError, Equatable {
    case connectionFailed(String)
    case discoveryBacklogOverflow(capacity: Int)
    case serverFailure(ServerError)
    case disconnected(DisconnectReason)
    case timeout
    case endpointUnreachable(String)
    case noDeviceFound
    case noMatchingDevice(filter: String, available: [String])
    case ambiguousDeviceTarget(filter: String, matches: [String])

    static let recoveryHint = "Is the app running? Check 'buttonheist list_devices' to see available devices."

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return message
        case .discoveryBacklogOverflow(let capacity):
            return "Bonjour discovery event backlog exceeded \(capacity) events"
        case .serverFailure(let serverError):
            return serverError.message.description
        case .disconnected(let reason):
            return reason.connectionFailureMessage
        case .timeout:
            return "Connection timed out"
        case .endpointUnreachable(let endpoint):
            return "Could not reach ButtonHeist server at \(endpoint)"
        case .noDeviceFound:
            return "No device found"
        case .noMatchingDevice(let filter, let available):
            return "No device matching '\(filter)' (available: \(available.joined(separator: ", ")))"
        case .ambiguousDeviceTarget(let filter, let matches):
            return "Ambiguous device target '\(filter)' (matches: \(matches.joined(separator: ", ")))"
        }
    }

    var failureCode: String {
        failureDetails.errorCode
    }

    var phase: FailurePhase {
        failureDetails.phase
    }

    var retryable: Bool {
        failureDetails.retryable
    }

    var hint: String? {
        failureDetails.hint
    }

    var failureDetails: FailureDetails {
        switch self {
        case .connectionFailed:
            return FailureDetails(
                code: .connectionFailed,
                hint: Self.recoveryHint
            )
        case .discoveryBacklogOverflow:
            return FailureDetails(
                code: .connectionFailed,
                hint: Self.recoveryHint
            )
        case .serverFailure(let serverError):
            let details = serverError.failureDetails
            return FailureDetails(
                code: details.code,
                hint: serverError.recoveryHint?.description ?? details.hint
            )
        case .disconnected(let reason):
            return reason.failureDetails
        case .timeout:
            return FailureDetails(
                code: .setupTimeout,
                hint: Self.recoveryHint
            )
        case .endpointUnreachable(let endpoint):
            return FailureDetails(
                code: .connectionEndpointUnreachable,
                hint: "Check that the app is running at \(endpoint), then retry the command."
            )
        case .noDeviceFound:
            return FailureDetails(code: .discoveryNoDeviceFound)
        case .noMatchingDevice:
            return FailureDetails(code: .discoveryNoMatchingDevice)
        case .ambiguousDeviceTarget:
            return FailureDetails(code: .discoveryAmbiguousDeviceTarget)
        }
    }
}

/// State carried while connected: device, keepalive task, and the lifecycle-scoped data
/// that only makes sense during a live connection.
struct HandoffConnectedSession {
    let attemptID: UUID
    let device: DiscoveredDevice
    let keepaliveTask: Task<Void, Never>
    var serverInfo: ServerInfo?
    var missedPongCount: Int

    init(
        attemptID: UUID,
        device: DiscoveredDevice,
        keepaliveTask: Task<Void, Never>,
        serverInfo: ServerInfo? = nil,
        missedPongCount: Int = 0
    ) {
        self.attemptID = attemptID
        self.device = device
        self.keepaliveTask = keepaliveTask
        self.serverInfo = serverInfo
        self.missedPongCount = missedPongCount
    }
}

/// Explicit connection lifecycle state machine. The device is carried in connecting and connected states.
struct HandoffConnectionAttempt {
    let id: UUID
    let device: DiscoveredDevice
}

struct HandoffReconnectAttempt: Equatable, Sendable {
    let id: UUID
    let target: HandoffReconnectTarget
}

enum HandoffConnectionPhase {
    case disconnected
    case reconnecting(HandoffReconnectAttempt)
    case connecting(HandoffConnectionAttempt)
    case connected(HandoffConnectedSession)
    case failed(HandoffConnectionError)
}

/// Concrete device identity auto-reconnect is allowed to recover.
struct HandoffReconnectTarget: Equatable, Sendable {
    let resolutionTarget: DeviceResolutionTarget
    let device: DiscoveredDevice
}

enum HandoffDriverIdentity {
    static func effectiveDriverId(explicit driverId: DriverID?) -> DriverID { driverId ?? persistentDriverId }

    private static let driverIdFile = PrivateStorage.resolveBaseDirectory()
        .appendingPathComponent("driver-id")

    private static let persistentDriverId: DriverID = {
        let fileURL = driverIdFile
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let driverId = try? DriverID(validating: existing) {
            do {
                try PrivateStorage.createPrivateDirectory(at: fileURL.deletingLastPathComponent())
                try PrivateStorage.createPrivateFile(at: fileURL)
            } catch {
                driverIdentityLogger.warning("Failed to repair driver-id permissions: \(error.localizedDescription)")
            }
            return driverId
        }

        guard let generated = try? DriverID(validating: UUID().uuidString.lowercased()) else {
            preconditionFailure("UUID generation produced a blank driver ID")
        }
        do {
            try PrivateStorage.writePrivateData(Data(generated.description.utf8), to: fileURL)
        } catch {
            driverIdentityLogger.warning("Failed to persist driver-id to \(fileURL.path)")
        }
        return generated
    }()
}
