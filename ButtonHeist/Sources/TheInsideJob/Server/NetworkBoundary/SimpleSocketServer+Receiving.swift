import Foundation
import Network
import os

import TheScore

private let receiveLogger = ButtonHeistLog.logger(.handoff(.server))

extension SimpleSocketServer {
    func startReceiving(clientId: Int, connection: NWConnection, generation: SocketListenerGeneration) {
        receiveNextChunk(
            clientId: clientId, connection: connection,
            framer: NewlineDelimitedFramer(
                maxPendingBytes: WireFrameLimits.clientToServerMaxBufferedBytes
            ), generation: generation
        )
    }

    private func receiveNextChunk(
        clientId: Int,
        connection: NWConnection,
        framer: NewlineDelimitedFramer,
        generation: SocketListenerGeneration
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: WireFrameLimits.receiveChunkBytes) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            self.spawnTrackedTask(in: generation) { server in
                await server.handleReceivedData(
                    clientId: clientId,
                    connection: connection,
                    content: content,
                    isComplete: isComplete,
                    error: error,
                    framer: framer,
                    generation: generation
                )
            }
        }
    }

    /// Process received data within actor isolation.
    private func handleReceivedData(
        clientId: Int,
        connection: NWConnection,
        content: Data?,
        isComplete: Bool,
        error: NWError?,
        framer: NewlineDelimitedFramer,
        generation: SocketListenerGeneration
    ) {
        if let error {
            receiveLogger.error("Receive error from client \(clientId): \(error)")
            removeClient(clientId)
            return
        }

        var receiveFramer = framer
        let messageFrames: [Data]
        do {
            messageFrames = try receiveFramer.append(content ?? Data())
        } catch {
            receiveLogger.warning("Client \(clientId) exceeded max buffer size, disconnecting")
            rejectClientWithServerError(
                clientId,
                kind: .validationError,
                message: "Inbound message exceeded the server buffer limit."
            )
            return
        }

        for messageData in messageFrames {
            guard routeMessageFrame(
                clientId: clientId,
                connection: connection,
                messageData: messageData
            ) else { return }
        }

        if isComplete {
            removeClient(clientId)
        } else {
            receiveNextChunk(
                clientId: clientId, connection: connection,
                framer: receiveFramer, generation: generation
            )
        }
    }

    private func routeMessageFrame(
        clientId: Int,
        connection: NWConnection,
        messageData: Data
    ) -> Bool {
        guard clientRegistry.client(clientId)?.connection === connection else { return false }
        callbacks.onDataReceived?(
            clientId,
            messageData,
            responseHandler(clientId: clientId, connection: connection)
        )
        return true
    }

    private func responseHandler(
        clientId: Int,
        connection: NWConnection
    ) -> SocketResponseHandler {
        { [weak self] response in
            guard let self else { return .failed(.transportUnavailable) }
            return await self.send(response, to: clientId, through: connection)
        }
    }
}
