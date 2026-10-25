import Foundation
import Network
import os

import TheScore

private let connectionLogger = ButtonHeistLog.logger(.handoff(.server))

extension SimpleSocketServer {
    static let maxConnections = 5

    func acceptReadyConnection(
        _ connection: NWConnection,
        generation: SocketListenerGeneration
    ) async -> ReadyConnectionAcceptance {
        guard await isCurrentListeningGeneration(generation) else {
            if !generation.cancelIfOwned(connection) {
                connection.cancel()
            }
            return .rejected
        }

        let scopeFilter = allowedScopes != ConnectionScope.all ? allowedScopes : nil
        if let scopeFilter {
            guard let host = Self.extractRemoteHost(from: connection) else {
                rejectStartedConnectionWithServerError(
                    connection,
                    generation: generation,
                    kind: .general,
                    message: "Connection rejected: server could not classify the connection scope."
                )
                return .rejected
            }
            let path = connection.currentPath
            let interfaceNameList = (path?.availableInterfaces ?? []).map { $0.name }
            let localHost: NWEndpoint.Host? = if case .hostPort(let local, _) = path?.localEndpoint {
                local
            } else {
                nil
            }
            let scope = ConnectionScope.classify(host: host, localHost: localHost, interfaceNames: interfaceNameList)
            if !scopeFilter.contains(scope) {
                let message: ServerErrorMessage
                do {
                    message = try ServerErrorMessage(
                        validating: "Connection rejected: \(scope.rawValue) connections are not allowed by this server."
                    )
                } catch {
                    connectionLogger.error("Failed to admit connection rejection error: \(error)")
                    if !generation.cancelIfOwned(connection) {
                        connection.cancel()
                    }
                    return .rejected
                }
                rejectStartedConnectionWithServerError(
                    connection,
                    generation: generation,
                    kind: .general,
                    message: message
                )
                return .rejected
            }
        }

        guard await isCurrentListeningGeneration(generation) else {
            if !generation.cancelIfOwned(connection) {
                connection.cancel()
            }
            return .rejected
        }

        let clientId: Int
        switch clientRegistry.admitConnection(
            connection,
            capacity: Self.maxConnections,
            transferOwnership: { generation.transferToClientRegistry(connection) }
        ) {
        case .registered(let registeredClientId):
            clientId = registeredClientId
        case .atCapacity:
            connectionLogger.warning("Max connections (\(Self.maxConnections)) reached, rejecting")
            rejectStartedConnectionWithServerError(
                connection,
                generation: generation,
                kind: .general,
                message: "Connection rejected: server already has the maximum number of clients."
            )
            return .rejected
        case .ownershipUnavailable:
            if !generation.cancelIfOwned(connection) {
                connection.cancel()
            }
            return .rejected
        }
        let remoteAddress = Self.extractRemoteHost(from: connection).map { "\($0)" }
        callbacks.onClientConnected?(clientId, remoteAddress)
        startReceiving(clientId: clientId, connection: connection, generation: generation)
        return .registered(clientId: clientId)
    }

    private func rejectStartedConnectionWithServerError(
        _ connection: NWConnection,
        generation: SocketListenerGeneration,
        kind: TheScore.ServerError.Kind,
        message: ServerErrorMessage
    ) {
        let response: Data
        do {
            response = try ResponseEnvelope(message: .error(TheScore.ServerError(kind: kind, message: message))).encoded()
        } catch {
            connectionLogger.error("Failed to encode connection rejection error: \(error.localizedDescription)")
            if !generation.cancelIfOwned(connection) {
                connection.cancel()
            }
            return
        }

        var data = response
        if !data.hasSuffix(Data([WireFrameLimits.newlineDelimiterByte])) {
            data.append(WireFrameLimits.newlineDelimiterByte)
        }

        dependencies.sendContent(connection, data, .contentProcessed { error in
            if let error {
                connectionLogger.error("Send error while rejecting unregistered connection: \(error)")
            }
            if !generation.cancelIfOwned(connection) {
                connection.cancel()
            }
        })
    }

    /// Extract the remote host from an NWConnection using typed Network framework
    /// values. Checks the connection endpoint directly first, then currentPath.
    nonisolated private static func extractRemoteHost(from connection: NWConnection) -> NWEndpoint.Host? {
        if case .hostPort(let host, _) = connection.endpoint {
            return host
        }
        if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
            return host
        }
        return nil
    }
}
