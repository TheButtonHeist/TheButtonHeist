import Foundation

import TheScore

struct AdmittedClientMessage: Sendable {
    let clientId: Int
    let envelope: RequestEnvelope
}

enum ClientAdmission {
    typealias ResponseHandler = SocketResponseHandler

    enum Effect {
        case replaceAuthenticationDeadline(clientId: Int)
        case cancelAuthenticationDeadline(clientId: Int)
        case cancelAllAuthenticationDeadlines
        case sendResponse(ServerMessage, requestId: RequestID?, respond: ResponseHandler)
        case sendClient(ServerMessage, requestId: RequestID?, clientId: Int)
        case delayedDisconnect(clientId: Int)
        case log(Log)
    }

    enum Log {
        case clientAuthenticatedWithToken(clientId: Int)
        case sessionLockRejected(clientId: Int, message: String)
        case rateLimited(clientId: Int)
        case undecodableUnauthenticatedMessage(clientId: Int)
        case undecodableAuthenticatedMessage(clientId: Int)
        case authenticatedProtocolMessage(clientId: Int, wireType: ClientWireMessageType)
        case unauthenticatedMessage(clientId: Int, message: String)
        case authenticationTimeout(clientId: Int, timeoutSeconds: UInt64)
        case versionMismatch(
            clientId: Int,
            serverVersion: ButtonHeistVersion,
            clientVersion: ButtonHeistVersion
        )
        case missingRegisteredAddress(clientId: Int)
        case lockedOut(clientId: Int, address: ClientNetworkAddress)
        case invalidToken(clientId: Int, attempts: Int)
        case lockoutStarted(address: ClientNetworkAddress, attempts: Int)
    }

    enum Decision {
        case admitted(AdmittedClientMessage)
        case handled([Effect])
        case sessionAdmission(SessionAdmission)
    }

    enum Authentication {}
    enum Timeout {}
}

#if canImport(UIKit)
#if DEBUG
/// Owns the unauthenticated ButtonHeist handshake and client auth phases.
extension ClientAdmission {
    struct Reducer {
        private var clientRegistry = Registry()
        private var tokenAuthentication: TokenAuthentication

        init(sessionToken: SessionAuthToken, authenticationPolicy: InsideJobAuthenticationPolicy) {
            self.tokenAuthentication = TokenAuthentication(
                sessionToken: sessionToken,
                policy: authenticationPolicy
            )
        }

        @discardableResult
        mutating func registerClientAddress(
            _ clientId: Int,
            address: ClientNetworkAddress
        ) -> [Effect] {
            clientRegistry.registerAddress(clientId, address: address)
            return [.replaceAuthenticationDeadline(clientId: clientId)]
        }

        @discardableResult
        mutating func removeAllClients() -> [Effect] {
            clientRegistry.removeAll()
            return [.cancelAllAuthenticationDeadlines]
        }

        func contains(_ clientId: Int) -> Bool {
            clientRegistry.contains(clientId)
        }

        mutating func admit(
            _ clientId: Int,
            data: Data,
            respond: @escaping ResponseHandler,
            at now: Date = Date()
        ) -> Decision {
            if let rateLimitEffects = rateLimitEffects(clientId, respond: respond, at: now) {
                return .handled(rateLimitEffects)
            }

            guard let envelope = try? RequestEnvelope.decoded(from: data) else {
                let effects = clientRegistry.state(for: clientId)?.isAuthenticated == true
                    ? Rejection.undecodableAuthenticatedMessage(clientId, respond: respond)
                    : Rejection.undecodableUnauthenticatedMessage(clientId, respond: respond)
                return .handled(effects)
            }

            guard clientRegistry.state(for: clientId)?.isAuthenticated != true else {
                return AuthenticatedCommand.admit(clientId, envelope: envelope, respond: respond)
            }

            return Handshake.admit(
                clientId,
                envelope: envelope,
                respond: respond,
                clientRegistry: &clientRegistry,
                tokenAuthentication: &tokenAuthentication
            )
        }

        mutating func completeAuthentication(_ sessionAdmission: SessionAdmission) -> [Effect] {
            let cancelDeadline = Effect.cancelAuthenticationDeadline(clientId: sessionAdmission.clientId)
            switch clientRegistry.completeAuthentication(sessionAdmission.clientId) {
            case .advanced(_, outcome: .authenticated):
                break
            case .advanced(_, outcome: .helloValidated):
                preconditionFailure("Authentication completion cannot emit hello validation.")
            case .missingClient:
                return [
                    cancelDeadline,
                    .log(.missingRegisteredAddress(clientId: sessionAdmission.clientId)),
                    .sendResponse(
                        .error(ServerError(kind: .authFailure, message: "Connection rejected.")),
                        requestId: nil,
                        respond: sessionAdmission.respond
                    ),
                    .delayedDisconnect(clientId: sessionAdmission.clientId),
                ]
            case .rejected:
                return [cancelDeadline] + Rejection.unauthenticatedMessage(
                    sessionAdmission.clientId,
                    message: "Authentication requires clientHello first.",
                    requestId: nil,
                    respond: sessionAdmission.respond
                )
            }

            return [
                cancelDeadline,
                .log(.clientAuthenticatedWithToken(clientId: sessionAdmission.clientId)),
            ]
        }

        func rejectForSessionLock(
            _ clientId: Int,
            diagnostic: SessionLease.SessionLockDiagnostic,
            respond: @escaping ResponseHandler
        ) -> [Effect] {
            let payload = diagnostic.payload()
            return [
                .log(.sessionLockRejected(clientId: clientId, message: payload.message)),
                .sendResponse(.sessionLocked(payload), requestId: nil, respond: respond),
                .delayedDisconnect(clientId: clientId),
            ]
        }

        mutating func removeClient(_ clientId: Int) -> [Effect] {
            _ = clientRegistry.remove(clientId)
            return [.cancelAuthenticationDeadline(clientId: clientId)]
        }

        func authenticationTimeout(_ clientId: Int, timeoutSeconds: UInt64) -> [Effect] {
            Timeout.effects(
                clientId: clientId,
                state: clientRegistry.state(for: clientId),
                timeoutSeconds: timeoutSeconds
            )
        }

        private mutating func rateLimitEffects(
            _ clientId: Int,
            respond: @escaping ResponseHandler,
            at now: Date
        ) -> [Effect]? {
            switch clientRegistry.admitMessage(clientId, at: now) {
            case .accept:
                return nil
            case .drop(shouldNotify: false):
                return [.log(.rateLimited(clientId: clientId))]
            case .drop(shouldNotify: true):
                let message: ServerErrorMessage
                do {
                    message = try ServerErrorMessage(
                        validating: "Rate limited: max \(RateLimiter.defaultMaxMessagesPerSecond) messages per second"
                    )
                } catch {
                    return [.log(.rateLimited(clientId: clientId))]
                }
                return [
                    .log(.rateLimited(clientId: clientId)),
                    .sendResponse(
                        .error(ServerError(kind: .general, message: message)),
                        requestId: nil,
                        respond: respond
                    ),
                ]
            }
        }
    }
}
#endif // DEBUG
#endif // canImport(UIKit)
