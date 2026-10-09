import Foundation
import ButtonHeistSupport

import TheScore

extension FenceError {
    init(_ connectionError: HandoffConnectionError) {
        self = .diagnostic(DiagnosticFailure(connectionError: connectionError))
    }

    init(_ sendFailure: DeviceSendFailure) {
        switch sendFailure {
        case .notConnected:
            self = .notConnected
        case .encodingFailed(let failure):
            self = .actionFailed("Failed to send request: \(failure.description)")
        case .transportFailed(let failure):
            self = .diagnostic(DiagnosticFailure(deviceTransportFailure: failure))
        }
    }
}

private extension DiagnosticFailure {
    init(deviceTransportFailure failure: NetworkTransportFailure) {
        self.init(
            message: "Transport send failed: \(failure.description)",
            details: FailureDetails(code: .transportNetworkError)
        )
    }
}
