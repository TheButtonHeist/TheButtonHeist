#if canImport(UIKit)
import ButtonHeistSupport
import XCTest
import ThePlans
import UIKit
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

@MainActor
extension TheBrainsScrollTests {

    func testSemanticRevealNoOpsWhenAlreadyVisible() async {
        let scrollView = RecordingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        let visibleElement = makeElement(label: "Visible")
        let visibleEntry = InterfaceTree.Element(
            heistId: "visible_element",
            scrollMembership: InterfaceTree.ScrollMembership(containerPath: TreePath([0]), index: nil),
            geometry: testGeometry(
                for: visibleElement,
                ownerPath: TreePath([0]),
                screen: TheVault.onscreenSpace(for: visibleElement)
            ),
            element: visibleElement
        )
        await installLiveScrollTarget(visibleEntry, scrollView: scrollView, containerName: "visible_scroll")

        let result = await brains.navigation.elementInflation.revealSemanticTarget(
            visibleEntry, deadline: semanticRevealDeadline()
        )

        guard case .alreadyVisible = result else {
            return XCTFail("Expected already-visible no-op, got \(result)")
        }
        XCTAssertEqual(scrollView.setContentOffsetAnimations, [])
        XCTAssertEqual(scrollView.contentOffset, .zero)
    }

    func testDirectSemanticRevealRejectsReusedIdReplacementWithoutStaleRestore() async throws {
        let scrollView = RecordingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        scrollView.contentOffset = CGPoint(x: 0, y: 80)
        let targetId: HeistId = "direct_reused_target"
        await installScreenWithOffViewport(
            visible: .init(makeElement(label: "Visible"), heistId: "visible_element"),
            offscreen: .init(
                makeElement(label: "Original Target", traits: .button),
                heistId: targetId,
                viewActivationPoint: CGPoint(x: 0, y: 1_200),
                scrollView: scrollView
            )
        )
        visibleObservationSource.observation = InterfaceObservation.makeForTests([
            .init(
                makeElement(label: "Replacement Target", traits: .button),
                heistId: targetId,
                object: retainedLiveObject()
            ),
        ])
        brains.navigation.elementInflation.exploration.revealKnownTarget = { _ in nil }
        scrollView.setContentOffsetAnimations.removeAll()
        let treeElement = try XCTUnwrap(brains.vault.interfaceElement(heistId: targetId))

        let result = await brains.navigation.elementInflation.revealSemanticTarget(
            treeElement,
            deadline: semanticRevealDeadline()
        )

        guard case .targetResolutionFailed(.notFound) = result else {
            return XCTFail("Expected direct reused-ID evidence to fail as not found, got \(result)")
        }
        XCTAssertEqual(scrollView.setContentOffsetAnimations, [false])
        XCTAssertNotEqual(scrollView.contentOffset, CGPoint(x: 0, y: 80))
    }

    func testSemanticRevealFailsWithoutProvenLiveScrollAncestor() async throws {
        let scrollView = RecordingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        let visible = makeElement(label: "Visible")
        let offscreen = makeElement(label: "Settings")
        await installScreenWithOffViewport(
            visible: InterfaceObservation.TestEntry(visible, heistId: "visible_element"),
            offscreen: OffViewportScrollTarget(
                offscreen,
                heistId: "settings_button",
                viewActivationPoint: CGPoint(x: 0, y: 1_200),
                scrollView: scrollView
            ),
            includeLiveScrollAncestor: false
        )

        let entry = try XCTUnwrap(
            brains.vault.interfaceTree.findElement(heistId: "settings_button")
        )
        let result = await brains.navigation.elementInflation.revealSemanticTarget(
            entry, deadline: semanticRevealDeadline()
        )

        guard case .failed(.noLiveScrollableAncestor) = result else {
            return XCTFail("Expected missing live scroll ancestor failure, got \(result)")
        }
        XCTAssertEqual(scrollView.setContentOffsetAnimations, [])
        XCTAssertEqual(scrollView.contentOffset, .zero)
    }

