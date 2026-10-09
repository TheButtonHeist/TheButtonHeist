import Foundation

import ButtonHeistSupport
import TheScore

extension TheFence {

    // MARK: - Pending Request Tracking

    enum PendingRequestError: Error, Equatable, LocalizedError {
        case duplicateRequestId(RequestID)

        var errorDescription: String? {
            switch self {
            case .duplicateRequestId(let requestId):
                return "Request ID '\(requestId)' already has a pending waiter"
            }
        }
    }

    struct PendingResponseExpectation<Response: Sendable>: Sendable {
        fileprivate let responseName: String
        fileprivate let extract: @Sendable (ServerMessage) -> Response?

        fileprivate func decode(
            _ result: Result<ServerMessage, Error>,
            requestId: RequestID
        ) -> Result<Response, Error> {
            switch result {
            case .success(let message):
                guard let response = extract(message) else {
                    return .failure(Self.responseTypeMismatchError(
                        expected: responseName,
                        actual: message.pendingResponseName ?? "unsupported",
                        requestId: requestId
                    ))
                }
                return .success(response)
            case .failure(let error):
                return .failure(error)
            }
        }

        private static func responseTypeMismatchError(
            expected: String,
            actual: String,
            requestId: RequestID
        ) -> FenceError {
            let message = "Protocol mismatch for request \(requestId): expected \(expected) response, " +
                "received \(actual) response."
            let details = FailureDetails(code: .protocolMismatch)
            return .diagnostic(DiagnosticFailure(
                message: message,
                details: details
            ))
        }
    }

    private struct PendingRequestOwner: Equatable, Sendable {
        let requestID: RequestID
        let nonce: UUID
    }

    private struct PendingRequest: Sendable {
        let owner: PendingRequestOwner
        let response: TimedOneShot<Result<ServerMessage, Error>>

        func complete(_ result: Result<ServerMessage, Error>) {
            response.resolve(returning: result)
        }
    }

    @ButtonHeistActor
    final class PendingRequestRegistry {
        private var pending: [RequestID: PendingRequest] = [:]

        func waitForResponse<Response: Sendable>(
            _ expectation: PendingResponseExpectation<Response>,
            requestId: RequestID,
            timeout: TimeInterval,
            afterRegister: (() -> Void)? = nil
        ) async throws -> Response {
            let owner = PendingRequestOwner(requestID: requestId, nonce: UUID())
            let response = TimedOneShot<Result<ServerMessage, Error>>()

            let result = await response.wait(
                cancellationValue: .failure(CancellationError()),
                onRegistered: { response in
                    guard register(
                        PendingRequest(
                            owner: owner,
                            response: response
                        )
                    ) else {
                        response.resolve(returning: .failure(PendingRequestError.duplicateRequestId(requestId)))
                        return
                    }

                    response.armTimeout(
                        after: .saturatingSeconds(timeout)
                    ) { [weak self] in
                        await self?.finish(
                            requestID: requestId,
                            expectedOwner: owner,
                            with: .failure(FenceError.actionTimeout)
                        )
                    }
                    afterRegister?()
                },
                onFinished: {
                    removeIfOwned(owner)
                }
            )
            return try expectation.decode(result, requestId: requestId).get()
        }

        @discardableResult
        func resolveTransientResponse(_ message: ServerMessage, requestId: RequestID) -> Bool {
            switch message {
            case .error(let serverError):
                finish(
                    requestID: requestId,
                    with: .failure(FenceError.serverError(serverError))
                )
                return true
            default:
                guard message.pendingResponseName != nil else { return false }
                finish(
                    requestID: requestId,
                    with: .success(message)
                )
                return true
            }
        }

        func resolveTransientFailure(_ error: Error, requestId: RequestID) {
            finish(
                requestID: requestId,
                with: .failure(error)
            )
        }

        func cancelAll(error: Error) {
            let requestIDs = Array(pending.keys)
            for requestID in requestIDs {
                finish(requestID: requestID, with: .failure(error))
            }
        }

        private func register(_ request: PendingRequest) -> Bool {
            guard pending[request.owner.requestID] == nil else { return false }
            pending[request.owner.requestID] = request
            return true
        }

        private func finish(
            requestID: RequestID,
            expectedOwner: PendingRequestOwner? = nil,
            with result: Result<ServerMessage, Error>
        ) {
            guard let request = pending[requestID],
                  expectedOwner == nil || request.owner == expectedOwner
            else { return }
            pending.removeValue(forKey: requestID)
            request.complete(result)
        }

        private func removeIfOwned(_ owner: PendingRequestOwner) {
            guard pending[owner.requestID]?.owner == owner else { return }
            pending.removeValue(forKey: owner.requestID)
        }
    }
}

extension TheFence.PendingResponseExpectation where Response == ActionResult {
    static var action: Self {
        Self(responseName: "action") { message in
            guard case .actionResult(let result) = message else { return nil }
            return result
        }
    }
}

extension TheFence.PendingResponseExpectation where Response == PongPayload {
    static var pong: Self {
        Self(responseName: "pong") { message in
            guard case .pong(let result) = message else { return nil }
            return result
        }
    }
}

extension TheFence.PendingResponseExpectation where Response == MainThreadProbeResponse {
    static var mainThreadProbe: Self {
        Self(responseName: "main-thread probe") { message in
            guard case .mainThreadProbe(let result) = message else { return nil }
            return result
        }
    }
}

extension TheFence.PendingResponseExpectation where Response == Interface {
    static var interface: Self {
        Self(responseName: "interface") { message in
            guard case .interface(let result) = message else { return nil }
            return result
        }
    }
}

extension TheFence.PendingResponseExpectation where Response == ScreenPayload {
    static var screen: Self {
        Self(responseName: "screen") { message in
            guard case .screen(let result) = message else { return nil }
            return result
        }
    }
}

extension TheFence.PendingResponseExpectation where Response == [Observation.Notification] {
    static var notifications: Self {
        Self(responseName: "notifications") { message in
            guard case .notifications(let result) = message else { return nil }
            return result
        }
    }
}

extension TheFence.PendingResponseExpectation where Response == HeistResult {
    static var heistExecution: Self {
        Self(responseName: "heist execution") { message in
            guard case .heistResult(let result) = message else { return nil }
            return result
        }
    }
}

private extension ServerMessage {
    var pendingResponseName: String? {
        switch self {
        case .pong:
            return "pong"
        case .mainThreadProbe:
            return "main-thread probe"
        case .interface:
            return "interface"
        case .heistResult:
            return "heist execution"
        case .actionResult:
            return "action"
        case .screen:
            return "screen"
        case .notifications:
            return "notifications"
        case .serverHello,
             .protocolMismatch,
             .authRequired,
             .info,
             .error,
             .sessionLocked,
             .status:
            return nil
        }
    }
}
