#if canImport(UIKit)
#if DEBUG
import Foundation

import TheScore

enum ResponseDeliveryOutcome: Sendable, Equatable, CustomStringConvertible {
    case delivered
    case refused(ResponseDeliveryFailure)
    case transportUnavailable(clientId: Int?)
    case failed(ResponseDeliveryFailure)

    var description: String {
        switch self {
        case .delivered:
            return "Delivered response envelope"
        case .refused(let failure), .failed(let failure):
            return failure.description
        case .transportUnavailable(let clientId):
            if let clientId {
                return "Connection failure while delivering response envelope to client \(clientId): transport is unavailable"
            }
            return "Connection failure while delivering response envelope: no transport is wired"
        }
    }

    init(sendFailure: ServerSendFailure) {
        switch sendFailure {
        case .clientNotFound(let clientId):
            self = .failed(.connectionClosed(clientId: clientId))
        case .transportUnavailable:
            self = .transportUnavailable(clientId: nil)
        case .transportFailed, .payloadTooLarge, .sendBufferFull:
            self = .failed(.sendFailed(sendFailure))
        }
    }
}

enum ResponseDeliveryFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case sessionContractViolation(String)
    case responseEncodingFailed(ResponseEncodingFailure)
    case connectionClosed(clientId: Int)
    case sendFailed(ServerSendFailure)

    var description: String {
        switch self {
        case .sessionContractViolation(let message):
            return "Session contract failure while delivering response envelope: \(message)"
        case .responseEncodingFailed(let failure):
            return failure.description
        case .connectionClosed(let clientId):
            return "Connection failure while delivering response envelope to client \(clientId): client is no longer connected"
        case .sendFailed(let failure):
            return "Send failure while delivering response envelope: \(failure.localizedDescription)"
        }
    }
}

struct ResponseEncodingFailure: Error, Sendable, Equatable, CustomStringConvertible {
    let requestId: RequestID?
    let underlyingDescription: String

    var description: String {
        if let requestId {
            return "Failed to encode response envelope for request \(requestId): \(underlyingDescription)"
        }
        return "Failed to encode response envelope: \(underlyingDescription)"
    }
}

enum ResponseEnvelopeDelivery {
    static func encodeEnvelope(
        _ message: ServerMessage,
        requestId: RequestID? = nil
    ) -> Result<Data, ResponseEncodingFailure> {
        do {
            let envelopeData = try ResponseEnvelope(
                requestId: requestId,
                message: message
            ).encoded()
            return .success(envelopeData)
        } catch {
            return .failure(.init(requestId: requestId, underlyingDescription: String(describing: error)))
        }
    }

}

extension TheGetaway {
    // MARK: - Encode / Decode

    func encodeEnvelope(
        _ message: ServerMessage,
        requestId: RequestID? = nil
    ) -> Result<Data, ResponseEncodingFailure> {
        ResponseEnvelopeDelivery.encodeEnvelope(message, requestId: requestId)
    }

    func logEncodingFailure(_ failure: ResponseEncodingFailure) {
        insideJobLogger.error("\(failure.description)")
    }

    func logDeliveryFailure(_ failure: ResponseDeliveryFailure) {
        insideJobLogger.error("\(failure.description)")
    }

    @discardableResult
    func sendMessage(
        _ message: ServerMessage,
        requestId: RequestID? = nil,
        respond: @escaping SocketResponseHandler,
        generation: ClientDelivery.Generation
    ) async -> ResponseDeliveryOutcome {
        await muscle.sendResponse(
            message,
            requestId: requestId,
            respond: respond,
            generation: generation
        )
    }

    func sendEncodedData(_ data: Data, toClient clientId: Int) async -> ResponseDeliveryOutcome {
        switch await muscle.sendData(data, toClient: clientId) {
        case .delivered:
            return .delivered
        case .failed(let sendFailure):
            return ResponseDeliveryOutcome(sendFailure: sendFailure)
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
