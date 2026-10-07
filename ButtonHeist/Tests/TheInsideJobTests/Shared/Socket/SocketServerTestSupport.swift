#if canImport(UIKit)
#if DEBUG
import Network
import os

@testable import TheInsideJob

enum TestSocketListenerOutcome: Sendable {
    case ready(UInt16)
    case failed(NWError)
}

final class TestSocketListenerProvider: Sendable {
    typealias Start = @MainActor @Sendable (_ invocation: Int) async -> TestSocketListenerOutcome

    private struct State {
        var invocationCount = 0
        var cancellationCount = 0
        var listenerReferences: [WeakSocketListenerReference] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let start: Start
    private let onCancel: @MainActor @Sendable () -> Void

    init(
        start: @escaping Start,
        onCancel: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.start = start
        self.onCancel = onCancel
    }

    convenience init(port: UInt16) {
        self.init { _ in .ready(port) }
    }

    var invocationCount: Int {
        state.withLock { $0.invocationCount }
    }

    var cancellationCount: Int {
        state.withLock { $0.cancellationCount }
    }

    var retainedListenerCount: Int {
        state.withLock { state in
            state.listenerReferences.compactMap(\.listener).count
        }
    }

    var listenerProvider: SocketListenerProvider {
        { [self] _ in
            let invocation = state.withLock { state in
                state.invocationCount += 1
                return state.invocationCount
            }
            let listener = TestSocketListener(
                start: { [start] in await start(invocation) },
                onCancel: { [state, onCancel] in
                    state.withLock { $0.cancellationCount += 1 }
                    Task { @MainActor in onCancel() }
                }
            )
            state.withLock {
                $0.listenerReferences.append(WeakSocketListenerReference(listener))
            }
            return listener
        }
    }
}

private final class WeakSocketListenerReference: @unchecked Sendable {
    weak var listener: (any SocketListening)?

    init(_ listener: any SocketListening) {
        self.listener = listener
    }
}

private final class TestSocketListener: SocketListening, @unchecked Sendable {
    private struct State {
        var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)?
        var newConnectionHandler: (@Sendable (NWConnection) -> Void)?
        var port: NWEndpoint.Port?
        var isCancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let startOperation: @Sendable () async -> TestSocketListenerOutcome
    private let onCancel: @Sendable () -> Void

    init(
        start: @escaping @Sendable () async -> TestSocketListenerOutcome,
        onCancel: @escaping @Sendable () -> Void
    ) {
        startOperation = start
        self.onCancel = onCancel
    }

    var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)? {
        get { state.withLock { $0.stateUpdateHandler } }
        set { state.withLock { $0.stateUpdateHandler = newValue } }
    }

    var newConnectionHandler: (@Sendable (NWConnection) -> Void)? {
        get { state.withLock { $0.newConnectionHandler } }
        set { state.withLock { $0.newConnectionHandler = newValue } }
    }

    var port: NWEndpoint.Port? {
        state.withLock { $0.port }
    }

    func start(queue _: DispatchQueue) {
        Task { [startOperation] in
            publish(await startOperation())
        }
    }

    func invalidate() {
        let invalidation = state.withLock { state -> (Bool, (@Sendable (NWListener.State) -> Void)?) in
            guard !state.isCancelled else { return (false, nil) }
            state.isCancelled = true
            let handler = state.stateUpdateHandler
            state.stateUpdateHandler = nil
            state.newConnectionHandler = nil
            return (true, handler)
        }
        guard invalidation.0 else { return }
        invalidation.1?(.cancelled)
        onCancel()
    }

    private func publish(_ outcome: TestSocketListenerOutcome) {
        let publication = state.withLock { state -> (NWListener.State, (@Sendable (NWListener.State) -> Void))? in
            guard !state.isCancelled, let handler = state.stateUpdateHandler else { return nil }
            switch outcome {
            case .ready(let port):
                state.port = NWEndpoint.Port(rawValue: port)
                return (.ready, handler)
            case .failed(let error):
                return (.failed(error), handler)
            }
        }
        guard let (state, handler) = publication else { return }
        handler(state)
    }
}

extension SimpleSocketServer {
    func insertClientForTesting(connection: NWConnection) -> Int? {
        guard currentListener != nil else { return nil }
        guard case .registered(let clientId) = clientRegistry.admitConnection(
            connection,
            capacity: .max,
            transferOwnership: { true }
        ) else {
            return nil
        }
        return clientId
    }

    func clientPendingSendBytesForTesting(_ clientId: Int) -> Int? {
        clientRegistry.pendingSendBytes(for: clientId)
    }

    var clientCountForTesting: Int {
        clientRegistry.count
    }
}
#endif
#endif
