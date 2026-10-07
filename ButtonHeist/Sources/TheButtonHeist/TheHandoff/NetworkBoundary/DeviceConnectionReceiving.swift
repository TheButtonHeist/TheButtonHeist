import Foundation
import ButtonHeistSupport
import Network
import TheScore

enum DeviceReceiveEvent: Sendable {
    case failed(NWError)
    case content(Data)
    case contentThenCompleted(Data)
    case completed
    case awaitingContent

    nonisolated init(content: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            self = .failed(error)
        } else if let content, isComplete {
            self = .contentThenCompleted(content)
        } else if let content {
            self = .content(content)
        } else if isComplete {
            self = .completed
        } else {
            self = .awaitingContent
        }
    }
}

extension DeviceConnection {
    func startReceiving() {
        guard case .connected(let session) = runtimePhase else { return }
        receiveNext(connection: session.connection, sessionID: session.id)
    }

    func receiveNext(connection: NWConnection, sessionID: UUID) {
        guard let session = connectedSession(matching: sessionID, connection: connection) else { return }
        let eventStream = session.eventStream
        connection.receive(minimumIncompleteLength: 1, maximumLength: WireFrameLimits.receiveChunkBytes) { content, _, isComplete, error in
            eventStream.yield(
                .received(
                    DeviceReceiveEvent(content: content, isComplete: isComplete, error: error),
                    sessionID: sessionID,
                    connection: connection
                )
            )
        }
    }

    // Internal for testing stale-callback handling.
    func handleReceive(_ event: DeviceReceiveEvent, connection: NWConnection) {
        handleReceive(event, connection: connection, sessionID: nil)
    }

    func handleReceive(_ event: DeviceReceiveEvent, connection: NWConnection, sessionID: UUID?) {
        guard var session = connectedSession(matching: sessionID, connection: connection) else {
            return
        }

        switch event {
        case .failed(let error):
            deviceConnectionLogger.error("Receive error: \(error)")
            transitionToDisconnected(.failure(.networkError(NetworkTransportFailure(error))))
        case .content(let content):
            guard appendAndProcess(content, into: &session) else { return }
            receiveNext(connection: connection, sessionID: session.id)
        case .contentThenCompleted(let content):
            guard appendAndProcess(content, into: &session) else { return }
            closeForCompletedReceive(session)
        case .completed:
            closeForCompletedReceive(session)
        case .awaitingContent:
            receiveNext(connection: connection, sessionID: session.id)
        }
    }

    private func appendAndProcess(
        _ content: Data,
        into session: inout RuntimeSession
    ) -> Bool {
        let (bufferedByteCount, overflowed) = session.receiveFramer.pendingByteCount.addingReportingOverflow(
            content.count
        )
        if overflowed || bufferedByteCount > WireFrameLimits.serverToClientMaxBufferedBytes {
            deviceConnectionLogger.warning("Server exceeded max buffer size, disconnecting")
            transitionToDisconnected(.failure(.bufferOverflow))
            return false
        }

        let messageFrames = session.receiveFramer.append(content)
        updateConnectedSession(session)
        for messageData in messageFrames {
            guard connectedSession(matching: session.id, connection: session.connection) != nil else {
                return false
            }
            handleMessage(messageData)
        }

        guard let latest = connectedSession(matching: session.id, connection: session.connection) else {
            return false
        }
        session = latest
        return true
    }

    private func closeForCompletedReceive(_ session: RuntimeSession) {
        guard connectedSession(matching: session.id, connection: session.connection) != nil else { return }
        deviceConnectionLogger.warning("Connection closed by server")
        transitionToDisconnected(.failure(.serverClosed))
    }
}