    func testSemanticOwnerReacquisitionRestoresOnlyMatchingGeometry() async throws {
        let rememberedPath = TreePath([9])
        let livePath = TreePath([1])
        let scrollView = RecordingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        let container = makeScrollableContainer(
            contentSize: scrollView.contentSize,
            frame: scrollView.frame
        )
        let rememberedPoint = CGPoint(x: 160, y: 1_200)
        let anchor = makeElement(label: "Visible Anchor")
        let targetElement = makeElement(label: "Moved Owner Target", traits: .button)
        let target = InterfaceTree.Element(
            heistId: "moved_owner_target",
            path: rememberedPath.appending(0),
            scrollMembership: .init(containerPath: rememberedPath, index: nil),
            geometry: HeistElement.Geometry(
                screen: .offscreen,
                view: .available(.init(
                    ownerPath: rememberedPath,
                    frame: try ViewRect(validating: CGRect(
                        x: rememberedPoint.x - 110,
                        y: rememberedPoint.y - 22,
                        width: 220,
                        height: 44
                    )),
                    activationPoint: try ViewPoint(validating: rememberedPoint)
                ))
            ),
            element: targetElement
        )
        let fixture = SemanticOwnerReacquisitionFixture(
            rememberedPath: rememberedPath,
            container: container,
            anchor: anchor,
            target: target
        )
        await installSyntheticObservation(try semanticOwnerReacquisitionObservation(
            fixture: fixture,
            livePath: livePath,
            scrollView: scrollView
        ))
        let sourceTarget = try resolvedTarget(.label("Moved Owner Target").and(.traits([.button])))
        guard case .admitted(let admittedTarget) = brains.navigation.elementInflation.admitSemanticTarget(
            sourceTarget,
            selectedElement: target
        ) else {
            return XCTFail("Expected target with a remembered scroll owner to admit")
        }
        var dispatchedPoint: ViewPoint?
        var dispatchedOwnerPath: TreePath?
        brains.navigation.elementInflation.exploration.moveViewport = { intent, _ in
            if case .revealViewPoint(let point, let target) = intent {
                dispatchedPoint = point
                dispatchedOwnerPath = target.containerTarget.path
            }
            return .unavailable()
        }
        var revealRootScrollViewID: ObjectIdentifier?
        brains.navigation.elementInflation.exploration.revealKnownTarget = { request in
            revealRootScrollViewID = request.revealRootScrollViewID
            return .unavailable
        }

        let result = await brains.navigation.elementInflation.revealSemanticTarget(
            admittedTarget,
            deadline: semanticRevealDeadline()
        )

        guard case .failed(.scanDidNotRevealTarget) = result else {
            return XCTFail("Expected the reacquired live container to admit a fallback scan, got \(result)")
        }
        XCTAssertEqual(revealRootScrollViewID, ObjectIdentifier(scrollView))
        XCTAssertEqual(dispatchedPoint, try ViewPoint(validating: rememberedPoint))
        XCTAssertEqual(dispatchedOwnerPath, livePath)
        XCTAssertEqual(scrollView.setContentOffsetAnimations, [])

        let replacementPath = TreePath([2])
        let replacementScrollView = RecordingScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400)
        )
        replacementScrollView.contentSize = CGSize(width: 320, height: 1_600)
        await installSyntheticObservation(try semanticOwnerReacquisitionObservation(
            fixture: fixture,
            livePath: replacementPath,
            scrollView: replacementScrollView
        ))
        dispatchedPoint = nil
        dispatchedOwnerPath = nil
        revealRootScrollViewID = nil

        let repeatedResult = await brains.navigation.elementInflation.revealSemanticTarget(
            admittedTarget,
            deadline: semanticRevealDeadline()
        )

        guard case .failed(.scanDidNotRevealTarget) = repeatedResult else {
            return XCTFail("Expected repeated matching-owner replacement to admit a scan, got \(repeatedResult)")
        }
        XCTAssertEqual(revealRootScrollViewID, ObjectIdentifier(replacementScrollView))
        XCTAssertEqual(dispatchedPoint, try ViewPoint(validating: rememberedPoint))
        XCTAssertEqual(dispatchedOwnerPath, replacementPath)
        XCTAssertEqual(replacementScrollView.setContentOffsetAnimations, [])
    }

    func testSemanticRevealDoesNotGuessWhenMovedContainerIdentityIsAmbiguous() async throws {
        let rememberedPath = TreePath([9])
        let firstPath = TreePath([0])
        let secondPath = TreePath([1])
        let firstScrollView = RecordingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let secondScrollView = RecordingScrollView(frame: CGRect(x: 0, y: 420, width: 320, height: 400))
        firstScrollView.contentSize = CGSize(width: 320, height: 1_600)
        secondScrollView.contentSize = firstScrollView.contentSize
        let container = makeScrollableContainer(
            contentSize: firstScrollView.contentSize,
            frame: firstScrollView.frame
        )
        let targetElement = makeElement(label: "Ambiguous Owner Target", traits: .button)
        let target = InterfaceTree.Element(
            heistId: "ambiguous_owner_target",
            path: rememberedPath.appending(0),
            scrollMembership: .init(containerPath: rememberedPath, index: nil),
            geometry: HeistElement.Geometry(
                screen: .offscreen,
                view: .invalidated(ownerPath: rememberedPath)
            ),
            element: targetElement
        )
        let liveObservation = InterfaceObservation.makeForTests(
            elements: [target.heistId: target],
            hierarchy: [
                .container(container, children: []),
                .container(container, children: []),
            ],
            containerRefsByPath: [
                firstPath: .init(object: firstScrollView),
                secondPath: .init(object: secondScrollView),
            ],
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: [
                firstPath: .init(view: firstScrollView),
                secondPath: .init(view: secondScrollView),
            ]
        )
        var containers = liveObservation.tree.containers
        containers[rememberedPath] = InterfaceTree.Container(
            container: container,
            path: rememberedPath,
            containerName: "remembered_scroll",
            viewSpace: .available(.init(
                ownerPath: .root,
                frame: try ViewRect(validating: firstScrollView.frame),
                activationPoint: try ViewPoint(validating: CGPoint(
                    x: firstScrollView.frame.midX,
                    y: firstScrollView.frame.midY
                ))
            ))
        )
        let observation = InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: liveObservation.tree.elements,
                containers: containers,
                viewportCapture: liveObservation.tree.viewportCapture
            ),
            liveCapture: liveObservation.liveCapture
        )
        await installSyntheticObservation(observation)
        let sourceTarget = try resolvedTarget(.label("Ambiguous Owner Target").and(.traits([.button])))
        guard case .admitted(let admittedTarget) = brains.navigation.elementInflation.admitSemanticTarget(
            sourceTarget,
            selectedElement: target
        ) else {
            return XCTFail("Expected target with a remembered scroll owner to admit")
        }
        var attemptedScan = false
        brains.navigation.elementInflation.exploration.revealKnownTarget = { _ in
            attemptedScan = true
            return .unavailable
        }

        let result = await brains.navigation.elementInflation.revealSemanticTarget(
            admittedTarget,
            deadline: semanticRevealDeadline()
        )

        guard case .failed(.noLiveScrollableAncestor) = result else {
            return XCTFail("Expected ambiguous live owners to remain unavailable, got \(result)")
        }
        XCTAssertFalse(attemptedScan)
        XCTAssertEqual(firstScrollView.setContentOffsetAnimations, [])
        XCTAssertEqual(secondScrollView.setContentOffsetAnimations, [])
    }

    func testSemanticRevealDispatchesPointOnlyToMatchingOwner() async throws {
        let scrollView = RecordingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        let observedPoint = CGPoint(x: 160, y: 1_200)
        await installScreenWithOffViewport(
            visible: .init(makeElement(label: "Visible"), heistId: "visible_element"),
            offscreen: .init(
                makeElement(label: "Settings", traits: .button),
                heistId: "settings_button",
                viewActivationPoint: observedPoint,
                scrollView: scrollView
            )
        )
        let matchingObservation = brains.vault.currentInterfaceObservation
        let matchingElement = try XCTUnwrap(
            matchingObservation.tree.findElement(heistId: "settings_button")
        )
        let mismatchedElement = InterfaceTree.Element(
            heistId: matchingElement.heistId,
            path: matchingElement.path,
            scrollMembership: matchingElement.scrollMembership,
            geometry: HeistElement.Geometry(
                screen: matchingElement.geometry.screen,
                view: viewSpace(
                    try ViewPoint(validating: observedPoint),
                    ownerPath: TreePath([1])
                )
            ),
            element: matchingElement.element
        )
        var mismatchedElements = matchingObservation.tree.elements
        mismatchedElements[mismatchedElement.heistId] = mismatchedElement
        let mismatchedObservation = InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: mismatchedElements,
                containers: matchingObservation.tree.containers,
                viewportCapture: matchingObservation.tree.viewportCapture
            ),
            liveCapture: matchingObservation.liveCapture
        )
        let sourceTarget = try resolvedTarget(.label("Settings").and(.traits([.button])))
        var dispatchedPoints: [ViewPoint] = []
        var dispatchedOwnerPaths: [TreePath] = []
        brains.navigation.elementInflation.exploration.moveViewport = { intent, _ in
            if case .revealViewPoint(let point, let target) = intent {
                dispatchedPoints.append(point)
                dispatchedOwnerPaths.append(target.containerTarget.path)
            }
            return .unavailable()
        }
        brains.navigation.elementInflation.exploration.revealKnownTarget = { _ in nil }

        await installSyntheticObservation(mismatchedObservation)
        guard case .admitted(let mismatchedTarget) = brains.navigation.elementInflation.admitSemanticTarget(
            sourceTarget,
            selectedElement: mismatchedElement
        ) else {
            return XCTFail("Expected mismatched fixture target to retain semantic admission")
        }
        _ = await brains.navigation.elementInflation.revealSemanticTarget(
            mismatchedTarget,
            deadline: semanticRevealDeadline()
        )

        XCTAssertTrue(dispatchedPoints.isEmpty)
        XCTAssertTrue(dispatchedOwnerPaths.isEmpty)

        await installSyntheticObservation(matchingObservation)
        guard case .admitted(let matchingTarget) = brains.navigation.elementInflation.admitSemanticTarget(
            sourceTarget,
            selectedElement: matchingElement
        ) else {
            return XCTFail("Expected matching fixture target to retain semantic admission")
        }
        _ = await brains.navigation.elementInflation.revealSemanticTarget(
            matchingTarget,
            deadline: semanticRevealDeadline()
        )

        XCTAssertEqual(dispatchedPoints, [try ViewPoint(validating: observedPoint)])
        XCTAssertEqual(dispatchedOwnerPaths, [TreePath([0])])
    }

    func testMissingInnerOwnerPagesAncestorWithoutReusingInnerContentPoint() async throws {
        let rootView = UIView()
        rootView.backgroundColor = .white
        let scrollView = RecordingScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400)
        )
        scrollView.contentSize = CGSize(width: 320, height: 1_200)
        rootView.addSubview(scrollView)

        let window = try installModalWindow(rootView: rootView)
        defer {
            window.rootViewController?.view.accessibilityViewIsModal = false
            window.isHidden = true
        }
        _ = try await publishedVisibleObservation()

        let ancestorPath = TreePath([0])
        let missingOwnerPath = ancestorPath.appending(0)
        let innerContentPoint = CGPoint(x: 160, y: 1_000)
        let container = makeScrollableContainer(
            contentSize: scrollView.contentSize,
            frame: scrollView.frame
        )
        let visibleElement = makeElement(label: "Visible")
        let visibleEntry = InterfaceTree.Element(
            heistId: "visible_element",
            scrollMembership: .init(containerPath: ancestorPath, index: nil),
            geometry: testGeometry(
                for: visibleElement,
                ownerPath: ancestorPath,
                screen: TheVault.onscreenSpace(for: visibleElement)
            ),
            element: visibleElement
        )
        let knownElement = makeElement(label: "Paged Target", traits: .button)
        let knownEntry = InterfaceTree.Element(
            heistId: "known_paged_target",
            scrollMembership: .init(containerPath: missingOwnerPath, index: nil),
            geometry: HeistElement.Geometry(
                screen: .offscreen,
                view: viewSpace(
                    try ViewPoint(validating: innerContentPoint),
                    ownerPath: missingOwnerPath
                )
            ),
            element: knownElement
        )
        let initialObservation = InterfaceObservation.makeForTests(
            elements: [
                visibleEntry.heistId: visibleEntry,
                knownEntry.heistId: knownEntry,
            ],
            hierarchy: [
                .container(container, children: [
                    .element(visibleElement, traversalIndex: 0),
                ]),
            ],
            heistIdsByPath: [ancestorPath.appending(0): visibleEntry.heistId],
            containerRefsByPath: [ancestorPath: .init(object: scrollView)],
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: [ancestorPath: .init(view: scrollView)]
        )
        let revealedElement = makeElement(label: "Paged Target", traits: .button)
        let revealed = revealedObservation(
            element: revealedElement,
            heistId: knownEntry.heistId,
            container: container,
            ownerPath: ancestorPath,
            scrollView: scrollView
        )
        await installSyntheticObservation(initialObservation)
        var movementTargets: [ObjectIdentifier] = []
        scrollView.onSetContentOffset = { scrollView in
            movementTargets.append(ObjectIdentifier(scrollView))
            self.visibleObservationSource.observation = revealed
        }
        let sourceTarget = try resolvedTarget(.label("Paged Target").and(.traits([.button])))
        guard case .admitted(let admittedTarget) = brains.navigation.elementInflation.admitSemanticTarget(
            sourceTarget,
            selectedElement: knownEntry
        ) else {
            return XCTFail("Expected known target with missing owner to admit")
        }

        let result = await brains.navigation.scanForSemanticTarget(.init(
            target: admittedTarget,
            revealRootScrollViewID: ObjectIdentifier(scrollView),
            deadline: semanticRevealDeadline()
        ))

        guard case .revealed(_, let exploration) = result else {
            return XCTFail("Expected ancestor paging to reveal the target, got \(result)")
        }
        let insets = scrollView.adjustedContentInset
        let visibleHeight = scrollView.bounds.height - insets.top - insets.bottom
        let expectedPageOffset = -insets.top
            + visibleHeight
            - CGFloat(ScrollContainerMetrics.pageOverlap)
        let innerSeedOffset = innerContentPoint.y - scrollView.bounds.height / 2
        XCTAssertEqual(exploration.progress.scrollCount, 1)
        XCTAssertEqual(movementTargets, [ObjectIdentifier(scrollView)])
        XCTAssertEqual(scrollView.requestedContentOffsets, [CGPoint(x: 0, y: expectedPageOffset)])
        XCTAssertNotEqual(scrollView.requestedContentOffsets[0].y, innerSeedOffset, accuracy: 0.01)
        XCTAssertEqual(scrollView.contentOffset.y, expectedPageOffset, accuracy: 0.01)
    }

    func testSiblingOwnerMismatchDoesNotDispatchSeed() async throws {
        let fixture = try siblingOwnerMismatchFixture()
        let window = try installModalWindow(rootView: fixture.rootView)
        defer {
            window.rootViewController?.view.accessibilityViewIsModal = false
            window.isHidden = true
        }
        _ = try await publishedVisibleObservation()

        await installSyntheticObservation(fixture.initialObservation)
        fixture.siblingScrollView.onSetContentOffset = { _ in
            self.visibleObservationSource.observation = fixture.revealedObservation
        }
        let sourceTarget = try resolvedTarget(
            .label("Sibling Target").and(.traits([.button]))
        )
        guard case .admitted(let admittedTarget) = brains.navigation.elementInflation.admitSemanticTarget(
            sourceTarget,
            selectedElement: fixture.targetEntry
        ) else {
            return XCTFail("Expected sibling target to admit")
        }

        let result = await brains.navigation.scanForSemanticTarget(.init(
            target: admittedTarget,
            revealRootScrollViewID: ObjectIdentifier(fixture.ancestorScrollView),
            deadline: semanticRevealDeadline()
        ))

        guard case .revealed(_, let exploration) = result else {
            return XCTFail("Expected sibling paging to reveal the target, got \(result)")
        }
        let insets = fixture.siblingScrollView.adjustedContentInset
        let visibleHeight = fixture.siblingScrollView.bounds.height - insets.top - insets.bottom
        let expectedPageOffset = -insets.top
            + visibleHeight
            - CGFloat(ScrollContainerMetrics.pageOverlap)
        let storedSeedOffset = fixture.storedInnerPoint.y
            - fixture.siblingScrollView.bounds.height / 2
        XCTAssertEqual(exploration.progress.scrollCount, 1)
        XCTAssertTrue(fixture.ancestorScrollView.requestedContentOffsets.isEmpty)
        XCTAssertEqual(fixture.siblingScrollView.requestedContentOffsets.count, 1)
        XCTAssertEqual(fixture.siblingScrollView.requestedContentOffsets[0].x, 0, accuracy: 0.01)
        XCTAssertEqual(fixture.siblingScrollView.requestedContentOffsets[0].y, expectedPageOffset, accuracy: 0.01)
        XCTAssertNotEqual(fixture.siblingScrollView.requestedContentOffsets[0].y, storedSeedOffset, accuracy: 0.01)
    }

    func testLaterOwnerMatchConsumesStoredSeed() async throws {
        let fixture = try laterOwnerMatchFixture()
        await installSyntheticObservation(fixture.unavailableObservation)
        let sourceTarget = try resolvedTarget(
            .label("Later Owner Target").and(.traits([.button]))
        )
        guard case .admitted(let admittedTarget) = brains.navigation.elementInflation.admitSemanticTarget(
            sourceTarget,
            selectedElement: fixture.targetEntry
        ) else {
            return XCTFail("Expected later owner target to admit")
        }

        let unavailableResult = await brains.navigation.scanForSemanticTarget(.init(
            target: admittedTarget,
            revealRootScrollViewID: ObjectIdentifier(fixture.ownerScrollView),
            deadline: semanticRevealDeadline()
        ))

        guard case .unavailable = unavailableResult else {
            return XCTFail("Expected absent owner request to remain unavailable, got \(unavailableResult)")
        }
        XCTAssertTrue(fixture.ownerScrollView.requestedContentOffsets.isEmpty)
        XCTAssertTrue(fixture.decoyScrollView.requestedContentOffsets.isEmpty)

        await installSyntheticObservation(fixture.matchingObservation)
        fixture.ownerScrollView.onSetContentOffset = { _ in
            self.visibleObservationSource.observation = fixture.revealedObservation
        }

        let result = await brains.navigation.scanForSemanticTarget(.init(
            target: admittedTarget,
            revealRootScrollViewID: ObjectIdentifier(fixture.ownerScrollView),
            deadline: semanticRevealDeadline()
        ))

        guard case .revealed(let currentElement, let exploration) = result else {
            return XCTFail("Expected restored owner to consume the seed, got \(result)")
        }
        XCTAssertEqual(currentElement.heistId, fixture.targetEntry.heistId)
        XCTAssertEqual(exploration.progress.scrollCount, 0)
        XCTAssertEqual(fixture.ownerScrollView.setContentOffsetAnimations, [false])
        XCTAssertEqual(fixture.ownerScrollView.requestedContentOffsets.count, 1)
        XCTAssertEqual(fixture.ownerScrollView.requestedContentOffsets[0].x, 0, accuracy: 0.01)
        XCTAssertEqual(fixture.ownerScrollView.requestedContentOffsets[0].y, 1_000, accuracy: 0.01)
        XCTAssertTrue(fixture.decoyScrollView.requestedContentOffsets.isEmpty)
    }

    func testSemanticRevealAdoptsCurrentIdAfterCandidateReordering() async throws {
        let selectedObject = SemanticActivationView()
        let siblingObject = SemanticActivationView()
        let postRevealObservation = InterfaceObservation.makeForTests([
            .init(
                reviewPRElement(priority: "P2"),
                heistId: "current_priority_one",
                object: siblingObject
            ),
            .init(
                reviewPRElement(priority: "P1"),
                heistId: "stabilized_priority_one",
                object: selectedObject
            ),
        ])

        let result = try await inflateSemanticDuplicate(
            postRevealObservation: postRevealObservation
        )

        guard case .inflated(let inflatedTarget) = result else {
            return XCTFail("Expected semantic identity to survive geometry stabilization, got \(result)")
        }
        XCTAssertEqual(inflatedTarget.treeElement.heistId, "stabilized_priority_one")
        XCTAssertTrue(inflatedTarget.liveTarget.object === selectedObject)
        _ = AccessibilityActionDispatcher().activate(inflatedTarget.liveTarget)
        XCTAssertEqual(selectedObject.activationCount, 1)
        XCTAssertEqual(siblingObject.activationCount, 0)
    }

    func testSemanticRevealFailsWhenTargetDisappearsAtGeometryCapture() async throws {
        let siblingObject = SemanticActivationView()
        let result = try await inflateSemanticDuplicate(
            postRevealObservation: .makeForTests([
                .init(
                    reviewPRElement(priority: "P2"),
                    heistId: "current_priority_one",
                    object: siblingObject
                ),
            ])
        )

        guard case .failed(let failure) = result else {
            return XCTFail("Expected the missing admitted target to fail, got \(result)")
        }
        XCTAssertEqual(failure.failedStep, .notFound)
        XCTAssertEqual(siblingObject.activationCount, 0)
    }

    func testSemanticRevealFailsWhenTargetBecomesAmbiguousAtGeometryCapture() async throws {
        let firstObject = SemanticActivationView()
        let secondObject = SemanticActivationView()
        let result = try await inflateSemanticDuplicate(
            postRevealObservation: .makeForTests([
                .init(
                    reviewPRElement(priority: "P1"),
                    heistId: "current_priority_one",
                    object: firstObject
                ),
                .init(
                    reviewPRElement(priority: "P1"),
                    heistId: "stabilized_priority_one",
                    object: secondObject
                ),
            ])
        )

        guard case .failed(let failure) = result else {
            return XCTFail("Expected the ambiguous admitted target to fail, got \(result)")
        }
        XCTAssertEqual(failure.failedStep, .ambiguous)
        XCTAssertEqual(firstObject.activationCount, 0)
        XCTAssertEqual(secondObject.activationCount, 0)
    }

    func testKnownTargetRevealReturnsTimedOutInflationFailureBeforeWork() async throws {
        let scrollView = RecordingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        await installScreenWithOffViewport(
            visible: .init(makeElement(label: "Visible"), heistId: "visible_element"),
            offscreen: .init(
                makeElement(label: "Settings"),
                heistId: "settings_button",
                viewActivationPoint: CGPoint(x: 0, y: 1_200),
                scrollView: scrollView
            ),
            includeLiveScrollAncestor: false
        )
        let entry = try XCTUnwrap(brains.vault.interfaceTree.findElement(heistId: "settings_button"))
        var knownTargetAttempts = 0
        brains.navigation.elementInflation.exploration.revealKnownTarget = { _ in
            knownTargetAttempts += 1
            return nil
        }
        let deadline = SemanticObservationDeadline(
            start: RuntimeElapsed.now,
            timeoutSeconds: 0
        )

        let state = await brains.navigation.elementInflation.stateAfterReveal(
            entry,
            target: try resolvedTarget(.label("Settings")),
            deadline: deadline,
            resolution: ActionSubjectResolution(origin: .known),
            transaction: .init(vault: brains.vault)
        )

        guard case .failed(let failure) = state else {
            return XCTFail("Expected typed deadline failure, got \(state)")
        }
        XCTAssertEqual(failure.failedStep, .timedOut)
        XCTAssertEqual(knownTargetAttempts, 0)
        XCTAssertEqual(scrollView.setContentOffsetAnimations, [])
    }

    func testKnownTargetRevealReturnsCancelledInflationFailureBeforeWork() async throws {
        let scrollView = RecordingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        await installScreenWithOffViewport(
            visible: .init(makeElement(label: "Visible"), heistId: "visible_element"),
            offscreen: .init(
                makeElement(label: "Settings"),
                heistId: "settings_button",
                viewActivationPoint: CGPoint(x: 0, y: 1_200),
                scrollView: scrollView
            ),
            includeLiveScrollAncestor: false
        )
        let entry = try XCTUnwrap(brains.vault.interfaceTree.findElement(heistId: "settings_button"))
        var knownTargetAttempts = 0
        brains.navigation.elementInflation.exploration.revealKnownTarget = { _ in
            knownTargetAttempts += 1
            return nil
        }
        let target = try resolvedTarget(AccessibilityTarget.label("Settings"))
        let revealTask = Task { @MainActor in
            let state = await self.brains.navigation.elementInflation.stateAfterReveal(
                entry,
                target: target,
                deadline: self.semanticRevealDeadline(),
                resolution: ActionSubjectResolution(origin: .known),
                transaction: .init(vault: self.brains.vault)
            )
            guard case .failed(let failure) = state else { return false }
            return failure.failedStep == .cancelled
        }
        revealTask.cancel()

        let wasCancelled = await revealTask.value
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(knownTargetAttempts, 0)
        XCTAssertEqual(scrollView.setContentOffsetAnimations, [])
    }

    func testScrollToVisibleUnknownTargetUsesCurrentSemanticDiagnostics() async throws {
        let visible = makeElement(label: "Visible")
        await installSyntheticObservation(
            .makeForTests(elements: [(visible, HeistId(rawValue: "visible_element"))])
        )

        let result = await brains.navigation.executeScrollToVisible(
            target: try resolvedScrollToVisibleTarget(
                ScrollToVisibleTarget(target: .label("Missing Button"))
            ),
            deadline: semanticRevealDeadline()
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .scrollToVisible)
        XCTAssertEqual(result.failureKind, .elementNotFound)
        XCTAssertTrue(result.message?.contains("element inflation failed [notFound]") == true)
        XCTAssertTrue(result.message?.contains("No match for") == true)
        XCTAssertTrue(result.message?.contains("Missing Button") == true)
        XCTAssertFalse(result.message?.contains("get_interface") == true)
    }

    func testElementInflationTimesOutWhenNoRevealPathAppears() async throws {
        let visible = makeElement(label: "Visible")
        let offscreen = makeElement(label: "Offscreen")
        await installScreenWithOffViewportEntry(
            liveHierarchy: [(visible, "visible_element")],
            offViewport: [InterfaceObservation.OffViewportEntry(offscreen, heistId: "offscreen_button")]
        )

        let result = await brains.navigation.elementInflation.inflate(
            for: try resolvedTarget(.label("Offscreen")),
            method: .activate,
            deadline: semanticRevealDeadline()
        )

        guard case .failed(let failure) = result else {
            return XCTFail("Expected element inflation timeout, got \(result)")
        }
        XCTAssertEqual(
            failure.failedStep,
            ElementInflation.ElementInflationFailureStep.timedOut,
            failure.message
        )
        XCTAssertEqual(failure.failureKind, .timeout)
        XCTAssertTrue(failure.message.contains("element inflation failed [timedOut]"))
    }

    private struct SemanticOwnerReacquisitionFixture {
        let rememberedPath: TreePath
        let container: AccessibilityContainer
        let anchor: AccessibilityElement
        let target: InterfaceTree.Element
    }

    private func semanticOwnerReacquisitionObservation(
        fixture: SemanticOwnerReacquisitionFixture,
        livePath: TreePath,
        scrollView: RecordingScrollView
    ) throws -> InterfaceObservation {
        precondition(livePath.indices.count == 1)
        let liveIndex = livePath.indices[0]
        precondition(liveIndex >= 0)
        let placeholder = AccessibilityContainer(
            type: .none,
            frame: AccessibilityRect(CGRect(x: 0, y: 0, width: 1, height: 1))
        )
        let hierarchy: [AccessibilityHierarchy] = Array(
            repeating: .container(placeholder, children: []),
            count: liveIndex
        ) + [
            .container(fixture.container, children: [
                .element(fixture.anchor, traversalIndex: 1),
            ]),
        ]
        let liveObservation = InterfaceObservation.makeForTests(
            elements: [fixture.target.heistId: fixture.target],
            hierarchy: hierarchy,
            heistIdsByPath: [livePath.appending(0): "visible_anchor"],
            elementRefs: [
                "visible_anchor": .init(object: retainedLiveObject(), scrollView: scrollView),
            ],
            containerRefsByPath: [livePath: .init(object: scrollView)],
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: [livePath: .init(view: scrollView)]
        )
        var containers = liveObservation.tree.containers
        containers[fixture.rememberedPath] = InterfaceTree.Container(
            container: fixture.container,
            path: fixture.rememberedPath,
            containerName: "remembered_scroll",
            viewSpace: .available(.init(
                ownerPath: .root,
                frame: try ViewRect(validating: scrollView.frame),
                activationPoint: try ViewPoint(validating: CGPoint(
                    x: scrollView.frame.midX,
                    y: scrollView.frame.midY
                ))
            ))
        )
        return InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: liveObservation.tree.elements,
                containers: containers,
                viewportCapture: liveObservation.tree.viewportCapture
            ),
            liveCapture: liveObservation.liveCapture
        )
    }

    private struct SiblingOwnerMismatchFixture {
        let rootView: UIView
        let ancestorScrollView: RecordingScrollView
        let siblingScrollView: RecordingScrollView
        let storedInnerPoint: CGPoint
        let targetEntry: InterfaceTree.Element
        let initialObservation: InterfaceObservation
        let revealedObservation: InterfaceObservation
    }

    private func revealedObservation(
        element: AccessibilityElement,
        heistId: HeistId,
        container: AccessibilityContainer,
        ownerPath: TreePath,
        scrollView: RecordingScrollView
    ) -> InterfaceObservation {
        let entry = InterfaceTree.Element(
            heistId: heistId,
            scrollMembership: .init(containerPath: ownerPath, index: nil),
            geometry: testGeometry(
                for: element,
                ownerPath: ownerPath,
                screen: TheVault.onscreenSpace(for: element)
            ),
            element: element
        )
        return InterfaceObservation.makeForTests(
            elements: [heistId: entry],
            hierarchy: [
                .container(container, children: [
                    .element(element, traversalIndex: 0),
                ]),
            ],
            heistIdsByPath: [ownerPath.appending(0): heistId],
            elementRefs: [heistId: .init(object: retainedLiveObject(), scrollView: scrollView)],
            containerRefsByPath: [ownerPath: .init(object: scrollView)],
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: [ownerPath: .init(view: scrollView)]
        )
    }

    private func siblingOwnerMismatchFixture() throws -> SiblingOwnerMismatchFixture {
        let rootView = UIView()
        rootView.backgroundColor = .white
        let ancestorScrollView = RecordingScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400)
        )
        ancestorScrollView.contentSize = CGSize(width: 320, height: 1_200)
        let siblingScrollView = RecordingScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 300)
        )
        siblingScrollView.contentSize = CGSize(width: 320, height: 1_800)
        ancestorScrollView.addSubview(siblingScrollView)
        rootView.addSubview(ancestorScrollView)

        let ancestorPath = TreePath([0])
        let siblingPath = ancestorPath.appending(0)
        let storedOwnerPath = ancestorPath.appending(1)
        let storedInnerPoint = CGPoint(x: 160, y: 1_300)
        let ancestorContainer = makeScrollableContainer(
            contentSize: ancestorScrollView.contentSize,
            frame: ancestorScrollView.frame
        )
        let siblingContainer = makeScrollableContainer(
            contentSize: siblingScrollView.contentSize,
            frame: siblingScrollView.frame
        )
        let targetElement = makeElement(label: "Sibling Target", traits: .button)
        let targetEntry = InterfaceTree.Element(
            heistId: "sibling_target",
            scrollMembership: .init(containerPath: siblingPath, index: nil),
            geometry: HeistElement.Geometry(
                screen: .offscreen,
                view: viewSpace(
                    try ViewPoint(validating: storedInnerPoint),
                    ownerPath: storedOwnerPath
                )
            ),
            element: targetElement
        )
        let containerRefs: [TreePath: LiveCapture.ContainerRef] = [
            ancestorPath: .init(object: ancestorScrollView),
            siblingPath: .init(object: siblingScrollView),
        ]
        let containerMemberships: [TreePath: InterfaceTree.ScrollMembership] = [
            siblingPath: .init(containerPath: ancestorPath, index: nil),
        ]
        let scrollableViews: [TreePath: LiveCapture.ScrollableViewRef] = [
            ancestorPath: .init(view: ancestorScrollView),
            siblingPath: .init(view: siblingScrollView),
        ]
        let initialObservation = InterfaceObservation.makeForTests(
            elements: [targetEntry.heistId: targetEntry],
            hierarchy: [
                .container(ancestorContainer, children: [
                    .container(siblingContainer, children: []),
                ]),
            ],
            containerRefsByPath: containerRefs,
            containerScrollMembershipsByPath: containerMemberships,
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: scrollableViews
        )
        let revealedEntry = InterfaceTree.Element(
            heistId: targetEntry.heistId,
            scrollMembership: .init(containerPath: siblingPath, index: nil),
            geometry: testGeometry(
                for: targetElement,
                ownerPath: siblingPath,
                screen: TheVault.onscreenSpace(for: targetElement)
            ),
            element: targetElement
        )
        let revealedObservation = InterfaceObservation.makeForTests(
            elements: [revealedEntry.heistId: revealedEntry],
            hierarchy: [
                .container(ancestorContainer, children: [
                    .container(siblingContainer, children: [
                        .element(targetElement, traversalIndex: 0),
                    ]),
                ]),
            ],
            heistIdsByPath: [siblingPath.appending(0): revealedEntry.heistId],
            elementRefs: [
                revealedEntry.heistId: .init(
                    object: retainedLiveObject(),
                    scrollView: siblingScrollView
                ),
            ],
            containerRefsByPath: containerRefs,
            containerScrollMembershipsByPath: containerMemberships,
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: scrollableViews
        )
        return SiblingOwnerMismatchFixture(
            rootView: rootView,
            ancestorScrollView: ancestorScrollView,
            siblingScrollView: siblingScrollView,
            storedInnerPoint: storedInnerPoint,
            targetEntry: targetEntry,
            initialObservation: initialObservation,
            revealedObservation: revealedObservation
        )
    }

    private struct LaterOwnerMatchFixture {
        let ownerScrollView: RecordingScrollView
        let decoyScrollView: RecordingScrollView
        let targetEntry: InterfaceTree.Element
        let unavailableObservation: InterfaceObservation
        let matchingObservation: InterfaceObservation
        let revealedObservation: InterfaceObservation
    }

    private func laterOwnerMatchFixture() throws -> LaterOwnerMatchFixture {
        let ownerPath = TreePath([0])
        let decoyPath = TreePath([1])
        let ownerScrollView = RecordingScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400)
        )
        ownerScrollView.contentSize = CGSize(width: 320, height: 1_600)
        let decoyScrollView = RecordingScrollView(
            frame: CGRect(x: 0, y: 420, width: 320, height: 400)
        )
        decoyScrollView.contentSize = CGSize(width: 320, height: 1_600)
        let ownerContainer = makeScrollableContainer(
            contentSize: ownerScrollView.contentSize,
            frame: ownerScrollView.frame
        )
        let decoyContainer = makeScrollableContainer(
            contentSize: decoyScrollView.contentSize,
            frame: decoyScrollView.frame
        )
        let targetId: HeistId = "later_owner_target"
        let targetElement = makeElement(label: "Later Owner Target", traits: .button)
        let viewSpace = viewSpace(
            try ViewPoint(validating: CGPoint(x: 160, y: 1_200)),
            ownerPath: ownerPath
        )
        let targetEntry = InterfaceTree.Element(
            heistId: targetId,
            scrollMembership: .init(containerPath: ownerPath, index: nil),
            geometry: HeistElement.Geometry(screen: .offscreen, view: viewSpace),
            element: targetElement
        )
        let unavailableObservation = InterfaceObservation.makeForTests(
            elements: [targetId: targetEntry],
            hierarchy: [
                .container(ownerContainer, children: []),
                .container(decoyContainer, children: []),
            ],
            firstResponderHeistId: nil
        )
        let containerRefs: [TreePath: LiveCapture.ContainerRef] = [
            ownerPath: .init(object: ownerScrollView),
            decoyPath: .init(object: decoyScrollView),
        ]
        let scrollableViews: [TreePath: LiveCapture.ScrollableViewRef] = [
            ownerPath: .init(view: ownerScrollView),
            decoyPath: .init(view: decoyScrollView),
        ]
        let matchingObservation = InterfaceObservation.makeForTests(
            elements: [targetId: targetEntry],
            hierarchy: [
                .container(ownerContainer, children: []),
                .container(decoyContainer, children: []),
            ],
            containerRefsByPath: containerRefs,
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: scrollableViews
        )
        let visibleEntry = InterfaceTree.Element(
            heistId: targetId,
            scrollMembership: .init(containerPath: ownerPath, index: nil),
            geometry: testGeometry(
                for: targetElement,
                ownerPath: ownerPath,
                screen: TheVault.onscreenSpace(for: targetElement)
            ),
            element: targetElement
        )
        let revealedObservation = InterfaceObservation.makeForTests(
            elements: [targetId: visibleEntry],
            hierarchy: [
                .container(ownerContainer, children: [
                    .element(targetElement, traversalIndex: 0),
                ]),
                .container(decoyContainer, children: []),
            ],
            heistIdsByPath: [ownerPath.appending(0): targetId],
            elementRefs: [
                targetId: .init(object: retainedLiveObject(), scrollView: ownerScrollView),
            ],
            containerRefsByPath: containerRefs,
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: scrollableViews
        )
        return LaterOwnerMatchFixture(
            ownerScrollView: ownerScrollView,
            decoyScrollView: decoyScrollView,
            targetEntry: targetEntry,
            unavailableObservation: unavailableObservation,
            matchingObservation: matchingObservation,
            revealedObservation: revealedObservation
        )
    }

    private func inflateSemanticDuplicate(
        postRevealObservation: InterfaceObservation
    ) async throws -> ElementInflation.ElementInflationResult {
        brains.tripwire.stopPulse()
        let scrollView = RecordingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        await installScreenWithOffViewport(
            visible: .init(reviewPRElement(priority: "P2"), heistId: "initial_priority_two"),
            offscreen: .init(
                reviewPRElement(
                    priority: "P1",
                    frame: CGRect(x: 40, y: 1_200, width: 240, height: 44)
                ),
                heistId: "initial_priority_one",
                viewActivationPoint: CGPoint(x: 160, y: 1_200),
                scrollView: scrollView
            )
        )
        let revealedObject = SemanticActivationView()
        let revealedObservation = InterfaceObservation.makeForTests([
            .init(
                reviewPRElement(priority: "P1"),
                heistId: "current_priority_one",
                object: revealedObject
            ),
            .init(
                reviewPRElement(priority: "P2"),
                heistId: "current_priority_two",
                object: SemanticActivationView()
            ),
        ])
        let originalMoveViewport = brains.navigation.elementInflation.exploration.moveViewport
        brains.navigation.elementInflation.exploration.moveViewport = { _, _ in .unavailable() }
        brains.navigation.elementInflation.exploration.revealKnownTarget = { _ in
            let current = await self.brains.vault.semanticObservationStream
                .commitDiscoveryObservationForTesting(revealedObservation)
                .current
            XCTAssertEqual(current.scope, .discovery)
            XCTAssertEqual(
                current.snapshot.interface.projectedElements
                    .filter { $0.semantics.assertable.label == "Review PR" }
                    .count,
                2
            )
            guard let currentElement = self.brains.vault.interfaceElement(heistId: "current_priority_one") else {
                return .unavailable
            }
            return .revealed(
                currentElement,
                Navigation.InterfaceExplorationResult(
                    current: current,
                    progress: .init(),
                    didMoveViewport: true,
                    viewportExit: .retained
                )
            )
        }
        defer {
            brains.navigation.elementInflation.exploration.moveViewport = originalMoveViewport
            brains.navigation.elementInflation.exploration.revealKnownTarget = { _ in .unavailable }
        }
        let target = try resolvedTarget(
            .label("Review PR").and(
                .traits([.button]),
                .customContent(.init(label: "Priority", value: "P1"))
            )
        )
        let resultBox = InflationResultBox()
        let inflation = Task { @MainActor in
            resultBox.value = await self.brains.navigation.elementInflation.inflate(
                for: target,
                method: .activate,
                activationPointPolicy: .liveObjectOnly,
                deadline: self.semanticRevealDeadline()
            )
        }
        await waitForSettledSemanticWaiter()
        await installSyntheticObservation(postRevealObservation)
        await inflation.value
        return try XCTUnwrap(resultBox.value)
    }

    private func reviewPRElement(
        priority: String,
        frame: CGRect = CGRect(x: 40, y: 120, width: 240, height: 44)
    ) -> AccessibilityElement {
        .make(
            label: "Review PR",
            traits: .button,
            shape: .frame(AccessibilityRect(frame)),
            customContent: [
                .init(label: "Category", value: "Infrastructure", isImportant: true),
                .init(label: "Priority", value: priority, isImportant: true),
            ]
        )
    }

}

#endif
