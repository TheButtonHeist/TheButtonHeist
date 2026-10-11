#if canImport(UIKit)
import ButtonHeistSupport
import UIKit
import XCTest

@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

@MainActor
final class AccessibilityNotificationObserverTests: XCTestCase {
    func testObserverInstallsOneCallbackAcrossDestinationLifetimes() async {
        var installCount = 0
        let observer = AccessibilityNotificationObserver(
            installCallbackForTesting: { installCount += 1 }
        )
        let original = AccessibilityNotificationBus()
        let replacement = AccessibilityNotificationBus()

        observer.attach(original)
        observer.detach(original)
        XCTAssertFalse(observer.hasDestination)
        XCTAssertTrue(observer.isInstalled)

        observer.attach(replacement)
        XCTAssertTrue(observer.hasDestination)
        XCTAssertEqual(installCount, 1)
        XCTAssertTrue(observer.isInstalled)
        observer.detach(replacement)
    }

    func testActionWindowProvidesCoverageAfterItsCursorWithoutDrainingIngress() async throws {
        let bus = AccessibilityNotificationBus()
        bus.recordForTesting(code: 1001, notificationData: .none, associatedElement: .none)

        let action = bus.beginActionWindow()
        XCTAssertEqual(action.cursor.sequence, 1)
        bus.recordForTesting(code: 1005, notificationData: .none, associatedElement: .none)
        bus.recordForTesting(
            code: 1008,
            notificationData: CapturedAccessibilityNotificationPayload("Done" as NSString),
            associatedElement: .none
        )

        let admitted = await action.admitCausallyCovered { coverage in
            XCTAssertEqual(coverage.after.sequence, 1)
            XCTAssertEqual(coverage.through.sequence, 3)
            XCTAssertEqual(coverage.scopedScreenChangedThrough, 0)
            XCTAssertEqual(
                bus.checkpoint(after: .origin, selection: .all).events.map(\.kind),
                [.layoutChanged, .elementUpdate, .announcement]
            )
            return coverage
        }
        let coverage = try XCTUnwrap(admitted)

        XCTAssertEqual(coverage.through.sequence, 3)
        XCTAssertEqual(
            bus.checkpoint(after: .origin, selection: .all).events.map(\.kind),
            [.layoutChanged, .elementUpdate, .announcement]
        )
        let claim = try XCTUnwrap(bus.freezeObservationCycleClaim())
        XCTAssertEqual(claim.batch.events.map(\.sequence), [1, 2, 3])
        XCTAssertTrue(claim.acknowledgeObservationCycle())
        XCTAssertTrue(bus.checkpoint(after: .origin, selection: .all).events.isEmpty)
    }

    func testNotificationStormRetainsScopedEvidenceAndBoundsAmbientOwnership() throws {
        let bus = AccessibilityNotificationBus()
        let action = bus.beginActionWindow()
        let scopedEventCount = 1_024

        for index in 0..<scopedEventCount {
            bus.recordForTesting(
                code: 1008,
                notificationData: CapturedAccessibilityNotificationPayload(
                    "Action announcement \(index)" as NSString
                ),
                associatedElement: .none
            )
        }
        action.cancel()

        for _ in 0..<65 {
            bus.recordForTesting(
                code: 1008,
                notificationData: .none,
                associatedElement: .none
            )
        }

        let retained = bus.checkpoint(after: .origin, selection: .all)
        let scoped = bus.checkpoint(after: .origin)
        XCTAssertEqual(
            retained.gap,
            AccessibilityNotificationGap(
                droppedThroughSequence: UInt64(scopedEventCount + 1)
            )
        )
        XCTAssertEqual(retained.through.sequence, UInt64(scopedEventCount + 65))
        XCTAssertEqual(scoped.events.count, scopedEventCount)
        XCTAssertEqual(
            scoped.events.map(\.sequence),
            Array(UInt64(1)...UInt64(scopedEventCount))
        )
        XCTAssertTrue(scoped.events.allSatisfy { $0.provenance == .scoped })
        XCTAssertNil(scoped.gap)
        XCTAssertEqual(
            retained.events.count(where: { $0.provenance == .ambient }),
            64
        )

        let claim = try XCTUnwrap(bus.freezeObservationCycleClaim())
        XCTAssertEqual(claim.batch.events.count, scopedEventCount + 64)
        XCTAssertEqual(
            claim.batch.events.prefix(scopedEventCount).map(\.sequence),
            Array(UInt64(1)...UInt64(scopedEventCount))
        )
        XCTAssertTrue(claim.acknowledgeObservationCycle())
        XCTAssertTrue(bus.checkpoint(after: .origin, selection: .all).events.isEmpty)
    }

