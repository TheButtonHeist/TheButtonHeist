#if canImport(UIKit)
#if DEBUG
import ButtonHeistSupport
import os
import XCTest

@testable import TheInsideJob
import TheScore

final class TheBrainsInteractionRequestTests: XCTestCase {
    @MainActor
    func testAdmissionStopsAtPendingCapacity() async {
        let brains = TheBrains(tripwire: TheTripwire())
        let activeGate = PipelineTestGate()

        XCTAssertEqual(brains.submitTransportRequest(lease: testLease(0)) {
            await activeGate.suspend()
        }, .accepted)
        await activeGate.entered.wait()

        for clientId in 1...64 {
            XCTAssertEqual(
                brains.submitTransportRequest(lease: testLease(clientId)) {},
                .accepted
            )
        }
        XCTAssertEqual(
            brains.submitTransportRequest(lease: testLease(65)) {},
            .rejected(.busy(capacity: 64))
        )

        activeGate.release()
        await brains.stopInteractionRequests()
    }

    @MainActor
    func testOwnerCancellationRetainsOtherQueuedRequestsInFIFOOrder() async {
        let brains = TheBrains(tripwire: TheTripwire())
        let activeGate = PipelineTestGate()
        let retainedCompleted = CompletionSignal()
        let endedLease = TransportClientLease(clientId: 2, incarnation: 1)
        let replacementLease = TransportClientLease(clientId: 2, incarnation: 2)
        var trace: [String] = []

        brains.submitTransportRequest(lease: testLease(1)) {
            trace.append("active")
            await activeGate.suspend()
        }
        await activeGate.entered.wait()
        brains.submitTransportRequest(lease: endedLease) {
            trace.append("cancelled")
        }
        brains.submitTransportRequest(lease: replacementLease) {
            trace.append("retained")
            retainedCompleted.finish()
        }

        brains.cancelTransportRequests(lease: endedLease)
        activeGate.release()
        await retainedCompleted.wait()
        XCTAssertEqual(trace, ["active", "retained"])
        await brains.stopInteractionRequests()
    }

    @MainActor
    func testCancelledActiveRequestFinishesCleanupBeforeQueueAdvances() async {
        let brains = TheBrains(tripwire: TheTripwire())
        let activeGate = PipelineTestGate()
        let nextGate = PipelineTestGate()
        let lastCompleted = CompletionSignal()
        var trace: [String] = []

        brains.submitTransportRequest(lease: testLease(1)) {
            trace.append("active-start")
            await activeGate.suspendIgnoringCancellation()
            trace.append("active-cleanup")
        }
        await activeGate.entered.wait()
        brains.submitTransportRequest(lease: testLease(2)) {
            trace.append("next-start")
            await nextGate.suspend()
            trace.append("next-finish")
        }
        brains.submitTransportRequest(lease: testLease(3)) {
            trace.append("last")
            lastCompleted.finish()
        }

        brains.cancelTransportRequests(lease: testLease(1))
        XCTAssertEqual(trace, ["active-start"])

        activeGate.release()
        await nextGate.entered.wait()
        XCTAssertEqual(trace, ["active-start", "active-cleanup", "next-start"])
        XCTAssertFalse(lastCompleted.isFinished)

        brains.cancelTransportRequests(lease: testLease(1))
        nextGate.release()
        await lastCompleted.wait()
        XCTAssertEqual(
            trace,
            ["active-start", "active-cleanup", "next-start", "next-finish", "last"]
        )
        await brains.stopInteractionRequests()
    }

    @MainActor
    func testOwnerCancellationCancelsTheActiveOperationTask() async {
        let executor = InteractionRequestExecutor()
        let activeGate = PipelineTestGate()
        let cancellationObserved = OSAllocatedUnfairLock(initialState: false)

        XCTAssertEqual(executor.submit(owner: .transportClient(testLease(1)), operation: {
            await withTaskCancellationHandler {
                await activeGate.suspend()
            } onCancel: {
                cancellationObserved.withLock { $0 = true }
            }
        }, completion: { _ in }), .accepted)
        await activeGate.entered.wait()

        executor.cancel(owner: .transportClient(testLease(1)))

        XCTAssertTrue(cancellationObserved.withLock { $0 })
        activeGate.release()
        await executor.drain()
    }

