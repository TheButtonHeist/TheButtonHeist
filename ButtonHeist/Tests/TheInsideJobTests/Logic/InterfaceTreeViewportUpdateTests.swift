#if canImport(UIKit)
import XCTest
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@testable import TheScore

extension InterfaceTreeTests {
    func testFreshViewportRemovesOnlyConfirmedMissingDiscoveryMemory() {
        let anchor = makeElement(label: "Anchor", traits: .staticText)
        let old = InterfaceObservation.makeForTests(
            elements: [(anchor, "anchor")],
            offViewport: [
                .init(makeElement(label: "Removed", traits: .button), heistId: "removed"),
                .init(makeElement(label: "Unvisited", traits: .button), heistId: "unvisited"),
            ]
        ).tree
        let fresh = InterfaceObservation.makeForTests(elements: [(anchor, "anchor")]).tree

        XCTAssertEqual(
            old.merging(fresh, confirmedMissing: ["removed"]).elementIDs,
            ["anchor", "unvisited"]
        )
        XCTAssertEqual(
            old.updatingViewport(with: fresh, confirmedMissing: ["removed"]).elementIDs,
            ["anchor", "unvisited"]
        )
        XCTAssertEqual(
            old.merging(fresh, confirmedMissing: ["removed"]).semanticInterface(timestamp: .distantPast)
                .annotations.elements.map(\.source),
            [.capture, .memory]
        )
    }

    func testViewportUpdateRetainsElementsThatMoveOffscreenInFullTreeCapture() throws {
        let visibleTarget = makeElement(label: "Target", traits: .button)
        let anchor = makeElement(label: "Anchor", traits: .staticText)
        let offscreenTarget = AccessibilityElement.make(
            label: "Target",
            traits: .button,
            visibility: .offscreen
        )
        let initial = InterfaceObservation.makeForTests(elements: [
            (visibleTarget, "target"),
            (anchor, "anchor"),
        ])
        let retainedParentGeometry = try XCTUnwrap(
            initial.tree.findElement(heistId: "target")?.geometry.view
        )
        let refreshed = InterfaceObservation.makeForTests(
            elements: [
                "target": InterfaceTree.Element(
                    heistId: "target",
                    path: TreePath([0]),
                    scrollMembership: nil,
                    geometry: HeistElement.Geometry(
                        screen: .offscreen,
                        view: retainedParentGeometry
                    ),
                    element: offscreenTarget
                ),
                "anchor": InterfaceTree.Element(
                    heistId: "anchor",
                    path: TreePath([1]),
                    scrollMembership: nil,
                    geometry: testGeometry(
                        for: anchor,
                        ownerPath: .root,
                        screen: TheVault.onscreenSpace(for: anchor)
                    ),
                    element: anchor
                ),
            ],
            hierarchy: [
                .element(offscreenTarget, traversalIndex: 0),
                .element(anchor, traversalIndex: 1),
            ],
            heistIdsByPath: [
                TreePath([0]): "target",
                TreePath([1]): "anchor",
            ],
            firstResponderHeistId: nil
        )

        let updated = initial.tree.updatingViewport(with: refreshed.tree)

        XCTAssertEqual(updated.viewportElementIDs, ["anchor"])
        XCTAssertEqual(updated.elementIDs, ["anchor", "target"])
        XCTAssertEqual(updated.findElement(heistId: "target")?.geometry.screen, .offscreen)
        XCTAssertEqual(
            updated.semanticInterface(timestamp: .distantPast).annotations.elements.map(\.source),
            [.capture, .capture]
        )
        XCTAssertEqual(
            updated.findElement(heistId: "target")?.geometry.view,
            retainedParentGeometry
        )
        XCTAssertNotEqual(
            initial.tree.findElement(heistId: "target")?.geometry.screen,
            updated.findElement(heistId: "target")?.geometry.screen
        )
        XCTAssertNoThrow(try InterfaceObservation.build(tree: updated))
    }

    func testInterfaceTreeViewportUpdatePreservesDiscoveryMemoryWhenVisibleIdsAreKnown() {
        let visible = makeElement(label: "Visible", traits: .button)
        let offViewport = makeElement(label: "Known", traits: .button)
        let refreshedVisible = makeElement(label: "Visible", traits: .button)
        let screen = InterfaceObservation.makeForTests(
            elements: [(visible, "button_visible")],
            offViewport: [
                InterfaceObservation.OffViewportEntry(
                    offViewport,
                    heistId: "button_known",
                    scrollContainerPath: TreePath([0])
                )
            ]
        )
        let refresh = InterfaceObservation.makeForTests(
            elements: [(refreshedVisible, "button_visible")],
            firstResponderHeistId: "button_visible"
        )

        let updated = screen.tree.updatingViewport(with: refresh.tree)

        XCTAssertEqual(updated.elementIDs, ["button_visible", "button_known"])
        XCTAssertEqual(updated.viewportElementIDs, ["button_visible"])
        XCTAssertEqual(refresh.tree.viewportCapture.firstResponderHeistId, "button_visible")
        XCTAssertEqual(updated.viewportCapture.firstResponderHeistId, "button_visible")
        XCTAssertEqual(updated.findElement(heistId: "button_known")?.element.label, "Known")
        XCTAssertEqual(updated.findElement(heistId: "button_known")?.geometry.screen, .offscreen)
        XCTAssertEqual(
            updated.findElement(heistId: "button_known")?.geometry.view.ownerPath,
            TreePath([0])
        )
    }

