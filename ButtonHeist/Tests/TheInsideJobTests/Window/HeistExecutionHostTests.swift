#if canImport(UIKit)
#if DEBUG
import ButtonHeistSupport
import UIKit
import XCTest

@_spi(ButtonHeistInternals) @testable import ThePlans
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

@MainActor
final class HeistExecutionHostTests: ButtonHeistTestCase {
    func testCancellationCompletesBeforePendingFailureCaptureReturns() async throws {
        let tripwire = TheTripwire()
        let brains = TheBrains(
            tripwire: tripwire,
            failureEvidencePolicy: .screenshot,
            notificationIngress: .injected,
            pulseIngress: .injected
        )
        let captureEntered = CompletionSignal()
        let captureReleased = CompletionSignal()
        let captureReturned = CompletionSignal()
        var captureRequestCount = 0
        let stream = brains.vault.semanticObservationStream
        stream.start()
        defer {
            captureReleased.finish()
            stream.stop()
        }
        let boundary = HeistExecution.Host.RuntimeBoundary(
            now: { RuntimeElapsed.now },
            wait: { _ in false },
            dispatch: { command, _ in
                .failure(
                    .empty(for: command.type),
                    message: "Unexpected action dispatch"
                )
            },
            explore: { _, _ in .init(viewportExit: .failed(.originUnavailable), coverage: .complete) },
            captureFailure: { _, _ in
                captureRequestCount += 1
                captureEntered.finish()
                await Task { [captureReleased] in
                    await captureReleased.wait()
                }.value
                captureReturned.finish()
                return .unavailable(
                    kind: .actionFailed,
                    message: "fixture capture unavailable"
                )
            }
        )
        let execution = Task { @MainActor in
            try await HeistExecution.Host(
                brains: brains,
                runtimeBoundary: boundary
            ).execute(
                try HeistPlan(body: [
                    .fail(FailStep(message: try .init(validating: "expected failure"))),
                ]),
                timeout: try .seconds(60)
            )
        }
        await captureEntered.wait()

        execution.cancel()
        do {
            _ = try await execution.value
            XCTFail("Expected cancelled execution")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertFalse(captureReturned.isFinished)

        captureReleased.finish()
        await captureReturned.wait()
        XCTAssertEqual(captureRequestCount, 1)
    }

    func testDeadlineDoesNotEndLaterEventDelivery() async {
        let deadline = HostDeadlineProbe([.elapsed, .suspended])
        let inbox = HeistExecution.Host.ObservationInbox(
            waitUntilDeadline: deadline.wait
        )
        let now = RuntimeElapsed.now

        let first = await inbox.wait(
            for: waitRequest(id: 1, at: now),
            at: now
        )
        XCTAssertEqual(first, .deadline)

        let laterWait = Task { @MainActor in
            await inbox.wait(
                for: waitRequest(id: 2, at: now),
                at: now
            )
        }
        await deadline.waitUntilEntered(2)
        inbox.yield(entry(.noChange, at: 0))

        let later = await laterWait.value
        XCTAssertEqual(later, .event(.noChange))
    }

    func testCancelledDeadlineCannotResolveRepeatedReducerWait() async {
        let deadline = HostDeadlineProbe([.suspended, .suspended])
        let inbox = HeistExecution.Host.ObservationInbox(
            waitUntilDeadline: deadline.wait
        )
        let now = RuntimeElapsed.now
        let request = waitRequest(id: 1, at: now)

        let firstWait = Task { @MainActor in
            await inbox.wait(for: request, at: now)
        }
        await deadline.waitUntilEntered(1)
        inbox.yield(entry(.noChange, at: 0))
        let first = await firstWait.value
        XCTAssertEqual(first, .event(.noChange))

        let repeatedWait = Task { @MainActor in
            await inbox.wait(for: request, at: now)
        }
        await deadline.waitUntilEntered(2)
        inbox.yield(entry(.noChange, at: 0))

        let repeated = await repeatedWait.value
        XCTAssertEqual(repeated, .event(.noChange))
    }

    func testInboxCancellationIsAnExplicitOutcome() async {
        let deadline = HostDeadlineProbe([.suspended])
        let inbox = HeistExecution.Host.ObservationInbox(
            waitUntilDeadline: deadline.wait
        )
        let now = RuntimeElapsed.now
        let wait = Task { @MainActor in
            await inbox.wait(
                for: waitRequest(id: 1, at: now),
                at: now
            )
        }
        await deadline.waitUntilEntered(1)

        wait.cancel()

        let outcome = await wait.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testQueuedEventWinsBeforeDeadlineInstallation() async {
        let deadline = HostDeadlineProbe([.elapsed])
        let inbox = HeistExecution.Host.ObservationInbox(
            waitUntilDeadline: deadline.wait
        )
        let now = RuntimeElapsed.now
        inbox.yield(entry(.noChange, at: 0))

        let outcome = await inbox.wait(
            for: waitRequest(id: 1, at: now),
            at: now
        )

        XCTAssertEqual(outcome, .event(.noChange))
    }

    func testObservationBaselineDiscardsLateDeliveredPreBoundaryEvent() async {
        let deadline = HostDeadlineProbe([.suspended])
        let inbox = HeistExecution.Host.ObservationInbox(
            waitUntilDeadline: deadline.wait
        )
        let now = RuntimeElapsed.now
        let postBaseline = notificationEvent("After baseline")

        inbox.advance(to: historyBoundary(at: 5))
        inbox.yield(entry(.noChange, at: 4))

        let wait = Task { @MainActor in
            await inbox.wait(
                for: waitRequest(id: 1, at: now),
                at: now
            )
        }
        await deadline.waitUntilEntered(1)
        inbox.yield(entry(postBaseline, at: 5))

        let outcome = await wait.value
        XCTAssertEqual(outcome, .event(postBaseline))
    }

    func testObservationBaselineDeliversPostBoundaryEventsInFIFOOrder() async {
        let deadline = HostDeadlineProbe([])
        let inbox = HeistExecution.Host.ObservationInbox(
            waitUntilDeadline: deadline.wait
        )
        let now = RuntimeElapsed.now
        let first = notificationEvent("First after baseline")
        let second = notificationEvent("Second after baseline")

        inbox.yield(entry(.noChange, at: 4))
        inbox.advance(to: historyBoundary(at: 5))
        inbox.yield(entry(first, at: 5))
        inbox.yield(entry(second, at: 6))

        let firstOutcome = await inbox.wait(
            for: waitRequest(id: 1, at: now),
            at: now
        )
        let secondOutcome = await inbox.wait(
            for: waitRequest(id: 2, at: now),
            at: now
        )

        XCTAssertEqual(firstOutcome, .event(first))
        XCTAssertEqual(secondOutcome, .event(second))
    }

    func testDispatchCompletionRetainsTransientEvidenceButDiscardsEarlierStillness() async {
        let deadline = HostDeadlineProbe([.suspended])
        let inbox = HeistExecution.Host.ObservationInbox(
            waitUntilDeadline: deadline.wait
        )
        let now = RuntimeElapsed.now
        let transient = notificationEvent("Activation refused")

        inbox.advance(to: historyBoundary(at: 5))
        inbox.yield(entry(transient, at: 5))
        inbox.yield(entry(.noChange, at: 6))
        inbox.advanceNoChange(to: 7)

        let transientOutcome = await inbox.wait(
            for: waitRequest(id: 1, at: now),
            at: now
        )
        XCTAssertEqual(transientOutcome, .event(transient))

        let stillnessWait = Task { @MainActor in
            await inbox.wait(
                for: waitRequest(id: 2, at: now),
                at: now
            )
        }
        await deadline.waitUntilEntered(1)
        inbox.yield(entry(.noChange, at: 7))

        let stillnessOutcome = await stillnessWait.value
        XCTAssertEqual(stillnessOutcome, .event(.noChange))
    }

    /// Physical canary: semantic Host coverage belongs to the deterministic
    /// runtime driver; this remains because it verifies UIKit viewport repair.
    func testCancellationRestoresPhysicalViewportAndAdmitsOneTerminalObservationCycle() async throws {
        let root = UIViewController()
        root.view.backgroundColor = .white
        root.view.accessibilityViewIsModal = true
        let scrollView = TrackingScrollView(
            frame: CGRect(x: 0, y: 40, width: 320, height: 240)
        )
        scrollView.contentSize = CGSize(width: 320, height: 960)
        let row = UILabel(frame: CGRect(x: 20, y: 20, width: 200, height: 44))
        row.text = "Visible Row"
        row.accessibilityLabel = "Visible Row"
        row.isAccessibilityElement = true
        scrollView.addSubview(row)
        root.view.addSubview(scrollView)
        present(root, above: true)

        let tripwire = TheTripwire()
        let brains = TheBrains(tripwire: tripwire, failureEvidencePolicy: .hierarchy)
        let forwardScroll = HostCaptureGate()
        scrollView.onForwardScroll = forwardScroll.arrive
        await brains.startTestObservation()
        defer {
            brains.stopTestObservation()
        }
        let initialContentOffset = scrollView.contentOffset

        let execution = Task { @MainActor in
            try await HeistExecution.Host(brains: brains).execute(
                try HeistPlan(body: [
                    .wait(WaitStep(
                        predicate: .exists(.label("Never Appears")),
                        timeout: 30
                    )),
                ]),
                timeout: try .seconds(60)
            )
        }
        await forwardScroll.waitUntilEntered()
        XCTAssertGreaterThan(scrollView.forwardScrollCount, 0)
        XCTAssertGreaterThan(scrollView.contentOffset.y, 0)
        execution.cancel()

        do {
            _ = try await execution.value
            XCTFail("Expected cancelled execution")
        } catch is CancellationError {
            // Expected after terminal restoration finishes.
        }

        XCTAssertEqual(scrollView.contentOffset, initialContentOffset)
    }

    private func waitRequest(
        id: UInt64,
        at now: RuntimeElapsed.Instant
    ) -> HeistExecution.WaitRequest {
        .init(
            id: .init(rawValue: id),
            deadline: .init(start: now, timeout: .seconds(1))
        )
    }

    private func notificationEvent(_ text: String) -> Observation.Event {
        guard let notification = Observation.Notification(text: text, element: nil) else {
            preconditionFailure("A textual notification is valid")
        }
        return .notification(notification)
    }

    private func entry(
        _ event: Observation.Event,
        at historyIndex: Int
    ) -> Observation.Publication.Entry {
        .init(historyIndex: historyIndex, event: event)
    }

    private func historyBoundary(
        at historyIndex: Int
    ) -> TheVault.State.HistoryBoundary {
        .init(baseline: nil, historyIndex: historyIndex)
    }

}

@MainActor
private final class HostDeadlineProbe {
    enum Response {
        case elapsed
        case suspended
    }

    private struct EntryWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct SuspendedWait {
        let id: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let responses: [Response]
    private var nextResponseIndex = 0
    private var entryWaiters: [EntryWaiter] = []
    private var suspendedWait: SuspendedWait?

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func wait(_: Duration) async -> Bool {
        precondition(nextResponseIndex < responses.count, "Deadline probe exhausted")
        let id = nextResponseIndex
        let response = responses[nextResponseIndex]
        nextResponseIndex += 1
        resumeEntryWaiters()
        switch response {
        case .elapsed:
            return true
        case .suspended:
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: false)
                        return
                    }
                    precondition(suspendedWait == nil, "Deadline probe admits one suspended wait")
                    suspendedWait = SuspendedWait(id: id, continuation: continuation)
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resolveSuspendedWait(id: id)
                }
            }
        }
    }

    func waitUntilEntered(_ count: Int) async {
        guard nextResponseIndex < count else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(EntryWaiter(
                count: count,
                continuation: continuation
            ))
        }
    }

    private func resumeEntryWaiters() {
        let ready = entryWaiters.filter { $0.count <= nextResponseIndex }
        entryWaiters.removeAll { $0.count <= nextResponseIndex }
        ready.forEach { $0.continuation.resume() }
    }

    private func resolveSuspendedWait(id: Int) {
        guard let suspendedWait, suspendedWait.id == id else { return }
        self.suspendedWait = nil
        suspendedWait.continuation.resume(returning: false)
    }
}

@MainActor
private final class HostCaptureGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func arrive() {
        guard !entered else { return }
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
}

@MainActor
private final class TrackingScrollView: UIScrollView {
    private(set) var forwardScrollCount = 0
    var onForwardScroll: (@MainActor () -> Void)?

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if contentOffset.y > self.contentOffset.y {
            forwardScrollCount += 1
            onForwardScroll?()
        }
        super.setContentOffset(contentOffset, animated: animated)
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