    @MainActor
    func testCallerCancellationCancelsActiveInAppRequest() async {
        let brains = TheBrains(tripwire: TheTripwire())
        let activeGate = PipelineTestGate()
        let cancellationObserved = OSAllocatedUnfairLock(initialState: false)

        let request = Task { @MainActor in
            await brains.executeInAppRequest {
                await withTaskCancellationHandler {
                    await activeGate.suspendIgnoringCancellation()
                    return "completed"
                } onCancel: {
                    cancellationObserved.withLock { $0 = true }
                }
            }
        }
        await activeGate.entered.wait()

        request.cancel()
        activeGate.release()

        guard case .cancelled = await request.value else {
            return XCTFail("Expected caller cancellation to cancel the active in-app request")
        }
        XCTAssertTrue(cancellationObserved.withLock { $0 })
        await brains.stopInteractionRequests()
    }

    @MainActor
    func testCallerCancellationRemovesOnlyItsQueuedInAppRequest() async {
        let brains = TheBrains(tripwire: TheTripwire())
        let activeGate = PipelineTestGate()
        let cancelledSubmissionStarted = CompletionSignal()
        let retainedSubmissionStarted = CompletionSignal()
        let trace = OSAllocatedUnfairLock(initialState: [String]())

        brains.submitTransportRequest(lease: testLease(1)) {
            trace.withLock { $0.append("active") }
            await activeGate.suspend()
        }
        await activeGate.entered.wait()

        let cancelled = Task { @MainActor in
            cancelledSubmissionStarted.finish()
            return await brains.executeInAppRequest {
                trace.withLock { $0.append("cancelled") }
                return "cancelled"
            }
        }
        await cancelledSubmissionStarted.wait()

        let retained = Task { @MainActor in
            retainedSubmissionStarted.finish()
            return await brains.executeInAppRequest {
                trace.withLock { $0.append("retained") }
                return "retained"
            }
        }
        await retainedSubmissionStarted.wait()

        cancelled.cancel()
        guard case .cancelled = await cancelled.value else {
            return XCTFail("Expected caller cancellation to remove the queued in-app request")
        }

        activeGate.release()
        guard case .completed(let value) = await retained.value else {
            return XCTFail("Expected the unrelated queued in-app request to complete")
        }
        XCTAssertEqual(value, "retained")
        XCTAssertEqual(trace.withLock { $0 }, ["active", "retained"])
        await brains.stopInteractionRequests()
    }

    @MainActor
    func testAlreadyCancelledCallerDoesNotAdmitInAppRequest() async {
        let brains = TheBrains(tripwire: TheTripwire())
        let operationExecuted = OSAllocatedUnfairLock(initialState: false)

        let request = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await brains.executeInAppRequest {
                operationExecuted.withLock { $0 = true }
                return "completed"
            }
        }

