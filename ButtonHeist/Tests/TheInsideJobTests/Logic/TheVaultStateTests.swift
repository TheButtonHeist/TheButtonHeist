#if canImport(UIKit)
#if DEBUG
import Foundation
import ButtonHeistTestSupport
import XCTest

@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@testable import ThePlans
@testable import TheScore

@MainActor
final class TheVaultStateTests: XCTestCase {
    func testHistoryOwnsOrder() throws {
        var history = Observation.History(retentionLimit: 4)
        let events: [Observation.Event] = [
            .noChange,
            .screenChanged(ScreenFacts(idAfter: "Checkout")),
            .elementsChanged(snapshot()),
        ]

        let recorded = history.record(events, protectedBy: nil)

        XCTAssertEqual(recorded, 0..<3)
        XCTAssertEqual(Array(history), events)
    }

    func testPruningRetainsNewestEvents() {
        var history = Observation.History(retentionLimit: 2)
        _ = history.record([
            .screenChanged(ScreenFacts(idAfter: "Checkout")),
            .noChange,
            .noChange,
        ], protectedBy: nil)

        XCTAssertEqual(history.startIndex, 1)
        XCTAssertEqual(Array(history), [.noChange, .noChange])
    }

    func testProtectedBoundaryPreventsEvictionUntilReleased() throws {
        var state = TheVault.State(retentionLimit: 2)
        _ = commit(&state, admission())
        let boundary = state.history.endIndex
        state.protectHistory(from: boundary)

        _ = commit(&state, admission())
        _ = commit(&state, admission())
        _ = commit(&state, admission())

        XCTAssertEqual(state.history.startIndex, boundary)
        XCTAssertEqual(
            Array(try state.history.events(after: boundary)),
            [.noChange, .noChange, .noChange]
        )

        state.releaseHistory(from: boundary)

        XCTAssertEqual(state.history.count, 2)
        XCTAssertThrowsError(try state.history.events(after: boundary)) { error in
            XCTAssertEqual(error as? Observation.History.ReadError, .rangeUnavailable)
        }
    }

    func testAdvancingProtectedBoundaryReleasesCompletedLeafHistory() throws {
        var state = TheVault.State(retentionLimit: 2)
        _ = commit(&state, admission())
        let firstBoundary = state.history.endIndex
        state.protectHistory(from: firstBoundary)

        _ = commit(&state, admission())
        _ = commit(&state, admission())
        let nextBoundary = state.history.endIndex
        state.advanceHistoryProtection(from: firstBoundary, to: nextBoundary)
        _ = commit(&state, admission())

        XCTAssertEqual(state.history.count, 2)
        XCTAssertThrowsError(
            try state.history.events(after: firstBoundary)
        ) { error in
            XCTAssertEqual(
                error as? Observation.History.ReadError,
                .rangeUnavailable
            )
        }
        XCTAssertEqual(
            Array(try state.history.events(after: nextBoundary)),
            [.noChange]
        )
    }

    func testEvictedRangeProducesIncompleteEvidence() {
        var history = Observation.History(retentionLimit: 1)
        _ = history.record([.noChange], protectedBy: nil)
        _ = history.record([.noChange], protectedBy: nil)

        let evidence = history.evidence(
            in: 0..<history.endIndex,
            baseline: snapshot(),
            current: snapshot()
        )

        XCTAssertEqual(evidence.coverage, .incomplete(.historyUnavailable))
        XCTAssertTrue(evidence.events.isEmpty)
    }

    func testIncompleteNotificationBatchCannotConstructAnAdmissionSnapshot() {
        XCTAssertNil(
            Observation.NotificationSnapshot(
                admittedNotifications: [],
                through: AccessibilityNotificationCursor(sequence: 7),
                scopedScreenChangedThrough: 0,
                gap: AccessibilityNotificationGap(droppedThroughSequence: 7)
            )
        )
    }