    func testCycleClaimFreezesCutoffBeforeLaterIngress() async throws {
        let bus = AccessibilityNotificationBus()
        bus.recordForTesting(code: 1001, notificationData: .none, associatedElement: .none)

        let first = try XCTUnwrap(bus.freezeObservationCycleClaim())
        bus.recordForTesting(code: 1005, notificationData: .none, associatedElement: .none)

        XCTAssertEqual(first.batch.events.map(\.sequence), [1])
        XCTAssertEqual(first.batch.through.sequence, 1)
        XCTAssertTrue(first.acknowledgeObservationCycle())

        let second = try XCTUnwrap(bus.freezeObservationCycleClaim())
        XCTAssertEqual(second.batch.events.map(\.sequence), [2])
        XCTAssertEqual(second.batch.through.sequence, 2)
    }

    func testFailedCycleCommitLeavesExactClaimUnacknowledgedForRetry() throws {
        let bus = AccessibilityNotificationBus()
        bus.recordForTesting(code: 1001, notificationData: .none, associatedElement: .none)

        let failedCommit = try XCTUnwrap(bus.freezeObservationCycleClaim())
        let retry = try XCTUnwrap(bus.freezeObservationCycleClaim())

        XCTAssertEqual(retry.id, failedCommit.id)
        XCTAssertEqual(retry.batch.events.map(\.sequence), [1])
        XCTAssertEqual(retry.batch.through, failedCommit.batch.through)
        XCTAssertTrue(retry.acknowledgeObservationCycle())
        XCTAssertTrue(bus.checkpoint(after: .origin, selection: .all).events.isEmpty)
    }

    func testSuccessfulCycleCommitAcknowledgesExactClaimOnce() throws {
        let bus = AccessibilityNotificationBus()
        bus.recordForTesting(code: 1001, notificationData: .none, associatedElement: .none)

        let claim = try XCTUnwrap(bus.freezeObservationCycleClaim())

        XCTAssertTrue(claim.acknowledgeObservationCycle())
        XCTAssertFalse(claim.acknowledgeObservationCycle())
        XCTAssertTrue(bus.checkpoint(after: .origin, selection: .all).events.isEmpty)
    }

    func testAmbientOverflowStartsReplacementBaselineInsteadOfNoChange() throws {
        let bus = AccessibilityNotificationBus()
        for _ in 0..<65 {
            bus.recordForTesting(
                code: 1008,
                notificationData: .none,
                associatedElement: .none
            )
        }

        let claim = try XCTUnwrap(bus.freezeObservationCycleClaim())
        XCTAssertEqual(
            claim.batch.gap,
            AccessibilityNotificationGap(droppedThroughSequence: 1)
        )

        var state = TheVault.State()
        _ = try state.commitObservation(
            admission(),
            beginningNewBaseline: false
        ).get()
        state.discardCurrentObservation()

        let newBaseline = claim.batch.beginningNewBaseline
        let replacement = try state.commitObservation(
            admission(notificationBatch: newBaseline),
            beginningNewBaseline: true
        ).get()

        XCTAssertNil(newBaseline.gap)
        XCTAssertTrue(newBaseline.events.isEmpty)
        guard case .elementsChanged = replacement.events.last else {
            return XCTFail("Ambient overflow must publish a replacement, not noChange")
        }
        XCTAssertTrue(claim.acknowledgeObservationCycle())
    }