        guard case .cancelled = await request.value else {
            return XCTFail("Expected an already-cancelled caller to reject in-app execution")
        }
        XCTAssertFalse(operationExecuted.withLock { $0 })
        await brains.stopInteractionRequests()
    }

    @MainActor
    func testDrainDeadlineReleasesWaitersAndRejectsAdmissionUntilLateOperationReturns() async {
        let deadline = ManualInteractionCleanupDeadline()
        let executor = InteractionRequestExecutor(
            cleanupDeadlineScheduler: deadline.schedule
        )
        let activeGate = PipelineTestGate()
        let drainCompleted = CompletionSignal()
        let joinedDrainCompleted = CompletionSignal()
        let lateReturn = CompletionSignal()
        let replacementCompleted = CompletionSignal()
        var activeCancellationCount = 0
        var rejectedReplacementCount = 0
        var trace = ["active-start"]

        XCTAssertEqual(executor.submit(owner: .inApp, operation: {
            await activeGate.suspendIgnoringCancellation()
            trace.append("active-effect")
            lateReturn.finish()
        }, completion: { outcome in
            if case .cancelled = outcome {
                activeCancellationCount += 1
            }
        }), .accepted)
        await activeGate.entered.wait()

        let drain = Task { @MainActor in
            await executor.drain()
            drainCompleted.finish()
        }
        let joinedDrain = Task { @MainActor in
            await executor.drain()
            joinedDrainCompleted.finish()
        }
        await Task.yield()
        XCTAssertEqual(activeCancellationCount, 1)
        XCTAssertFalse(drainCompleted.isFinished)
        XCTAssertFalse(joinedDrainCompleted.isFinished)

        deadline.fire()
        await drain.value
        await joinedDrain.value
        XCTAssertTrue(drainCompleted.isFinished)
        XCTAssertTrue(joinedDrainCompleted.isFinished)
        XCTAssertEqual(executor.submit(owner: .inApp, operation: {
            trace.append("rejected-replacement")
        }, completion: { outcome in
            if case .rejected(.cleanupTimedOut) = outcome {
                rejectedReplacementCount += 1
            }
        }), .rejected(.cleanupTimedOut))
        XCTAssertEqual(rejectedReplacementCount, 1)
        XCTAssertEqual(trace, ["active-start"])

        activeGate.release()
        await lateReturn.wait()
        await Task.yield()
        XCTAssertEqual(activeCancellationCount, 1)
        XCTAssertEqual(executor.submit(owner: .inApp, operation: {
            trace.append("replacement")
            replacementCompleted.finish()
        }, completion: { _ in }), .accepted)
        await replacementCompleted.wait()
        XCTAssertEqual(trace, ["active-start", "active-effect", "replacement"])
        await executor.drain()
    }

    @MainActor
    func testDrainAfterExpiredCancellationRejectsAdmissionUntilCleanupReturns() async {
        let deadline = ManualInteractionCleanupDeadline()
        let executor = InteractionRequestExecutor(
            cleanupDeadlineScheduler: deadline.schedule
        )
        let activeGate = PipelineTestGate()
        let lateReturn = CompletionSignal()
        var activeCancellationCount = 0
        var queuedCancellationCount = 0

        XCTAssertEqual(executor.submit(owner: .transportClient(testLease(1)), operation: {
            await activeGate.suspendIgnoringCancellation()
            lateReturn.finish()
        }, completion: { outcome in
            if case .cancelled = outcome {
                activeCancellationCount += 1
            }
        }), .accepted)
        await activeGate.entered.wait()
        XCTAssertEqual(executor.submit(owner: .transportClient(testLease(2)), operation: {}, completion: { outcome in
            if case .cancelled = outcome {
                queuedCancellationCount += 1
            }
        }), .accepted)

        executor.cancel(owner: .transportClient(testLease(1)))
        XCTAssertEqual(activeCancellationCount, 1)
        deadline.fire()
        XCTAssertEqual(queuedCancellationCount, 1)
        XCTAssertEqual(
            executor.submit(
                owner: .transportClient(testLease(3)),
                operation: {},
                completion: { _ in }
            ),
            .rejected(.cleanupTimedOut)
        )

        let drainStarted = CompletionSignal()
        let drain = Task { @MainActor in
            drainStarted.finish()
            await executor.drain()
        }
        await drainStarted.wait()
        await drain.value
        XCTAssertEqual(activeCancellationCount, 1)
        XCTAssertEqual(
            executor.submit(
                owner: .transportClient(testLease(3)),
                operation: {},
                completion: { _ in }
            ),
            .rejected(.cleanupTimedOut)
        )
        activeGate.release()
        await lateReturn.wait()
        await Task.yield()
        XCTAssertEqual(
            executor.submit(
                owner: .transportClient(testLease(3)),
                operation: {},
                completion: { _ in }
            ),
            .accepted
        )
        await executor.drain()
    }
}

