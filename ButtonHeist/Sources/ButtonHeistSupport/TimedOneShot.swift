import os

package struct TimedOneShot<Value: Sendable>: Sendable {
    private enum State {
        case pending(timer: Task<Void, Never>?)
        case registered(CheckedContinuation<Value, Never>, timer: Task<Void, Never>?)
        case resolved
    }

    private let lock = OSAllocatedUnfairLock(initialState: State.pending(timer: nil))

    package init() {}

    package func register(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        lock.withLock { state -> Bool in
            switch state {
            case .pending(let timer):
                state = .registered(continuation, timer: timer)
                return true
            case .registered:
                preconditionFailure("TimedOneShot registered twice")
            case .resolved:
                return false
            }
        }
    }

    @discardableResult
    package func resolve(returning value: Value) -> Bool {
        let resolved = lock.withLock { state -> (continuation: CheckedContinuation<Value, Never>?, timer: Task<Void, Never>?, didResolve: Bool) in
            switch state {
            case .pending(let timer):
                state = .resolved
                return (nil, timer, true)
            case .registered(let continuation, let timer):
                state = .resolved
                return (continuation, timer, true)
            case .resolved:
                return (nil, nil, false)
            }
        }
        resolved.timer?.cancel()
        resolved.continuation?.resume(returning: value)
        return resolved.didResolve
    }

    @discardableResult
    package func armTimeout(
        after duration: Duration,
        _ operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        let canArm = lock.withLock { state -> Bool in
            if case .resolved = state {
                return false
            }
            return true
        }
        guard canArm else { return false }

        let task = Task { @concurrent in
            guard await Task.cancellableSleep(for: duration) else { return }
            await operation()
        }

        let replaced = lock.withLock { state -> (replaced: Task<Void, Never>?, didArm: Bool) in
            switch state {
            case .pending(let existing):
                state = .pending(timer: task)
                return (existing, true)
            case .registered(let continuation, let existing):
                state = .registered(continuation, timer: task)
                return (existing, true)
            case .resolved:
                return (task, false)
            }
        }
        replaced.replaced?.cancel()
        return replaced.didArm
    }

    package func cancelTimeout() {
        let timer = lock.withLock { state -> Task<Void, Never>? in
            switch state {
            case .pending(let timer):
                state = .pending(timer: nil)
                return timer
            case .registered(let continuation, let timer):
                state = .registered(continuation, timer: nil)
                return timer
            case .resolved:
                return nil
            }
        }
        timer?.cancel()
    }
}

package extension TimedOneShot {
    func wait(
        isolation: isolated (any Actor)? = #isolation,
        cancellationValue: @autoclosure @escaping @Sendable () -> Value,
        onRegistered: (TimedOneShot<Value>) -> Void,
        onFinished: () -> Void = {}
    ) async -> Value {
        let result = await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                    if Task.isCancelled {
                        continuation.resume(returning: cancellationValue())
                        return
                    }
                    guard register(continuation) else {
                        continuation.resume(returning: cancellationValue())
                        return
                    }
                    onRegistered(self)
                }
            },
            onCancel: {
                _ = resolve(returning: cancellationValue())
            }
        )
        onFinished()
        return result
    }
}