    func testRawCheckpointReportsOnlyRetentionEvictionAsGap() async {
        let bus = AccessibilityNotificationBus()
        for _ in 0..<65 {
            bus.recordForTesting(code: 1001, notificationData: .none, associatedElement: .none)
        }

        let raw = bus.checkpoint(after: .origin, selection: .all)
        let scoped = bus.checkpoint(after: .origin)

        XCTAssertEqual(raw.gap, AccessibilityNotificationGap(droppedThroughSequence: 1))
        XCTAssertEqual(raw.events.map(\.sequence), Array(UInt64(2)...UInt64(65)))
        XCTAssertNil(scoped.gap)
        XCTAssertTrue(scoped.events.isEmpty)
    }

    func testNotificationCheckpointReportsRetainedHistoryGap() async {
        let bus = AccessibilityNotificationBus()
        let cursor = bus.cursor()
        for index in 0..<65 {
            bus.recordForTesting(
                code: 1008,
                notificationData: CapturedAccessibilityNotificationPayload(
                    "Unrelated announcement \(index)" as NSString
                ),
                associatedElement: .none
            )
        }

        let batch = bus.checkpoint(after: cursor, selection: .all)

        XCTAssertEqual(
            batch.gap,
            AccessibilityNotificationGap(droppedThroughSequence: 1)
        )
        XCTAssertEqual(batch.events.map(\.sequence), Array(UInt64(2)...UInt64(65)))
        XCTAssertEqual(batch.events.map(\.kind), Array(repeating: .announcement, count: 64))
    }

    func testNotificationCheckpointPreservesRetainedPayloadOrderAcrossGap() async {
        let bus = AccessibilityNotificationBus()
        let cursor = bus.cursor()
        for index in 0..<64 {
            bus.recordForTesting(
                code: 1008,
                notificationData: CapturedAccessibilityNotificationPayload(
                    "Unrelated announcement \(index)" as NSString
                ),
                associatedElement: .none
            )
        }
        bus.recordForTesting(
            code: 1008,
            notificationData: CapturedAccessibilityNotificationPayload(
                "Expected announcement" as NSString
            ),
            associatedElement: .none
        )

        let batch = bus.checkpoint(after: cursor, selection: .all)
        let retainedText = batch.events.compactMap { event -> String? in
            guard case .string(let text) = event.notificationData else { return nil }
            return text
        }

        XCTAssertEqual(retainedText.last, "Expected announcement")
        XCTAssertEqual(batch.events.map(\.sequence), Array(UInt64(2)...UInt64(65)))
        XCTAssertEqual(
            batch.gap,
            AccessibilityNotificationGap(droppedThroughSequence: 1)
        )
    }

    func testStoppingSemanticObservationDoesNotClearRetainedIngress() async {
        let vault = TheVault(tripwire: TheTripwire())
        let heist = vault.accessibilityNotifications.beginHeistScope()
        vault.accessibilityNotifications.recordForTesting(
            code: 1001,
            notificationData: .none,
            associatedElement: .none
        )
        heist.cancel()

        vault.semanticObservationStream.stop()

        let batch = vault.accessibilityNotifications.checkpoint(
            after: .origin,
            selection: .all
        )
        XCTAssertEqual(batch.events.map(\.kind), [.layoutChanged])
        XCTAssertEqual(batch.events.map(\.provenance), [.scoped])
        XCTAssertNil(batch.gap)
    }

    func testStringPayloadsFromPublicNotificationsAreCapturedInIngressOrder() async {
        let bus = AccessibilityNotificationBus()

        bus.recordForTesting(
            code: 1008,
            notificationData: CapturedAccessibilityNotificationPayload("Item deleted" as NSString),
            associatedElement: .none
        )
        bus.recordForTesting(
            code: 1001,
            notificationData: CapturedAccessibilityNotificationPayload("3 items selected" as NSString),
            associatedElement: .none
        )
        bus.recordForTesting(
            code: 1000,
            notificationData: CapturedAccessibilityNotificationPayload("Checkout" as NSString),
            associatedElement: .none
        )

        let events = bus.checkpoint(after: .origin, selection: .all).events
        let text = events.compactMap { event -> String? in
            guard case .string(let value) = event.notificationData else { return nil }
            return value
        }
        XCTAssertEqual(text, ["Item deleted", "3 items selected", "Checkout"])
        XCTAssertEqual(
            events.map(\.kind),
            [.announcement, .layoutChanged, .screenChanged]
        )
    }

