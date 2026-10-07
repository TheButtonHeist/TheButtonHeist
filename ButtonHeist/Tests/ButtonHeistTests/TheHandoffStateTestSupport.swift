import Foundation
import Network
import os
@_spi(ButtonHeistTooling) @testable import ButtonHeist

@ButtonHeistActor
final class ManualReconnectSleeper {
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private(set) var sleepCallCount = 0

    func sleep(_: TimeInterval) async -> Bool {
        sleepCallCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext(returning result: Bool = true) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: result)
    }
}

@ButtonHeistActor
final class HandoffTestSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

final class FakeDiscoveryBrowser: DeviceDiscoveryBrowsing {
    private struct State {
        var onResultsChanged: (@Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void)?
        var onStateChanged: (@Sendable (DeviceDiscoveryBrowserState) -> Void)?
        var startCount = 0
        var cancelCount = 0
        var isInvalidated = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var startCount: Int {
        state.withLock { $0.startCount }
    }

    var cancelCount: Int {
        state.withLock { $0.cancelCount }
    }

    var hasInstalledCallbacks: Bool {
        state.withLock { $0.onResultsChanged != nil || $0.onStateChanged != nil }
    }

    func start(
        queue: DispatchQueue,
        onResultsChanged: @escaping @Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void,
        onStateChanged: @escaping @Sendable (DeviceDiscoveryBrowserState) -> Void
    ) {
        state.withLock { state in
            state.onResultsChanged = onResultsChanged
            state.onStateChanged = onStateChanged
            state.startCount += 1
        }
    }

    func invalidate() {
        state.withLock { state in
            guard !state.isInvalidated else { return }
            state.isInvalidated = true
            state.onResultsChanged = nil
            state.onStateChanged = nil
            state.cancelCount += 1
        }
    }

    func emit(_ browserState: DeviceDiscoveryBrowserState) {
        let onStateChanged = state.withLock { $0.onStateChanged }
        onStateChanged?(browserState)
    }
}