@MainActor
private final class ManualInteractionCleanupDeadline {
    private var deadlineReached: (@MainActor @Sendable () -> Void)?

    func schedule(
        _ deadlineReached: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        self.deadlineReached = deadlineReached
        return Task {}
    }

    func fire() {
        let operation = deadlineReached
        self.deadlineReached = nil
        operation?()
    }
}

private final class PipelineTestGate: Sendable {
    let entered = CompletionSignal()
    private let released = CompletionSignal()

    func suspend() async {
        entered.finish()
        await released.wait()
    }

    func suspendIgnoringCancellation() async {
        entered.finish()
        await Task { [released] in
            await released.wait()
        }.value
    }

    func release() {
        released.finish()
    }
}

final class ClientRequestPipelineTests: XCTestCase {
    @MainActor
    func testSameClientControlProgressesAndDisconnectCancelsLaterUIWork() async {
        let brains = TheBrains(tripwire: TheTripwire())
        let uiGate = PipelineTestGate()
        let controlCompleted = CompletionSignal()
        let controlTrace = OSAllocatedUnfairLock(initialState: [String]())
        let secondUIExecuted = OSAllocatedUnfairLock(initialState: false)
        let pipeline = ClientRequestPipeline { request in
            switch request.text {
            case "first-ui":
                _ = await MainActor.run {
                    brains.submitTransportRequest(lease: request.lease) {
                        await uiGate.suspend()
                    }
                }
            case "ping":
                controlTrace.withLock { $0.append("ping") }
            case "status":
                controlTrace.withLock { $0.append("status") }
                controlCompleted.finish()
            case "second-ui":
                _ = await MainActor.run {
                    brains.submitTransportRequest(lease: request.lease) {
                        secondUIExecuted.withLock { $0 = true }
                    }
                }
            default:
                XCTFail("Unexpected request")
            }
        }

        XCTAssertEqual(pipeline.enqueue(request(clientId: 1, requestId: "first-ui")), .enqueued)
        await uiGate.entered.wait()
        XCTAssertEqual(pipeline.enqueue(request(clientId: 1, requestId: "ping")), .enqueued)
        XCTAssertEqual(pipeline.enqueue(request(clientId: 1, requestId: "status")), .enqueued)
        XCTAssertEqual(pipeline.enqueue(request(clientId: 1, requestId: "second-ui")), .enqueued)
        await controlCompleted.wait()
        XCTAssertEqual(controlTrace.withLock { $0 }, ["ping", "status"])
        XCTAssertFalse(secondUIExecuted.withLock { $0 })

        let consumer = pipeline.stop()
        brains.cancelTransportRequests(lease: testLease(1))
        uiGate.release()
        await brains.stopInteractionRequests()
        await consumer?.value
        XCTAssertFalse(secondUIExecuted.withLock { $0 })
    }

    @MainActor
    func testAdmissionOverflowStopsAtItsNamedCapacity() async throws {
        let activeGate = PipelineTestGate()
        let executedRequestIds = OSAllocatedUnfairLock(initialState: [String]())
        let pipeline = ClientRequestPipeline { request in
            executedRequestIds.withLock { $0.append(request.text) }
            await activeGate.suspend()
        }

        XCTAssertEqual(pipeline.enqueue(request(clientId: 1, requestId: "active")), .enqueued)
        await activeGate.entered.wait()
        for requestIndex in 0..<ClientRequestPipeline.maximumQueuedRequests {
            let requestID = try RequestID(validating: "queued-\(requestIndex)")
            XCTAssertEqual(
                pipeline.enqueue(request(clientId: 1, requestId: requestID)),
                .enqueued
            )
        }

        XCTAssertEqual(
            pipeline.enqueue(request(clientId: 1, requestId: "overflow")),
            .overflowed
        )
        XCTAssertEqual(pipeline.enqueue(request(clientId: 1, requestId: "late")), .stopped)

        let consumer = pipeline.stop()
        activeGate.release()
        await consumer?.value
        XCTAssertEqual(executedRequestIds.withLock { $0 }, ["active"])
    }

