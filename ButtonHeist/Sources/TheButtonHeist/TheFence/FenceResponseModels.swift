import Foundation
import ThePlans

import TheScore

/// Level of detail for interface responses.
@_spi(ButtonHeistTooling) public enum InterfaceDetail: String, CaseIterable, Sendable {
    case summary
    case full
}

@_spi(ButtonHeistTooling) public enum HeistCatalogDetail: String, CaseIterable, Sendable, Equatable {
    case summary
    case detailed
}

@_spi(ButtonHeistTooling) public struct ScreenshotResponseOptions: Sendable, Equatable {
    public let includeInterface: Bool

    public init(includeInterface: Bool = true) {
        self.includeInterface = includeInterface
    }
}

@_spi(ButtonHeistTooling) public struct SessionDevicePayload: Sendable, Equatable {
    public let deviceName: String
    public let appName: String
    public let connectionType: ConnectionScope
    public let shortId: String?

    package init(
        deviceName: String,
        appName: String,
        connectionType: ConnectionScope,
        shortId: String?
    ) {
        self.deviceName = deviceName
        self.appName = appName
        self.connectionType = connectionType
        self.shortId = shortId
    }
}

@_spi(ButtonHeistTooling) public struct SessionFailurePayload: Sendable, Equatable {
    private let details: FailureDetails
    public let message: String?

    public var code: String { details.errorCode }
    public var phase: FailurePhase { details.phase }
    public var retryable: Bool { details.retryable }
    public var hint: String? { details.hint }

    package init(
        details: FailureDetails,
        message: String?
    ) {
        self.details = details
        self.message = message
    }
}

@_spi(ButtonHeistTooling) public enum SessionConnectionState: Sendable, Equatable {
    case disconnected(lastFailure: SessionFailurePayload?)
    case connecting(lastFailure: SessionFailurePayload?)
    case connected(device: SessionDevicePayload)
    case failed(SessionFailurePayload)
}

@_spi(ButtonHeistTooling) public struct SessionStatePayload: Sendable, Equatable {
    public let state: SessionConnectionState
    public let actionTimeoutSeconds: TimeInterval
    public let longActionTimeoutSeconds: TimeInterval

    package init(
        state: SessionConnectionState,
        actionTimeoutSeconds: TimeInterval,
        longActionTimeoutSeconds: TimeInterval
    ) {
        self.state = state
        self.actionTimeoutSeconds = actionTimeoutSeconds
        self.longActionTimeoutSeconds = longActionTimeoutSeconds
    }

}

extension DiagnosticFailure {
    init(_ error: Error) {
        switch error {
        case let fenceError as FenceError:
            self.init(fenceError)
        case let connectionError as HandoffConnectionError:
            self.init(connectionError: connectionError)
        case let configError as TargetConfigLoadError:
            self.init(
                message: configError.displayMessage,
                details: configError.failureDetails
            )
        case let validationError as SchemaValidationError:
            self.init(
                message: validationError.message,
                details: FailureDetails(code: .requestValidationError)
            )
        case let inputError as PublicJSONInputError:
            self.init(
                message: inputError.message,
                details: FailureDetails(code: .requestInvalid)
            )
        case let routingError as FenceOperationRoutingError:
            self.init(message: routingError.message, details: routingError.details)
        default:
            self.init(
                message: error.displayMessage,
                details: FailureDetails(code: .clientUnknown)
            )
        }
    }

    init(_ fenceError: FenceError) {
        self = fenceError.diagnosticFailure
    }

}

/// Typed response from TheFence command execution.
///
/// Cases marked `…Data` carry the raw payload in memory (base64-encoded).
/// Screenshot data is opt-in.
/// Cases without the `Data` suffix carry a filesystem path where the artifact
/// has been written.
@_spi(ButtonHeistTooling) public enum FenceResponse {
    case ok(message: String)
    case error(DiagnosticFailure)
    case status(connected: Bool, deviceName: String?)
    case pong(PongPayload)
    case devices([DiscoveredDevice])
    case interface(Interface, detail: InterfaceDetail = .summary)
    case notifications([Observation.Notification])
    case action(result: ActionResult, expectation: ExpectationResult? = nil)
    /// Screenshot written to disk. `path` is the resolved filesystem location.
    case screenshot(path: String, payload: ScreenPayload, options: ScreenshotResponseOptions = ScreenshotResponseOptions())
    /// Screenshot held in memory as base64 PNG. Returned only when inline data
    /// is explicitly requested.
    case screenshotData(payload: ScreenPayload, options: ScreenshotResponseOptions = ScreenshotResponseOptions())
    case heistExecution(
        plan: HeistPlan,
        report: HeistReport
    )
    case heistValidation(HeistValidation.Report)
    case heistCatalog([HeistDescription], detail: HeistCatalogDetail)
    case heistDescription(HeistDescription)
    case sessionState(payload: SessionStatePayload)
    case targets([TargetName: TargetConfig], defaultTarget: TargetName?)

    /// Builds an error response with typed metadata when the error belongs to TheFence.
    public static func failure(_ error: Error) -> FenceResponse {
        let failure = DiagnosticFailure(error)
        return .error(failure)
    }

    /// Whether callers should treat this response as a failed command.
    public var isFailure: Bool {
        switch self {
        case .ok, .status, .pong, .devices, .interface, .notifications, .screenshot, .screenshotData,
             .heistCatalog, .heistDescription,
             .sessionState, .targets:
            return false
        case .error:
            return true
        case .action(let result, let expectation):
            if !result.outcome.isSuccess { return true }
            if let expectation, !expectation.met { return true }
            return false
        case .heistExecution(_, let report):
            return report.failure != nil
        case .heistValidation(let report):
            return !report.commandPassed
        }
    }

}