    func testInterfaceTreeViewportUpdateSlotsVisibleUpdatesWithoutTouchingDiscoveryMemory() {
        let counter = makeElement(label: "Total", value: "$4.00", traits: .staticText)
        let offViewport = makeElement(label: "Below Fold", value: "old", traits: .button)
        let updatedCounter = makeElement(label: "Total", value: "$8.00", traits: .staticText)
        let screen = InterfaceObservation.makeForTests(
            elements: [(counter, "total_staticText")],
            offViewport: [
                InterfaceObservation.OffViewportEntry(
                    offViewport,
                    heistId: "below_fold_button",
                    scrollContainerPath: TreePath([0])
                )
            ]
        )
        let refresh = InterfaceObservation.makeForTests(elements: [(updatedCounter, "total_staticText")])

        let updated = screen.tree.updatingViewport(with: refresh.tree)

        XCTAssertEqual(updated.findElement(heistId: "total_staticText")?.element.value, "$8.00")
        XCTAssertEqual(updated.findElement(heistId: "below_fold_button")?.element.value, "old")
        XCTAssertEqual(updated.findElement(heistId: "below_fold_button")?.geometry.screen, .offscreen)
        XCTAssertEqual(updated.viewportElementIDs, ["total_staticText"])
        XCTAssertEqual(updated.elementIDs, ["below_fold_button", "total_staticText"])
    }

    func testInterfaceTreeViewportUpdateDoesNotPreserveDiscoveryMemoryForDisjointCommittedViewport() {
        let oldVisible = makeElement(label: "Old Visible", traits: .button)
        let staleOffViewport = makeElement(label: "Stale Below Fold", traits: .button)
        let freshVisible = makeElement(label: "Fresh Visible", traits: .button)
        let screen = InterfaceObservation.makeForTests(
            elements: [(oldVisible, "old_visible")],
            offViewport: [
                InterfaceObservation.OffViewportEntry(
                    staleOffViewport,
                    heistId: "stale_below_fold",
                    scrollContainerPath: TreePath([0])
                ),
            ]
        )
        let refresh = InterfaceObservation.makeForTests(elements: [(freshVisible, "stale_below_fold")])

        let updated = screen.tree.updatingViewport(with: refresh.tree)

        XCTAssertEqual(updated.viewportElementIDs, ["stale_below_fold"])
        XCTAssertEqual(updated.elementIDs, ["stale_below_fold"])
        XCTAssertEqual(updated.findElement(heistId: "stale_below_fold")?.element.label, "Fresh Visible")
        guard let refreshedGeometry = updated.findElement(heistId: "stale_below_fold")?.geometry,
              case .onscreen = refreshedGeometry.screen
        else {
            return XCTFail("Expected the refreshed element to carry onscreen geometry")
        }
    }

    func testInterfaceTreeViewportUpdatePreservesDiscoveryMemoryFromOffViewportBaseline() {
        let offViewport = makeElement(label: "Below Fold", traits: .button)
        let visible = makeElement(label: "Visible", traits: .button)
        let screen = InterfaceObservation.makeForTests(
            offViewport: [InterfaceObservation.OffViewportEntry(offViewport, heistId: "below_fold_button")]
        )
        let refresh = InterfaceObservation.makeForTests(elements: [(visible, "button_visible")])

        let updated = screen.tree.updatingViewport(with: refresh.tree)

        XCTAssertEqual(updated.viewportElementIDs, ["button_visible"])
        XCTAssertEqual(updated.elementIDs, ["below_fold_button", "button_visible"])
        XCTAssertEqual(updated.findElement(heistId: "below_fold_button")?.element.label, "Below Fold")
        XCTAssertEqual(updated.findElement(heistId: "below_fold_button")?.geometry.screen, .offscreen)
    }

    func testInterfaceTreeViewportUpdatePreservesDiscoveryMemoryWhenCommittedViewportAddsElement() {
        let visible = makeElement(label: "Visible", traits: .button)
        let added = makeElement(label: "Added", traits: .button)
        let offViewport = makeElement(label: "Below Fold", traits: .button)
        let screen = InterfaceObservation.makeForTests(
            elements: [(visible, "button_visible")],
            offViewport: [InterfaceObservation.OffViewportEntry(offViewport, heistId: "below_fold_button")]
        )
        let refresh = InterfaceObservation.makeForTests(elements: [
            (visible, "button_visible"),
            (added, "button_added")
        ])

        let updated = screen.tree.updatingViewport(with: refresh.tree)

        XCTAssertEqual(updated.viewportElementIDs, ["button_added", "button_visible"])
        XCTAssertEqual(updated.elementIDs, ["below_fold_button", "button_added", "button_visible"])
        XCTAssertEqual(updated.findElement(heistId: "below_fold_button")?.element.label, "Below Fold")
        XCTAssertEqual(updated.findElement(heistId: "below_fold_button")?.geometry.screen, .offscreen)
    }