    func testEqualSettledStateRecordsNoChange() {
        var state = TheVault.State()
        let first = commit(&state, admission())
        let second = commit(&state, admission())

        guard case .elementsChanged(let initial) = first.events.last else {
            return XCTFail("The first parse must establish element truth")
        }
        XCTAssertEqual(initial, first.current.snapshot)
        XCTAssertEqual(second.events, [.noChange])
        XCTAssertEqual(Array(state.history), first.events + second.events)
        XCTAssertEqual(state.current, second.current)
    }

    func testReplacementPublishesNotificationDepartureBoundaryAndArrivalInOrder() throws {
        var state = TheVault.State()
        let baseline = commit(&state, admission(
            keyboardVisible: true,
            timestamp: Date(timeIntervalSince1970: 1)
        ))
        let boundary = state.history.endIndex
        let replacement = commit(&state, admission(
            notifications: [
                Observation.AdmittedNotification(
                    sequence: 1,
                    kind: .announcement,
                    text: "Opening checkout",
                    element: nil
                ),
                Observation.AdmittedNotification(
                    sequence: 2,
                    kind: .screenChanged,
                    text: nil,
                    element: nil
                ),
            ],
            keyboardVisible: false,
            timestamp: Date(timeIntervalSince1970: 2)
        ))

        XCTAssertEqual(replacement.events.count, 4)
        guard case .notification(let notification) = replacement.events[0],
              case .elementsChanged(let departure) = replacement.events[1],
              case .screenChanged = replacement.events[2],
              case .elementsChanged(let arrival) = replacement.events[3]
        else {
            return XCTFail("Expected notification, departure, screen boundary, and arrival")
        }
        XCTAssertEqual(notification.text, "Opening checkout")
        XCTAssertTrue(departure.interface.tree.isEmpty)
        XCTAssertEqual(
            departure.interface.timestamp,
            baseline.current.snapshot.interface.timestamp
        )
        XCTAssertEqual(departure.context, baseline.current.snapshot.context)
        XCTAssertNotEqual(departure.context, arrival.context)
        XCTAssertEqual(arrival, replacement.current.snapshot)
        XCTAssertEqual(
            Array(try state.history.events(after: boundary)),
            replacement.events
        )
    }

    func testNotificationPrecedesForcedElementChange() throws {
        var state = TheVault.State()
        _ = commit(&state, admission())
        let notification = Observation.AdmittedNotification(
            sequence: 1,
            kind: .layoutChanged,
            text: "Updated",
            element: nil
        )

        let publication = commit(&state, admission(notifications: [notification]))

        XCTAssertEqual(
            publication.events.first,
            .notification(try XCTUnwrap(Observation.Notification(
                text: "Updated",
                element: nil
            )))
        )
        guard case .elementsChanged(let snapshot) = publication.events.last else {
            return XCTFail("Layout notification must force an element-change event")
        }
        XCTAssertEqual(snapshot, publication.current.snapshot)
    }

