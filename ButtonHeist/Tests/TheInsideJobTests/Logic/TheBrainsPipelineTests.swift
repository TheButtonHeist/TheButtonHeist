#if canImport(UIKit)
import Foundation
import XCTest
import ThePlans
import UIKit
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@testable import TheScore

/// Deterministic tests for post-action observation and exploration behavior
/// that operate purely against the current `InterfaceObservation` snapshot: failure result
/// assembly, wait-change guards, and semantic discovery observation.
///
/// Success-path post-action observation and `exploreScreen` container iteration
/// require a live window and are covered by integration/benchmark runs.
@MainActor
final class TheBrainsPipelineTests: XCTestCase {
    var brains: TheBrains!

    override func setUp() async throws {
        try await super.setUp()
        brains = TheBrains(tripwire: TheTripwire())
    }

    override func tearDown() async throws {
        brains.vault.semanticObservationStream.stop()
        brains = nil
        try await super.tearDown()
    }

    func testObservationScopeDerivesFromCompiledProgramTargets() throws {
        let visible = try AccessibilityPredicate.elementsChanged([
            .appeared(.label("Ready")),
        ]).resolve(in: .empty)
        let discovery = try AccessibilityPredicate.elementsChanged([
            .appeared(.container(.identifier("OffscreenGroup"))),
        ]).resolve(in: .empty)
        let notification = try AccessibilityPredicate.notification.resolve(in: .empty)

        XCTAssertEqual(visible.observationScope, .visible)
        XCTAssertEqual(discovery.observationScope, .discovery)
        XCTAssertEqual(notification.observationScope, .visible)
    }

    // MARK: - Semantic Discovery Observation

    func testExplorationTerminalResolutionSupportsContainerTargets() async throws {
        let observation = makeDiscoveryObservationProjectionFixture()
        let visibleRoot = try AccessibilityTarget.container(.identifier("RootViewController")).resolve(in: .empty)
        let offscreenGroup = try AccessibilityTarget.container(.identifier("OffscreenGroup")).resolve(in: .empty)
        let missing = try AccessibilityTarget.container(.identifier("Missing")).resolve(in: .empty)

        XCTAssertTrue(brains.vault.hasVisibleTerminalResolution(visibleRoot, in: observation.tree))
        XCTAssertFalse(brains.vault.hasVisibleTerminalResolution(offscreenGroup, in: observation.tree))
        XCTAssertFalse(brains.vault.hasVisibleTerminalResolution(missing, in: observation.tree))
    }

    func testSemanticExplorationAddsNestedContainersAfterOuterContainerIsExplored() async {
        let outer = makeScrollableContainer(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400),
            contentSize: CGSize(width: 320, height: 1_200)
        )
        let nested = makeScrollableContainer(
            frame: CGRect(x: 20, y: 520, width: 280, height: 240),
            contentSize: CGSize(width: 280, height: 900)
        )
        let outerPath = TreePath([0])
        let nestedPath = TreePath([0, 0])
        let outerEntry = semanticContainer(outer, path: outerPath)
        let nestedEntry = semanticContainer(nested, path: nestedPath)
        var exploration = Navigation.SemanticExploration(startingFresh: false)
        exploration.progress.addPendingContainers([outerEntry])

        exploration.markExplored(outerEntry)
        exploration.addDiscoveredContainers([outerEntry, nestedEntry])

