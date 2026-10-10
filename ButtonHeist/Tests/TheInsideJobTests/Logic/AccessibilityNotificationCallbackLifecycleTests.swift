#if canImport(UIKit)
import Foundation
import XCTest

import TheScore
@testable import TheInsideJob

@MainActor
final class AccessibilityNotificationCallbackLifecycleTests: XCTestCase {
    func testDetachedDestinationRejectsCallbackRetainedByPrivateSPI() async throws {
        let harness = CallbackHarness()
        let observer = makeObserver(harness: harness)
        let bus = AccessibilityNotificationBus()
        observer.attach(bus)
        let callback = try XCTUnwrap(harness.callbacks.first)
        let actionWindow = bus.beginActionWindow()

        observer.detach(bus)
        callback(1000, nil, nil)

        let admittedCoverage = await actionWindow.admitCausallyCovered { Optional($0) }
        let coverage = try XCTUnwrap(admittedCoverage)
        XCTAssertEqual(
            coverage,
            AccessibilityNotificationCoverage(
                after: .origin,
                through: .origin,
                scopedScreenChangedThrough: 0
            )
        )
        XCTAssertTrue(
            bus.checkpoint(after: .origin, selection: .all).events.isEmpty
        )
        XCTAssertEqual(bus.latestSequence, 0)
    }

