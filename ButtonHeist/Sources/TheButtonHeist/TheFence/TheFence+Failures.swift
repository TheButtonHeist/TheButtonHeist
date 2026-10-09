import Foundation

import ThePlans
import TheScore

/// Errors thrown by TheFence during command dispatch, connection, and action execution.
public enum FenceError: Error {
    case invalidRequest(String)
    case heistBuildDiagnostics([HeistBuildDiagnostic])
    case diagnostic(DiagnosticFailure)
    case sessionLocked(String)
    case authFailed(String)
    case notConnected
    case actionTimeout
    case actionFailed(String)
    case serverError(ServerError)
}
