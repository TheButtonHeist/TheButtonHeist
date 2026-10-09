import Foundation

import ThePlans
import TheScore

public extension FenceError {
    internal var diagnosticFailure: DiagnosticFailure {
        switch self {
        case .invalidRequest(let message):
            return DiagnosticFailure(message: message, details: FailureDetails(code: .requestInvalid))
        case .heistBuildDiagnostics(let diagnostics):
            return DiagnosticFailure(
                message: diagnostics.renderedBuildDiagnosticMessage,
                details: diagnostics.heistBuildFailureDetails,
                buildDiagnostics: diagnostics
            )
        case .diagnostic(let failure):
            return failure
        case .sessionLocked(let message):
            return DiagnosticFailure(
                message: "Session locked: \(message)",
                details: FailureDetails(code: .sessionLocked)
            )
        case .authFailed(let message):
            return DiagnosticFailure(
                message: "Auth failed: \(message)",
                details: FailureDetails(code: .authFailed)
            )
        case .notConnected:
            return DiagnosticFailure(
                message: "Not connected to device.",
                details: FailureDetails(code: .connectionNotConnected)
            )
        case .actionTimeout:
            return DiagnosticFailure(
                message: "Command timed out waiting for a response from the app.",
                details: FailureDetails(code: .requestTimeout)
            )
        case .actionFailed(let message):
            return DiagnosticFailure(
                message: "Action failed: \(message)",
                details: FailureDetails(code: .requestActionFailed)
            )
        case .serverError(let serverError):
            return DiagnosticFailure(
                message: "Action failed: \(serverError.message)",
                details: serverError.failureDetails
            )
        }
    }

}

private extension Array where Element == HeistBuildDiagnostic {
    var primaryBuildDiagnostic: HeistBuildDiagnostic? {
        first(where: { $0.kind == .error }) ?? first
    }

    var renderedBuildDiagnosticMessage: String {
        guard !isEmpty else { return "Heist planning failed." }
        return map(\.renderedMessage).joined(separator: "\n")
    }

    var heistBuildFailureDetails: FailureDetails {
        guard let primary = primaryBuildDiagnostic else {
            return FailureDetails(code: .requestInvalid)
        }
        return FailureDetails(
            code: .requestInvalid,
            hint: primary.hint
        )
    }
}