    func testInterfaceTreeViewportUpdateDropsDisappearedVisibleNonScrollElements() {
        let disappearing = makeElement(label: "Disappearing", traits: .staticText)
        let visible = makeElement(label: "Visible", traits: .button)
        let screen = InterfaceObservation.makeForTests(
            elements: [
                (disappearing, "disappearing_staticText"),
                (visible, "button_visible")
            ]
        )
        let refresh = InterfaceObservation.makeForTests(elements: [(visible, "button_visible")])

        let updated = screen.tree.updatingViewport(with: refresh.tree)

        XCTAssertEqual(updated.elementIDs, ["button_visible"])
        XCTAssertNil(updated.findElement(heistId: "disappearing_staticText"))
    }

    func testInterfaceTreeViewportUpdateDropsDisappearedVisibleScrollElements() {
        let scrolledAway = makeElement(label: "Scrolled Away", traits: .button)
        let visible = makeElement(label: "Visible", traits: .button)
        let scrollContainer = AccessibilityContainer(
            type: .none,
            scrollableContentSize: AccessibilitySize(width: 320, height: 1_200),
            frame: AccessibilityRect(x: 0, y: 0, width: 320, height: 400)
        )
        let screen = InterfaceObservation.makeForTests(
            elements: [
                "button_scrolled_away": InterfaceTree.Element(
                    heistId: "button_scrolled_away",
                    path: TreePath([0, 0]),
                    scrollMembership: InterfaceTree.ScrollMembership(containerPath: TreePath([0]), index: nil),
                    geometry: testGeometry(
                        for: scrolledAway,
                        ownerPath: TreePath([0]),
                        screen: TheVault.onscreenSpace(for: scrolledAway)
                    ),
                    element: scrolledAway
                ),
                "button_visible": InterfaceTree.Element(
                    heistId: "button_visible",
                    path: TreePath([1]),
                    scrollMembership: nil,
                    geometry: testGeometry(
                        for: visible,
                        ownerPath: .root,
                        screen: TheVault.onscreenSpace(for: visible)
                    ),
                    element: visible
                )
            ],
            hierarchy: [
                .container(scrollContainer, children: [
                    .element(scrolledAway, traversalIndex: 0),
                ]),
                .element(visible, traversalIndex: 1)
            ],
            heistIdsByPath: [
                TreePath([0, 0]): "button_scrolled_away",
                TreePath([1]): "button_visible"
            ],
            firstResponderHeistId: nil,
        )
        let refresh = InterfaceObservation.makeForTests(elements: [(visible, "button_visible")])

        let updated = screen.tree.updatingViewport(with: refresh.tree)

        XCTAssertEqual(updated.elementIDs, ["button_visible"])
        XCTAssertEqual(updated.viewportElementIDs, ["button_visible"])
        XCTAssertNil(updated.findElement(heistId: "button_scrolled_away"))
    }

    func testInterfaceTreeViewportUpdatePreservesOffViewportMemoryForUnrelatedVisibleRefresh() {
        let old = makeElement(label: "Old", traits: .button)
        let offViewport = makeElement(label: "Known", traits: .button)
        let replacement = makeElement(label: "Replacement", traits: .button)
        let screen = InterfaceObservation.makeForTests(
            elements: [(old, "button_old")],
            offViewport: [
                InterfaceObservation.OffViewportEntry(offViewport, heistId: "button_known")
            ]
        )
        let refresh = InterfaceObservation.makeForTests(elements: [(replacement, "button_replacement")])

        let updated = screen.tree.updatingViewport(with: refresh.tree)

        XCTAssertEqual(updated.elementIDs, ["button_known", "button_replacement"])
        XCTAssertEqual(updated.findElement(heistId: "button_known")?.element.label, "Known")
        XCTAssertEqual(updated.findElement(heistId: "button_known")?.geometry.screen, .offscreen)
    }

    func testInterfaceTreeViewportUpdateReplacesInterfaceTreeForEmptyRefresh() {
        let old = makeElement(label: "Old", traits: .button)
        let screen = InterfaceObservation.makeForTests(elements: [(old, "button_old")])

        let updated = screen.tree.updatingViewport(with: .empty)

        XCTAssertTrue(updated.elementIDs.isEmpty)
        XCTAssertTrue(updated.viewportElementIDs.isEmpty)
    }
}

#endif // canImport(UIKit)