    func testObserverPublishesOneMonotonicPayloadSequence() async throws {
        var callback: AccessibilityNotificationCallback?
        let observer = AccessibilityNotificationObserver(
            installCallbackForTesting: { callback = $0 }
        )
        let bus = AccessibilityNotificationBus()
        observer.attach(bus)
        defer { observer.detach(bus) }
        let publish = try XCTUnwrap(callback)

        publish(1001, nil, nil)
        publish(1005, "75%" as NSString, nil)
        publish(1008, "Done" as NSString, nil)

        let events = bus.checkpoint(after: .origin, selection: .all).events
        XCTAssertEqual(events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(
            events.map(\.kind),
            [.layoutChanged, .elementUpdate, .announcement]
        )
        XCTAssertEqual(bus.latestSequence, 3)
        guard case .string(let value) = events[1].notificationData else {
            return XCTFail("Expected the captured string payload")
        }
        XCTAssertEqual(value, "75%")
    }

    func testPrivateCallbackFromBackgroundQueuePublishesOnMainInIngressOrder() async throws {
        var callback: ButtonHeistPrivateSPI.AccessibilityNotificationCallbackBlock?
        let observer = AccessibilityNotificationObserver(
            installPrivateCallbackForTesting: { callback = $0 }
        )
        let bus = AccessibilityNotificationBus()
        observer.attach(bus)
        defer { observer.detach(bus) }
        let privateCallback = BackgroundPrivateCallback(
            try XCTUnwrap(callback)
        )
        let callbacksQueued = expectation(description: "private callbacks queued")

        DispatchQueue.global().async {
            privateCallback.invoke(1001, notificationData: nil, associatedElement: nil)
            privateCallback.invoke(
                1008,
                notificationData: "Delivered from background" as NSString,
                associatedElement: nil
            )
            DispatchQueue.main.async {
                callbacksQueued.fulfill()
            }
        }

        await fulfillment(of: [callbacksQueued], timeout: 1)

        let events = bus.checkpoint(after: .origin, selection: .all).events
        XCTAssertEqual(events.map(\.sequence), [1, 2])
        XCTAssertEqual(events.map(\.kind), [.layoutChanged, .announcement])
        guard case .string(let text) = events[1].notificationData else {
            return XCTFail("Expected main-queue normalization of the announcement")
        }
        XCTAssertEqual(text, "Delivered from background")
    }

    func testObserverAppendsAfterInjectedIngress() async throws {
        var callback: AccessibilityNotificationCallback?
        let observer = AccessibilityNotificationObserver(
            installCallbackForTesting: { callback = $0 }
        )
        let bus = AccessibilityNotificationBus()
        observer.attach(bus)
        defer { observer.detach(bus) }
        bus.recordForTesting(code: 1005, notificationData: .none, associatedElement: .none)

        try XCTUnwrap(callback)(1001, nil, nil)

        XCTAssertEqual(
            bus.checkpoint(after: .origin, selection: .all).events.map(\.sequence),
            [1, 2]
        )
        XCTAssertEqual(bus.latestSequence, 2)
    }

    func testProbeObservesOnlyElementUpdateNotifications() throws {
        let payload = CapturedAccessibilityNotificationPayload("Updated" as NSString)

        XCTAssertNil(
            AccessibilityNotificationProbe.description(
                rawCode: 1001,
                notificationData: payload,
                associatedElement: .none
            )
        )
        XCTAssertNotNil(
            AccessibilityNotificationProbe.description(
                rawCode: 1005,
                notificationData: payload,
                associatedElement: .none
            )
        )
    }

    func testProbeDescriptionPreservesBehaviorTokensFromRawPayload() throws {
        let behavior = [
            "ChangeType": 2,
            "IsQuiet": true,
        ] as NSDictionary
        let notificationData = [
            "data": behavior,
            "token": "kAXValueChangeUserInfoKey",
        ] as NSDictionary
        let associatedElement = NSObject()

        let description = try XCTUnwrap(
            AccessibilityNotificationProbe.description(
                rawCode: 1005,
                notificationData: CapturedAccessibilityNotificationPayload(notificationData),
                associatedElement: CapturedAccessibilityNotificationPayload(associatedElement)
            )
        )

        XCTAssertTrue(description.contains("code=1005(elementUpdate)"))
        XCTAssertTrue(description.contains("notificationData.class="))
        XCTAssertTrue(description.contains("kAXValueChangeUserInfoKey"))
        XCTAssertTrue(description.contains("ChangeType"))
        XCTAssertTrue(description.contains("IsQuiet"))
        XCTAssertTrue(description.contains("associatedElement.class="))
    }

    func testUnknownNotificationsPreserveRawCodesAtBoundary() async {
        let bus = AccessibilityNotificationBus()

        bus.recordForTesting(code: 1009, notificationData: .none, associatedElement: .none)
        bus.recordForTesting(code: 4002, notificationData: .none, associatedElement: .none)

        XCTAssertEqual(bus.latestSequence, 2)
        XCTAssertEqual(
            bus.checkpoint(after: .origin, selection: .all).events.map(\.kind),
            [.unknown(1009), .unknown(4002)]
        )
    }

    func testOnlyScopedScreenChangedAdvancesInvalidationCursor() async {
        let bus = AccessibilityNotificationBus()
        XCTAssertEqual(bus.latestScopedScreenChangedSequence, 0)

        bus.recordForTesting(code: 1000, notificationData: .none, associatedElement: .none)
        XCTAssertEqual(bus.latestScopedScreenChangedSequence, 0)

        let actionWindow = bus.beginActionWindow()
        defer { actionWindow.cancel() }
        bus.recordForTesting(code: 1001, notificationData: .none, associatedElement: .none)
        bus.recordForTesting(code: 1008, notificationData: .none, associatedElement: .none)
        bus.recordForTesting(code: 4002, notificationData: .none, associatedElement: .none)
        XCTAssertEqual(bus.latestScopedScreenChangedSequence, 0)

        bus.recordForTesting(code: 1000, notificationData: .none, associatedElement: .none)
        XCTAssertEqual(bus.latestScopedScreenChangedSequence, 5)
    }

    func testNotificationBusOwnsMonotonicSequence() async {
        let bus = AccessibilityNotificationBus()
        bus.recordForTesting(code: 1005, notificationData: .none, associatedElement: .none)
        bus.recordForTesting(code: 1001, notificationData: .none, associatedElement: .none)

        XCTAssertEqual(
            bus.checkpoint(after: .origin, selection: .all).events.map(\.sequence),
            [1, 2]
        )
        XCTAssertEqual(bus.latestSequence, 2)
    }

    func testCheckpointIncludesScopedEventsAndExcludesAmbientEvents() {
        let bus = AccessibilityNotificationBus()
        bus.recordForTesting(code: 1000, notificationData: .none, associatedElement: .none)
        let heist = bus.beginHeistScope()
        defer { heist.cancel() }
        bus.recordForTesting(code: 1001, notificationData: .none, associatedElement: .none)
        let batch = bus.checkpoint(after: heist.cursor)
        bus.recordForTesting(code: 1000, notificationData: .none, associatedElement: .none)

        XCTAssertEqual(batch.events.map(\.sequence), [2])
        XCTAssertEqual(batch.events.map(\.provenance), [.scoped])
        XCTAssertEqual(batch.through.sequence, 2)
    }

    private func admission(
        notificationBatch: AccessibilityNotificationBatch = AccessibilityNotificationBatch(
            events: [],
            through: .origin,
            scopedScreenChangedThrough: 0,
            gap: nil
        )
    ) -> Observation.Admission {
        let observation = InterfaceObservation.empty
        return Observation.Admission(
            sourceObservation: observation,
            tripwireSignal: .empty,
            discoveryCommitPolicy: .mergeIntoInterface,
            lineage: .resting,
            scope: .visible,
            notifications: Observation.NotificationSnapshot(
                admittedNotifications: [],
                through: notificationBatch.through,
                scopedScreenChangedThrough: notificationBatch.scopedScreenChangedThrough,
                gap: notificationBatch.gap
            )!,
            keyboardVisible: nil,
            timestamp: Date(timeIntervalSince1970: 0),
            viewportFrames: observation.tree.viewportFrames,
            geometryTolerance: CoarseFrameComparison.currentGeometryTolerance
        )
    }

    /// The C block is deliberately invoked from a foreign queue in this test,
    /// matching the private UIAccessibility callback boundary.
    private final class BackgroundPrivateCallback: @unchecked Sendable {
        private let callback: ButtonHeistPrivateSPI.AccessibilityNotificationCallbackBlock

        init(_ callback: @escaping ButtonHeistPrivateSPI.AccessibilityNotificationCallbackBlock) {
            self.callback = callback
        }

        func invoke(
            _ code: UInt32,
            notificationData: AnyObject?,
            associatedElement: AnyObject?
        ) {
            callback(code, notificationData, associatedElement)
        }
    }
}

/// Which screen changes invalidate settled observation history.
///
/// A settled observation describes the screen it was taken on, so a screen
/// change after it means the observation describes a screen we are no longer
/// looking at. Scope is what decides whether a given change says that: one
/// recorded inside an action's attribution window belongs to the command and
/// counts, one recorded outside it is the host app talking to itself and does
/// not.
@MainActor
final class ScreenChangeObservationAdmissionTests: XCTestCase {

