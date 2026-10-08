#if canImport(UIKit)
#if DEBUG
import Foundation

import TheScore

extension TheGetaway {

    /// Broadcast a server message to every active session connection.
    ///
    /// Awaits the transport so two back-to-back `broadcastToAll` calls from
    /// the same caller deliver in FIFO order. The previous sync shape used
    /// fire-and-forget Tasks under the hood, which made no FIFO guarantee.
    @discardableResult
    func broadcastToAll(_ message: ServerMessage) async -> ResponseDeliveryOutcome {
        guard !message.isScreenshot else {
            let failure = ResponseDeliveryFailure.sessionContractViolation("screenshots must be requested explicitly")
            logDeliveryFailure(failure)
            return .refused(failure)
        }
        let data: Data
        switch ResponseEnvelopeDelivery.encodeEnvelope(message) {
        case .success(let envelopeData):
            data = envelopeData
        case .failure(let failure):
            logEncodingFailure(failure)
            return .failed(.responseEncodingFailed(failure))
        }
        guard transport != nil else {
            let outcome = ResponseDeliveryOutcome.transportUnavailable(clientId: nil)
            insideJobLogger.error("\(outcome.description)")
            return outcome
        }
        var firstFailure: ResponseDeliveryOutcome?
        for clientId in await muscle.activeSessionConnections.sorted() {
            switch await sendEncodedData(data, toClient: clientId) {
            case .delivered:
                continue
            case .refused(let failure), .failed(let failure):
                logDeliveryFailure(failure)
                if firstFailure == nil {
                    firstFailure = .failed(failure)
                }
            case .transportUnavailable(let clientId):
                let outcome = ResponseDeliveryOutcome.transportUnavailable(clientId: clientId)
                insideJobLogger.error("\(outcome.description)")
                if firstFailure == nil {
                    firstFailure = outcome
                }
            }
        }
        if let firstFailure {
            return firstFailure
        }
        return .delivered
    }
}

private extension ServerMessage {
    var isScreenshot: Bool {
        if case .screen = self { return true }
        return false
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
