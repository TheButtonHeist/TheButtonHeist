import Foundation
import ButtonHeistSupport

/// Fires a callback after a period of inactivity.
/// `withActivity` suspends expiry while work runs; `resetTimer` starts idle monitoring.
@ButtonHeistActor
@_spi(ButtonHeistTooling) public final class IdleMonitor {
    private enum State {
        case idle(Task<Void, Never>?)
        case active(count: Int)
        case stopped
    }

    private let timeout: TimeInterval
    private let onTimeout: @ButtonHeistActor () -> Void
    private var state = State.idle(nil)

    public init(timeout: TimeInterval, onTimeout: @escaping @ButtonHeistActor () -> Void) {
        self.timeout = timeout
        self.onTimeout = onTimeout
    }

    /// Suspend idle expiry until all overlapping activities finish.
    public func withActivity<Value>(
        _ operation: @ButtonHeistActor () async throws -> Value
    ) async rethrows -> Value {
        switch state {
        case .idle(let timer):
            timer?.cancel()
            state = .active(count: 1)
        case .active(let count):
            state = .active(count: count + 1)
        case .stopped:
            return try await operation()
        }
        defer { finishActivity() }
        return try await operation()
    }

    public func resetTimer() {
        if case .active = state { return }
        stop()
        state = .idle(nil)
        guard timeout > 0 else { return }
        state = .idle(Task { [weak self, timeout] in
            guard await Task.cancellableSleep(for: .saturatingSeconds(timeout)) else { return }
            guard !Task.isCancelled, let self else { return }
            self.state = .idle(nil)
            self.onTimeout()
        })
    }

    public func stop() {
        if case .idle(let timer) = state { timer?.cancel() }
        state = .stopped
    }

    /// Whether idle expiry is scheduled, for deterministic lifecycle tests.
    var hasPendingTimer: Bool {
        guard case .idle(let task?) = state else { return false }
        return !task.isCancelled
    }

    private func finishActivity() {
        guard case .active(let count) = state else { return }
        if count > 1 {
            state = .active(count: count - 1)
        } else {
            state = .idle(nil)
            resetTimer()
        }
    }
}
