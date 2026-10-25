import ButtonHeistSupport
import Testing

@Suite struct AsyncCoordinationPrimitivesTests {
    @Test func `completion signal supports finish before wait`() async {
        let signal = CompletionSignal()

        signal.finish()

        await signal.wait()
        #expect(signal.isFinished)
    }

    @Test func `completion signal resumes every waiter`() async {
        let signal = CompletionSignal()
        let first = Task { await signal.wait(timeout: .seconds(30)) }
        let second = Task { await signal.wait(timeout: .seconds(30)) }

        signal.finish()

        let firstFinished = await first.value
        let secondFinished = await second.value
        #expect(firstFinished)
        #expect(secondFinished)
    }

    @Test func `completion signal finish is idempotent`() async {
        let signal = CompletionSignal()
        let waiter = Task { await signal.wait(timeout: .seconds(30)) }

        signal.finish()
        signal.finish()

        let didFinish = await waiter.value
        #expect(didFinish)
        #expect(signal.isFinished)
    }

    @Test func `completion signal timeout preserves later completion`() async {
        let signal = CompletionSignal()

        let didFinishBeforeTimeout = await signal.wait(timeout: .milliseconds(1))
        #expect(!didFinishBeforeTimeout)
        #expect(!signal.isFinished)
        signal.finish()
        let didFinishImmediately = await signal.wait(timeout: .zero)
        #expect(didFinishImmediately)
    }

    @Test func `resolve before timeout drains waiter and cancels timer`() async {
        let harness = WaiterHarness()
        let task = Task {
            await harness.wait(key: "resolve", timeout: .seconds(30), timeoutValue: 99)
        }

        let didRegister = await waitUntil { await harness.count == 1 }
        #expect(didRegister)
        let didResolve = await harness.resolve("resolve", returning: 7)
        #expect(didResolve)
        let value = await task.value
        let waiterCount = await harness.count
        let timeoutFireCount = await harness.timeoutFireCount
        #expect(value == 7)
        #expect(waiterCount == 0)
        #expect(timeoutFireCount == 0)
    }

    @Test func `timeout before resolve drains waiter and rejects stale resolve`() async {
        let harness = WaiterHarness()
        let task = Task {
            await harness.wait(key: "timeout", timeout: .milliseconds(1), timeoutValue: 42)
        }

        let value = await task.value
        let timeoutFireCount = await harness.timeoutFireCount
        let waiterCount = await harness.count
        #expect(value == 42)
        #expect(timeoutFireCount == 1)
        #expect(waiterCount == 0)
        let didResolve = await harness.resolve("timeout", returning: 7)
        #expect(!didResolve)
    }

    @Test func `cancellation resumes and unregisters waiter`() async {
        let harness = WaiterHarness()
        let task = Task {
            await harness.wait(key: "cancel", timeout: .seconds(30), timeoutValue: 99)
        }

        let didRegister = await waitUntil { await harness.count == 1 }
        #expect(didRegister)
        task.cancel()

        let value = await task.value
        let didUnregister = await waitUntil { await harness.count == 0 }
        #expect(value == WaiterHarness.cancelledValue)
        #expect(didUnregister)
        let didResolve = await harness.resolve("cancel", returning: 7)
        #expect(!didResolve)
    }

    @Test func `duplicate and stale resolution only resolves once`() async {
        let harness = WaiterHarness()
        let task = Task {
            await harness.wait(key: "once", timeout: nil, timeoutValue: 99)
        }

        let didRegister = await waitUntil { await harness.count == 1 }
        #expect(didRegister)
        let didResolve = await harness.resolve("once", returning: 3)
        let didResolveAgain = await harness.resolve("once", returning: 4)
        #expect(didResolve)
        #expect(!didResolveAgain)
        let value = await task.value
        let waiterCount = await harness.count
        #expect(value == 3)
        #expect(waiterCount == 0)
        let didResolveMissing = await harness.resolve("missing", returning: 5)
        #expect(!didResolveMissing)
    }

    @Test func `synchronous resolution still runs waiter cleanup`() async {
        let harness = WaiterHarness()

        let value = await harness.waitResolvingDuringRegistration(key: "immediate", returning: 11)
        let waiterCount = await harness.count
        #expect(value == 11)
        #expect(waiterCount == 0)
        let didResolveAgain = await harness.resolve("immediate", returning: 12)
        #expect(!didResolveAgain)
    }
}

private actor WaiterHarness {
    static let cancelledValue = -1

    private var waiters = WaiterStore<String, TimedOneShot<Int>>()
    private(set) var timeoutFireCount = 0

    var count: Int {
        waiters.count
    }

    func wait(key: String, timeout: Duration?, timeoutValue: Int) async -> Int {
        let oneShot = TimedOneShot<Int>()
        return await oneShot.wait(
            cancellationValue: Self.cancelledValue,
            onRegistered: { oneShot in
                self.preconditionIsolated()
                waiters.insert(oneShot, for: key)
                if let timeout {
                    oneShot.armTimeout(after: timeout) { [weak self] in
                        await self?.timeout(key: key, returning: timeoutValue)
                    }
                }
            },
            onFinished: {
                self.preconditionIsolated()
                waiters.resolve(key, returning: Self.cancelledValue)
            }
        )
    }

    func waitResolvingDuringRegistration(key: String, returning value: Int) async -> Int {
        let oneShot = TimedOneShot<Int>()
        return await oneShot.wait(
            cancellationValue: Self.cancelledValue,
            onRegistered: { oneShot in
                self.preconditionIsolated()
                waiters.insert(oneShot, for: key)
                oneShot.resolve(returning: value)
            },
            onFinished: {
                self.preconditionIsolated()
                waiters.resolve(key, returning: Self.cancelledValue)
            }
        )
    }

    @discardableResult
    func resolve(_ key: String, returning value: Int) -> Bool {
        waiters.resolve(key, returning: value)
    }

    private func timeout(key: String, returning value: Int) {
        timeoutFireCount += 1
        waiters.resolve(key, returning: value)
    }
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if await condition() {
            return true
        }
        await Task.yield()
    }
    return await condition()
}