    func testLayoutChangeInvalidatesRetainedParentSpaceGeometry() throws {
        let scrollPath = TreePath([0])
        let anchorId: HeistId = "visible_anchor"
        let targetId: HeistId = "retained_target"
        let frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        let container = AccessibilityContainer(
            type: .none,
            scrollableContentSize: AccessibilitySize(CGSize(width: 320, height: 1_600)),
            frame: AccessibilityRect(frame)
        )
        let anchor = AccessibilityElement.make(label: "Visible Anchor")
        let targetElement = AccessibilityElement.make(label: "Retained Target", traits: .button)
        let target = InterfaceTree.Element(
            heistId: targetId,
            path: scrollPath.appending(1),
            scrollMembership: .init(containerPath: scrollPath, index: nil),
            geometry: HeistElement.Geometry(
                screen: .offscreen,
                view: .available(.init(
                    ownerPath: scrollPath,
                    frame: try ViewRect(validating: CGRect(x: 20, y: 900, width: 200, height: 44)),
                    activationPoint: try ViewPoint(validating: CGPoint(x: 120, y: 922))
                ))
            ),
            element: targetElement
        )
        let baseline = InterfaceObservation.makeForTests(
            elements: [targetId: target],
            hierarchy: [
                .container(container, children: [
                    .element(anchor, traversalIndex: 0),
                ]),
            ],
            heistIdsByPath: [scrollPath.appending(0): anchorId],
            firstResponderHeistId: nil
        )
        let refreshed = InterfaceObservation.makeForTests(
            elements: [:],
            hierarchy: [
                .container(container, children: [
                    .element(anchor, traversalIndex: 0),
                ]),
            ],
            heistIdsByPath: [scrollPath.appending(0): anchorId],
            firstResponderHeistId: nil
        )
        let fixture = ParentGeometryTransitionFixture(
            scrollPath: scrollPath,
            anchorId: anchorId,
            targetId: targetId,
            container: container,
            anchor: anchor,
            targetElement: targetElement,
            refreshed: refreshed
        )
        var state = TheVault.State()
        _ = requireCommitted(state.commitObservation(
            admission(observation: baseline),
            beginningNewBaseline: false
        ))
        let layoutChange = Observation.AdmittedNotification(
            sequence: 1,
            kind: .layoutChanged,
            text: nil,
            element: nil
        )

        _ = requireCommitted(state.commitObservation(
            admission(notifications: [layoutChange], observation: refreshed),
            beginningNewBaseline: false
        ))

        let retained = try XCTUnwrap(state.interfaceTree.findElement(heistId: targetId))
        XCTAssertEqual(retained.geometry.view, .invalidated(ownerPath: scrollPath))
        XCTAssertEqual(retained.geometry.screen, .offscreen)
        guard case .available? = state.interfaceTree.containers[scrollPath]?.viewSpace else {
            return XCTFail("Fresh container geometry must remain a complete available value")
        }

        let settled = requireCommitted(state.commitObservation(
            admission(observation: refreshed),
            beginningNewBaseline: false
        ))
        XCTAssertEqual(settled.events, [.noChange])
        try assertParentGeometryRecoveryAndRepeatedInvalidation(
            in: &state,
            fixture: fixture
        )
    }

    func testCurrentAfterBoundaryUsesHistoryAvailability() {
        var state = TheVault.State(retentionLimit: 1)
        _ = commit(&state, admission())
        let boundary = state.history.endIndex

        XCTAssertEqual(
            try state.current(after: boundary, scope: .visible).get(),
            nil
        )

        let current = commit(&state, admission()).current

        XCTAssertEqual(
            try state.current(after: boundary, scope: .visible).get(),
            current
        )
    }

    func testRejectedLiveCaptureReattachmentLeavesCommittedStateUntouched() {
        var state = TheVault.State()
        let retained = InterfaceObservation.makeForTests(
            elements: [(AccessibilityElement.make(label: "Retained"), "retained")]
        )
        let initial = requireCommitted(
            state.commitObservation(
                admission(observation: retained),
                beginningNewBaseline: false
            )
        )
        let priorHistoryEnd = state.history.endIndex
        let priorNotificationIndex = state.notificationIndex
        let priorCurrent = state.current
        let priorObservation = state.interfaceObservation
        let replacement = InterfaceObservation.makeForTests(
            elements: [(AccessibilityElement.make(label: "Replacement"), "replacement")]
        )

        XCTAssertThrowsError(try retained.replacingTreeWithCurrentCapture(replacement.tree))
        XCTAssertEqual(state.history.endIndex, priorHistoryEnd)
        XCTAssertEqual(state.notificationIndex, priorNotificationIndex)
        XCTAssertEqual(state.current, priorCurrent)
        XCTAssertEqual(state.interfaceObservation?.tree, priorObservation?.tree)
        XCTAssertEqual(initial.current, priorCurrent)
    }

    private struct ParentGeometryTransitionFixture {
        let scrollPath: TreePath
        let anchorId: HeistId
        let targetId: HeistId
        let container: AccessibilityContainer
        let anchor: AccessibilityElement
        let targetElement: AccessibilityElement
        let refreshed: InterfaceObservation
    }