        XCTAssertTrue(exploration.progress.exploredScrollPaths.contains(outerPath))
        XCTAssertFalse(exploration.progress.pendingScrollPaths.contains(outerPath))
        XCTAssertTrue(exploration.progress.pendingScrollPaths.contains(nestedPath))
    }

    func testSemanticExplorationAbsorbQueuesScrollContainersFromParsedPage() async {
        let outer = makeScrollableContainer(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400),
            contentSize: CGSize(width: 320, height: 1_200)
        )
        let nested = makeScrollableContainer(
            frame: CGRect(x: 20, y: 180, width: 280, height: 240),
            contentSize: CGSize(width: 280, height: 900)
        )
        let outerPath = TreePath([0])
        let nestedPath = TreePath([0, 0])
        let page = InterfaceObservation.makeForTests(
            elements: [:],
            hierarchy: [
                .container(outer, children: [
                    .container(nested, children: [])
                ])
            ],
            containerScrollMembershipsByPath: [
                nestedPath: .init(containerPath: outerPath, index: nil)
            ],
            containerViewSpacesByPath: [
                nestedPath: viewSpace(for: nested, ownerPath: outerPath)
            ],
            firstResponderHeistId: nil,
        )
        var exploration = Navigation.SemanticExploration(startingFresh: false)

        exploration.recordCommittedObservation(
            continuity: .sameGeneration,
            scrollableContainers: page.tree.orderedContainers.filter { $0.container.isScrollable }
        )

        XCTAssertTrue(exploration.progress.pendingScrollPaths.contains(outerPath))
        XCTAssertTrue(exploration.progress.pendingScrollPaths.contains(nestedPath))
    }

    func testSemanticExplorationAbsorbQueuesNestedContainerWithoutRequeuingExploredOuter() async {
        let outer = makeScrollableContainer(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400),
            contentSize: CGSize(width: 320, height: 1_200)
        )
        let nested = makeScrollableContainer(
            frame: CGRect(x: 20, y: 520, width: 280, height: 240),
            contentSize: CGSize(width: 280, height: 900)
        )
        let outerPath = TreePath([0])
        let nestedPath = TreePath([0, 0])
        let page = InterfaceObservation.makeForTests(
            elements: [:],
            hierarchy: [
                .container(outer, children: [
                    .container(nested, children: [])
                ])
            ],
            containerScrollMembershipsByPath: [
                nestedPath: .init(containerPath: outerPath, index: nil)
            ],
            containerViewSpacesByPath: [
                nestedPath: viewSpace(for: nested, ownerPath: outerPath)
            ],
            firstResponderHeistId: nil,
        )
        let outerEntry = semanticContainer(outer, path: outerPath)
        var exploration = Navigation.SemanticExploration(startingFresh: false)
        exploration.progress.addPendingContainers([outerEntry])
        exploration.markExplored(outerEntry)

        exploration.recordCommittedObservation(
            continuity: .sameGeneration,
            scrollableContainers: page.tree.orderedContainers.filter { $0.container.isScrollable }
        )

        XCTAssertTrue(exploration.progress.exploredScrollPaths.contains(outerPath))
        XCTAssertFalse(exploration.progress.pendingScrollPaths.contains(outerPath))
        XCTAssertTrue(exploration.progress.pendingScrollPaths.contains(nestedPath))
    }

    func testSemanticExplorationFinishOwnsExplorationTimestamp() async {
        var exploration = Navigation.SemanticExploration(startingFresh: false)
        let current = await brains.vault.semanticObservationStream
            .commitDiscoveryObservationForTesting(.empty)
            .current

        let startTime = CACurrentMediaTime() - 1
        let result = exploration.finish(
            startTime: startTime,
            current: current,
            didMoveViewport: false,
            viewportExit: .restored
        )
        let finishTime = CACurrentMediaTime()

        XCTAssertGreaterThanOrEqual(result.progress.explorationTime, 1)
        XCTAssertLessThanOrEqual(result.progress.explorationTime, finishTime - startTime)
        XCTAssertFalse(result.didMoveViewport)
        XCTAssertEqual(result.current, current)
    }

    func testSemanticOnlyScrollableContainerIsQueuedForSwipeExploration() async {
        let path = TreePath([0])
        let container = semanticContainer(
            makeScrollableContainer(
                frame: CGRect(x: 0, y: 0, width: 320, height: 400),
                contentSize: CGSize(width: 320, height: 1_200)
            ),
            path: path
        )
        var exploration = Navigation.SemanticExploration(startingFresh: false)

        exploration.recordCommittedObservation(
            continuity: .sameGeneration,
            scrollableContainers: [container]
        )

        XCTAssertNil(brains.vault.liveScrollableContainerView(forPath: path))
        XCTAssertTrue(exploration.progress.pendingScrollPaths.contains(path))
    }

    // MARK: - Helpers

    func makeDiscoveryObservationProjectionFixture() -> InterfaceObservation {
        let rootPath = TreePath([0])
        let visiblePath = TreePath([0, 0])
        let offscreenContainerPath = TreePath([0, 2])
        let rootContainer = AccessibilityContainer(
            type: .none,
            identifier: "RootViewController",
            scrollableContentSize: AccessibilitySize(width: 320, height: 720),
            frame: AccessibilityRect(CGRect(x: 0, y: 0, width: 320, height: 480))
        )
        let offscreenContainer = AccessibilityContainer(
            type: .semanticGroup(label: "OffscreenGroup", value: nil),
            identifier: "OffscreenGroup",
            frame: AccessibilityRect(CGRect(x: 0, y: 480, width: 320, height: 240))
        )
        let visible = AccessibilityElement.make(
            label: "Visible",
            traits: .button,
            respondsToUserInteraction: false
        )
        let offscreen = AccessibilityElement.make(
            label: "Offscreen",
            traits: .button,
            respondsToUserInteraction: false
        )
        let tree = InterfaceTree(
                elements: [
                    "visible_button": InterfaceTree.Element(
                        heistId: "visible_button",
                        path: visiblePath,
                        scrollMembership: InterfaceTree.ScrollMembership(
                            containerPath: rootPath,
                            index: 0
                        ),
                        geometry: testGeometry(
                            for: visible,
                            ownerPath: rootPath,
                            screen: TheVault.onscreenSpace(for: visible)
                        ),
                        element: visible
                    ),
                    "offscreen_button": InterfaceTree.Element(
                        heistId: "offscreen_button",
                        path: TreePath([0, 2, 0]),
                        scrollMembership: InterfaceTree.ScrollMembership(
                            containerPath: rootPath,
                            index: 2
                        ),
                        geometry: testGeometry(
                            for: offscreen,
                            ownerPath: rootPath,
                            screen: .offscreen
                        ),
                        element: offscreen
                    ),
                ],
                containers: [
                    rootPath: InterfaceTree.Container(
                        container: rootContainer,
                        path: rootPath,
                        containerName: "root",
                        viewSpace: viewSpace(for: rootContainer, ownerPath: .root)
                    ),
                    offscreenContainerPath: InterfaceTree.Container(
                        container: offscreenContainer,
                        path: offscreenContainerPath,
                        containerName: "offscreen_group",
                        viewSpace: viewSpace(for: offscreenContainer, ownerPath: rootPath),
                        scrollMembership: InterfaceTree.ScrollMembership(
                            containerPath: rootPath,
                            index: 1
                        )
                    ),
                ],
            viewportCapture: .init(
                hierarchy: [
                    .container(rootContainer, children: [
                        .element(visible, traversalIndex: 0),
                    ]),
                ],
                heistIdsByPath: [visiblePath: "visible_button"]
            )
        )
        let viewportObservation = InterfaceObservation.makeForTests(
            tree: tree,
            liveCapture: LiveCapture.makeForTests(tree: tree)
        )
        return viewportObservation
    }

    func notificationBatch(
        kind: AccessibilityNotificationKind,
        gap: AccessibilityNotificationGap? = nil
    ) -> AccessibilityNotificationBatch {
        let sequence = (gap?.droppedThroughSequence ?? 0) + 1
        return AccessibilityNotificationBatch(
            events: [PendingAccessibilityNotificationEvent(
                sequence: sequence,
                kind: kind,
                timestamp: Date(timeIntervalSince1970: 0),
                notificationData: .none,
                associatedElement: .none,
                provenance: .scoped
            )],
            through: AccessibilityNotificationCursor(sequence: sequence),
            scopedScreenChangedThrough: kind == .screenChanged ? sequence : 0,
            gap: gap
        )
    }

    func makeScreen(elements: [(label: String, traits: UIAccessibilityTraits, heistId: HeistId)]) -> InterfaceObservation {
        let pairs: [(AccessibilityElement, HeistId)] = elements.map { entry in
            let element = AccessibilityElement.make(
                label: entry.label,
                traits: entry.traits,
                respondsToUserInteraction: false
            )
            return (element, entry.heistId)
        }
        return .makeForTests(elements: pairs)
    }

    func makeScrollableContainer(frame: CGRect, contentSize: CGSize) -> AccessibilityContainer {
        AccessibilityContainer(
            type: .none, scrollableContentSize: AccessibilitySize(contentSize),
            frame: AccessibilityRect(frame)
        )
    }

    func semanticContainer(
        _ container: AccessibilityContainer,
        path: TreePath
    ) -> InterfaceTree.Container {
        InterfaceTree.Container(
            container: container,
            path: path,
            containerName: nil,
            viewSpace: viewSpace(for: container, ownerPath: path.parent ?? .root)
        )
    }

    private func viewSpace(
        for container: AccessibilityContainer,
        ownerPath: TreePath
    ) -> HeistElement.Geometry.ViewSpace {
        let frame = container.frame.cgRect
        return .admit(
            ownerPath: ownerPath,
            frame: try? ViewRect(validating: frame),
            activationPoint: try? ViewPoint(validating: CGPoint(
                x: frame.midX,
                y: frame.midY
            ))
        )
    }
}

#endif