    @MainActor
    func testBlockedClientDoesNotDelayAnotherClient() async {
        let blocked = PipelineTestGate()
        let otherClientCompleted = CompletionSignal()
        let first = ClientRequestPipeline { request in
            if request.text == "blocked" {
                await blocked.suspend()
            }
        }
        let second = ClientRequestPipeline { request in
            if request.text == "ping" {
                otherClientCompleted.finish()
            }
        }

        XCTAssertEqual(first.enqueue(request(clientId: 1, requestId: "blocked")), .enqueued)
        await blocked.entered.wait()
        XCTAssertEqual(second.enqueue(request(clientId: 2, requestId: "ping")), .enqueued)

        await otherClientCompleted.wait()

        blocked.release()
        let firstConsumer = first.stop()
        let secondConsumer = second.stop()
        await firstConsumer?.value
        await secondConsumer?.value
    }

    @MainActor
    func testRequestsFromOneClientExecuteInExactOrder() async {
        let blocked = PipelineTestGate()
        let secondCompleted = CompletionSignal()
        let trace = OSAllocatedUnfairLock(initialState: [String]())
        let pipeline = ClientRequestPipeline { request in
            let requestId = request.text
            trace.withLock { $0.append("start-\(requestId)") }
            if requestId == "first" {
                await blocked.suspend()
            }
            trace.withLock { $0.append("finish-\(requestId)") }
            if requestId == "second" {
                secondCompleted.finish()
            }
        }

        XCTAssertEqual(pipeline.enqueue(request(clientId: 1, requestId: "first")), .enqueued)
        XCTAssertEqual(pipeline.enqueue(request(clientId: 1, requestId: "second")), .enqueued)
        await blocked.entered.wait()
        XCTAssertEqual(trace.withLock { $0 }, ["start-first"])

        blocked.release()
        await secondCompleted.wait()

        XCTAssertEqual(
            trace.withLock { $0 },
            ["start-first", "finish-first", "start-second", "finish-second"]
        )
        let consumer = pipeline.stop()
        await consumer?.value
    }

    @MainActor
    func testStopCancelsQueuedClientWork() async {
        let blocked = PipelineTestGate()
        let executedRequestIds = OSAllocatedUnfairLock(initialState: [String]())
        let pipeline = ClientRequestPipeline { request in
            let requestId = request.text
            executedRequestIds.withLock { $0.append(requestId) }
            if requestId == "active" {
                await blocked.suspend()
            }
        }

        XCTAssertEqual(pipeline.enqueue(request(clientId: 1, requestId: "active")), .enqueued)
        XCTAssertEqual(pipeline.enqueue(request(clientId: 1, requestId: "queued")), .enqueued)
        await blocked.entered.wait()

        let consumer = pipeline.stop()
        blocked.release()
        await consumer?.value

        XCTAssertEqual(executedRequestIds.withLock { $0 }, ["active"])
        XCTAssertEqual(pipeline.enqueue(request(clientId: 1, requestId: "late")), .stopped)
    }

    @MainActor
    private func request(clientId: Int, requestId: RequestID) -> ClientTransportRequest {
        ClientTransportRequest(
            lease: testLease(clientId),
            data: Data(requestId.description.utf8),
            respond: { _ in .delivered }
        )
    }
}

private func testLease(_ clientId: Int) -> TransportClientLease {
    TransportClientLease(clientId: clientId, incarnation: 1)
}

private extension ClientTransportRequest {
    var text: String {
        String(bytes: data, encoding: .utf8) ?? ""
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