    private func assertParentGeometryRecoveryAndRepeatedInvalidation(
        in state: inout TheVault.State,
        fixture: ParentGeometryTransitionFixture
    ) throws {
        let restoredFrame = try ViewRect(
            validating: CGRect(x: 24, y: 880, width: 220, height: 48)
        )
        let restoredPoint = try ViewPoint(validating: CGPoint(x: 134, y: 904))
        let restoredTarget = InterfaceTree.Element(
            heistId: fixture.targetId,
            path: fixture.scrollPath.appending(1),
            scrollMembership: .init(containerPath: fixture.scrollPath, index: nil),
            geometry: HeistElement.Geometry(
                screen: .offscreen,
                view: .available(.init(
                    ownerPath: fixture.scrollPath,
                    frame: restoredFrame,
                    activationPoint: restoredPoint
                ))
            ),
            element: fixture.targetElement
        )
        let restored = InterfaceObservation.makeForTests(
            elements: [fixture.targetId: restoredTarget],
            hierarchy: [
                .container(fixture.container, children: [
                    .element(fixture.anchor, traversalIndex: 0),
                    .element(fixture.targetElement, traversalIndex: 1),
                ]),
            ],
            heistIdsByPath: [
                fixture.scrollPath.appending(0): fixture.anchorId,
                fixture.scrollPath.appending(1): fixture.targetId,
            ],
            firstResponderHeistId: nil
        )

        _ = requireCommitted(state.commitObservation(
            admission(observation: restored),
            beginningNewBaseline: false
        ))

        XCTAssertEqual(
            state.interfaceTree.findElement(heistId: fixture.targetId)?.geometry.view,
            .available(.init(
                ownerPath: fixture.scrollPath,
                frame: restoredFrame,
                activationPoint: restoredPoint
            ))
        )
        XCTAssertEqual(
            state.interfaceTree.findElement(heistId: fixture.targetId)?.geometry.screen,
            .offscreen
        )

        let repeatedLayoutChange = Observation.AdmittedNotification(
            sequence: 2,
            kind: .layoutChanged,
            text: nil,
            element: nil
        )
        _ = requireCommitted(state.commitObservation(
            admission(notifications: [repeatedLayoutChange], observation: fixture.refreshed),
            beginningNewBaseline: false
        ))

        XCTAssertEqual(
            state.interfaceTree.findElement(heistId: fixture.targetId)?.geometry.view,
            .invalidated(ownerPath: fixture.scrollPath)
        )
        XCTAssertEqual(
            state.interfaceTree.findElement(heistId: fixture.targetId)?.geometry.screen,
            .offscreen
        )
    }

    private func admission(
        scope: SemanticObservationScope = .visible,
        notifications: [Observation.AdmittedNotification] = [],
        keyboardVisible: Bool? = nil,
        timestamp: Date = Date(timeIntervalSince1970: 0),
        observation: InterfaceObservation = .empty
    ) -> Observation.Admission {
        let through = notifications.map(\.sequence).max() ?? 0
        return Observation.Admission(
            sourceObservation: observation,
            tripwireSignal: .empty,
            discoveryCommitPolicy: .mergeIntoInterface,
            lineage: .resting,
            scope: scope,
            notifications: Observation.NotificationSnapshot(
                admittedNotifications: notifications,
                through: AccessibilityNotificationCursor(sequence: through),
                scopedScreenChangedThrough: 0
            )!,
            keyboardVisible: keyboardVisible,
            timestamp: timestamp,
            viewportFrames: observation.tree.viewportFrames,
            geometryTolerance: CoarseFrameComparison.currentGeometryTolerance
        )
    }

    private func commit(
        _ state: inout TheVault.State,
        _ admission: Observation.Admission
    ) -> Observation.Publication {
        requireCommitted(state.commitObservation(
            admission,
            beginningNewBaseline: false
        ))
    }

    private func requireCommitted(
        _ result: Result<Observation.Publication, Observation.CaptureFailure>
    ) -> Observation.Publication {
        switch result {
        case .success(let publication):
            publication
        case .failure(let failure):
            preconditionFailure("Test observation was rejected: \(failure.diagnostic)")
        }
    }

    private func snapshot() -> Observation.Snapshot {
        Observation.Snapshot(
            interface: makeTestInterface(elements: [], timestamp: Date(timeIntervalSince1970: 0)),
            context: .empty
        )
    }
}
#endif // DEBUG
#endif // canImport(UIKit)
