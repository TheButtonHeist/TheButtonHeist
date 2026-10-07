import Foundation
import Network
import os

final class DeviceConnectionEventStream: Sendable {
    static let bufferLimit = 512

    let events: AsyncStream<DeviceConnectionEvent>

    private let continuation: AsyncStream<DeviceConnectionEvent>.Continuation
    private let didOverflowState = OSAllocatedUnfairLock(initialState: false)

    init() {
        let stream = AsyncStream<DeviceConnectionEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.bufferLimit)
        )
        self.events = stream.stream
        self.continuation = stream.continuation
    }

    func yield(_ event: DeviceConnectionEvent) {
        switch continuation.yield(event) {
        case .enqueued, .terminated:
            return
        case .dropped:
            didOverflowState.withLock { $0 = true }
            continuation.finish()
        @unknown default:
            didOverflowState.withLock { $0 = true }
            continuation.finish()
        }
    }

    func finish() {
        continuation.finish()
    }

    var didOverflow: Bool {
        didOverflowState.withLock { $0 }
    }
}

extension DeviceConnection {
    /// Internal for testing and overflow handling from NW callbacks.
    func handleEventStreamOverflow(connection: NWConnection) {
        handleEventStreamOverflow(connection: connection, sessionID: nil)
    }

    func handleEventStreamOverflow(connection: NWConnection, sessionID: UUID?) {
        guard isCurrentSession(sessionID, connection: connection) else { return }
        deviceConnectionLogger.error("Connection event backlog exceeded \(DeviceConnectionEventStream.bufferLimit), disconnecting")
        transitionToDisconnected(.failure(.eventBacklogOverflow(maxEvents: DeviceConnectionEventStream.bufferLimit)))
    }
}