    private var visibleObservationSource = VisibleObservationSourceFixture(observation: .empty)
    private var brains: TheBrains!

    override func setUp() async throws {
        try await super.setUp()
        brains = TheBrains(
            tripwire: TheTripwire(),
            visibleObservationSource: visibleObservationSource.capture
        )
    }

    override func tearDown() async throws {
        brains.vault.semanticObservationStream.stop()
        brains = nil
        try await super.tearDown()
    }

    func testScreenChangedInsideCommandScopeDiscardsCommittedObservation() async {
        await commitOverview()

        let actionWindow = brains.vault.accessibilityNotifications.beginActionWindow()
        defer { actionWindow.cancel() }
        recordScreenChanged()
        brains.vault.semanticObservationStream.discardIfScreenChangedSinceRead()

        XCTAssertNil(brains.vault.state.current)
    }

    func testScreenChangedOutsideCommandScopePreservesCommittedObservation() async {
        await commitOverview()

        recordScreenChanged()
        let actionWindow = brains.vault.accessibilityNotifications.beginActionWindow()
        defer { actionWindow.cancel() }
        brains.vault.semanticObservationStream.discardIfScreenChangedSinceRead()

        XCTAssertNotNil(brains.vault.state.current)
    }

    func testAdmissionReadPreservesBaselineDepartureEvidenceForReplacementCapture() async throws {
        let baseline = await commitOverview()
        let actionWindow = brains.vault.accessibilityNotifications.beginActionWindow()
        defer { actionWindow.cancel() }
        recordScreenChanged()

        XCTAssertNil(brains.vault.semanticObservationStream.admittedObservation(
            scope: .visible,
            after: nil
        ))

        let replacement = await brains.vault.semanticObservationStream
            .commitVisibleObservationForTesting(
                InterfaceObservation.makeForTests([
                    InterfaceObservation.TestEntry(
                        AccessibilityElement.make(label: "Checkout", traits: .header),
                        heistId: "checkout_header"
                    )
                ])
            )

        guard case .elementsChanged(let departure) = replacement.events[0],
              case .screenChanged = replacement.events[1],
              case .elementsChanged(let arrival) = replacement.events[2]
        else {
            return XCTFail("Expected baseline departure, screen boundary, and replacement capture")
        }
        XCTAssertTrue(departure.interface.tree.isEmpty)
        XCTAssertEqual(
            departure.interface.timestamp,
            baseline.current.snapshot.interface.timestamp
        )
        XCTAssertEqual(departure.context, baseline.current.snapshot.context)
        XCTAssertEqual(arrival, replacement.current.snapshot)
    }

    @discardableResult
    private func commitOverview() async -> Observation.Publication {
        await brains.vault.semanticObservationStream.commitVisibleObservationForTesting(
            InterfaceObservation.makeForTests([
                InterfaceObservation.TestEntry(
                    AccessibilityElement.make(label: "Overview", traits: .header),
                    heistId: "overview_header"
                )
            ])
        )
    }

    private func recordScreenChanged() {
        brains.vault.accessibilityNotifications.recordForTesting(
            code: 1000,
            notificationData: .none,
            associatedElement: .none
        )
    }

}

#endif