    func testInstalledCallbackFollowsTheSingleDestination() async throws {
        let harness = CallbackHarness()
        let observer = makeObserver(harness: harness)
        let original = AccessibilityNotificationBus()
        let replacement = AccessibilityNotificationBus()
        observer.attach(original)
        let callback = try XCTUnwrap(harness.callbacks.first)

        observer.detach(original)
        callback(1000, nil, nil)
        XCTAssertEqual(original.latestSequence, 0)

        observer.attach(replacement)
        defer { observer.detach(replacement) }
        XCTAssertEqual(harness.callbacks.count, 1)
        let activeWindow = replacement.beginActionWindow()
        callback(1000, nil, nil)
        callback(1005, nil, nil)
        callback(1008, "Current announcement" as NSString, nil)

        let admittedActiveCoverage = await activeWindow.admitCausallyCovered { Optional($0) }
        let activeCoverage = try XCTUnwrap(admittedActiveCoverage)
        let activeEvents = replacement.checkpoint(
            after: activeCoverage.after,
            selection: .all
        ).events
        XCTAssertEqual(activeWindow.cursor.sequence, 0)
        XCTAssertEqual(activeCoverage.through.sequence, 3)
        XCTAssertEqual(activeCoverage.scopedScreenChangedThrough, 1)
        XCTAssertEqual(activeEvents.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(
            activeEvents.map(\.kind),
            [.screenChanged, .elementUpdate, .announcement]
        )
        XCTAssertEqual(activeEvents.map(\.provenance), [.scoped, .scoped, .scoped])
        XCTAssertEqual(replacement.latestSequence, 3)
    }

    func testCallbacksDeliveredIntoOpenActionWindowHaveCompleteCausalCoverage() async throws {
        let harness = CallbackHarness()
        let observer = makeObserver(harness: harness)
        let bus = AccessibilityNotificationBus()
        observer.attach(bus)
        defer { observer.detach(bus) }
        let callback = try XCTUnwrap(harness.callbacks.first)
        let actionWindow = bus.beginActionWindow()

        callback(1000, nil, nil)
        callback(UInt32.max, nil, nil)
        let admittedCoverage = await actionWindow.admitCausallyCovered { Optional($0) }
        let coverage = try XCTUnwrap(admittedCoverage)
        let events = bus.checkpoint(
            after: coverage.after,
            selection: .all
        ).events

        XCTAssertEqual(actionWindow.cursor.sequence, 0)
        XCTAssertEqual(coverage.through.sequence, 2)
        XCTAssertEqual(coverage.scopedScreenChangedThrough, 1)
        XCTAssertEqual(events.map(\.sequence), [1, 2])
        XCTAssertEqual(events.map(\.kind), [.screenChanged, .unknown(.max)])
        XCTAssertEqual(events.map(\.provenance), [.scoped, .scoped])
    }

    func testMainActorDeliveryOrdersNotificationsBeforeLaterWork() async throws {
        let harness = CallbackHarness()
        let observer = makeObserver(harness: harness)
        let bus = AccessibilityNotificationBus()
        observer.attach(bus)
        defer { observer.detach(bus) }
        let callback = try XCTUnwrap(harness.callbacks.first)
        let heist = bus.beginHeistScope()
        defer { heist.cancel() }
        let action = bus.beginActionWindow()
        callback(1001, nil, nil)
        var unrelatedWorkRan = false
        let laterMainActorWork = Task { @MainActor in
            unrelatedWorkRan = true
            callback(1008, "After scheduled work" as NSString, nil)
        }

        let admittedCoverage = await action.admitCausallyCovered {
            Optional($0)
        }
        await laterMainActorWork.value
        let coverage = try XCTUnwrap(admittedCoverage)
        XCTAssertEqual(coverage.after, .origin)
        XCTAssertEqual(coverage.through.sequence, 1)
        XCTAssertTrue(unrelatedWorkRan)
        let events = bus.checkpoint(after: .origin, selection: .all).events
        guard events.count == 2,
              case .action = events[0].owner
        else {
            return XCTFail("Expected the first notification to belong to the action")
        }
        XCTAssertEqual(events[1].owner, .heist(heist.cursor))
    }

    func testFailedAdmissionRetriesSealedCoverageWithoutLaterIngress() async throws {
        let bus = AccessibilityNotificationBus()
        let action = bus.beginActionWindow()
        bus.recordForTesting(code: 1001, notificationData: .none, associatedElement: .none)
        let suspension = AdmissionSuspension()

        let failedAdmission = Task { @MainActor in
            await action.admitCausallyCovered { coverage -> Bool? in
                XCTAssertEqual(coverage.through.sequence, 1)
                await suspension.suspendAdmission()
                return nil
            }
        }
        await suspension.waitUntilSuspended()
        bus.recordForTesting(code: 1005, notificationData: .none, associatedElement: .none)
        await suspension.resumeAdmission()
        let failedResult = await failedAdmission.value
        XCTAssertNil(failedResult)

        bus.recordForTesting(code: 1008, notificationData: .none, associatedElement: .none)
        let retriedAdmission = await action.admitCausallyCovered { Optional($0) }
        let retriedCoverage = try XCTUnwrap(retriedAdmission)

        XCTAssertEqual(retriedCoverage.after, .origin)
        XCTAssertEqual(retriedCoverage.through.sequence, 1)
        let events = bus.checkpoint(after: .origin, selection: .all).events
        guard events.count == 3,
              case .action = events[0].owner
        else {
            return XCTFail("Expected the original callback to retain action ownership")
        }
        XCTAssertEqual(events[1].owner, .ambient)
        XCTAssertEqual(events[2].owner, .ambient)
    }

    func testCancellationAfterSealLetsSuccessfulAdmissionFinish() async throws {
        let bus = AccessibilityNotificationBus()
        let action = bus.beginActionWindow()
        bus.recordForTesting(code: 1001, notificationData: .none, associatedElement: .none)
        let suspension = AdmissionSuspension()

        let admission = Task { @MainActor in
            await action.admitCausallyCovered { coverage in
                await suspension.suspendAdmission()
                return coverage
            }
        }
        await suspension.waitUntilSuspended()
        action.cancel()
        bus.recordForTesting(code: 1005, notificationData: .none, associatedElement: .none)
        await suspension.resumeAdmission()

        let admissionResult = await admission.value
        let admittedCoverage = try XCTUnwrap(admissionResult)
        XCTAssertEqual(admittedCoverage.after, .origin)
        XCTAssertEqual(admittedCoverage.through.sequence, 1)
        let repeatedAdmission = await action.admitCausallyCovered { Optional($0) }
        XCTAssertNil(repeatedAdmission)
        let events = bus.checkpoint(after: .origin, selection: .all).events
        guard events.count == 2,
              case .action = events[0].owner
        else {
            return XCTFail("Expected cancellation to preserve the sealed action cutoff")
        }
        XCTAssertEqual(events[1].owner, .ambient)
    }

    func testCancellationAfterSealMakesFailedAdmissionTerminal() async throws {
        let bus = AccessibilityNotificationBus()
        let action = bus.beginActionWindow()
        bus.recordForTesting(code: 1001, notificationData: .none, associatedElement: .none)
        let suspension = AdmissionSuspension()

        let admission = Task { @MainActor in
            await action.admitCausallyCovered { _ -> Bool? in
                await suspension.suspendAdmission()
                return nil
            }
        }
        await suspension.waitUntilSuspended()
        action.cancel()
        await suspension.resumeAdmission()

        let failedAdmission = await admission.value
        XCTAssertNil(failedAdmission)
        let repeatedAdmission = await action.admitCausallyCovered { Optional($0) }
        XCTAssertNil(repeatedAdmission)
    }

    func testCallbackImmediatelyNormalizesMutableObjectiveCPayload() async throws {
        let harness = CallbackHarness()
        let observer = makeObserver(harness: harness)
        let bus = AccessibilityNotificationBus()
        observer.attach(bus)
        defer { observer.detach(bus) }
        let callback = try XCTUnwrap(harness.callbacks.first)
        let mutablePayload = NSMutableString(string: "Original announcement")
        let actionWindow = bus.beginActionWindow()

        callback(1008, mutablePayload, nil)
        mutablePayload.setString("Mutated after callback")

        let admittedCoverage = await actionWindow.admitCausallyCovered { Optional($0) }
        let coverage = try XCTUnwrap(admittedCoverage)
        let events = bus.checkpoint(
            after: coverage.after,
            selection: .all
        ).events
        XCTAssertEqual(coverage.through.sequence, 1)
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        guard case .string(let value) = event.notificationData else {
            return XCTFail("Expected normalized string payload")
        }
        XCTAssertEqual(value, "Original announcement")
    }

    private func makeObserver(harness: CallbackHarness) -> AccessibilityNotificationObserver {
        AccessibilityNotificationObserver(
            installCallbackForTesting: { callback in
                harness.install(callback)
            }
        )
    }

    @MainActor
    private final class CallbackHarness {
        private(set) var callbacks: [AccessibilityNotificationCallback] = []

        func install(_ callback: @escaping AccessibilityNotificationCallback) {
            callbacks.append(callback)
        }
    }

    private actor AdmissionSuspension {
        private var admissionContinuation: CheckedContinuation<Void, Never>?
        private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

        func suspendAdmission() async {
            await withCheckedContinuation { continuation in
                precondition(admissionContinuation == nil)
                admissionContinuation = continuation
                let waiters = suspensionWaiters
                suspensionWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        func waitUntilSuspended() async {
            if admissionContinuation != nil { return }
            await withCheckedContinuation { continuation in
                suspensionWaiters.append(continuation)
            }
        }

        func resumeAdmission() {
            admissionContinuation?.resume()
            admissionContinuation = nil
        }
    }
}

#endif
