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

    func testScrollToVisibleVisibleAmbiguousMatcherFailsClosed() async throws {
        let first = makeElement(label: "Duplicate", traits: .button)
        let second = makeElement(label: "Duplicate", traits: .button)
        let firstEntry = InterfaceTree.Element(
            heistId: "duplicate_1",
            scrollMembership: nil,
            geometry: testGeometry(
                for: first,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: first)
            ),
            element: first
        )
        let secondEntry = InterfaceTree.Element(
            heistId: "duplicate_2",
            scrollMembership: nil,
            geometry: testGeometry(
                for: second,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: second)
            ),
            element: second
        )
        await installSyntheticObservation(
            InterfaceObservation.makeForTests(
            elements: [
                firstEntry.heistId: firstEntry,
                secondEntry.heistId: secondEntry,
            ],
            hierarchy: [
                .element(first, traversalIndex: 0),
                .element(second, traversalIndex: 1),
            ],
            heistIdsByPath: [
                TreePath([0]): firstEntry.heistId,
                TreePath([1]): secondEntry.heistId,
            ],
            firstResponderHeistId: nil,
            )
        )

        let result = await brains.navigation.executeScrollToVisible(
            target: try resolvedScrollToVisibleTarget(
                ScrollToVisibleTarget(target: .label("Duplicate"))
            ),
            deadline: semanticRevealDeadline()
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .scrollToVisible)
        XCTAssertTrue(
            result.message?.contains("element inflation failed [ambiguous]") ?? false,
            "Expected classified ambiguity diagnostic, got \(String(describing: result.message))"
        )
        XCTAssertTrue(
            result.message?.contains("2 elements match") ?? false,
            "Expected ambiguity diagnostic, got \(String(describing: result.message))"
        )
    }

    func testScrollToVisiblePreservesVisibleMatcherOrdinalOutOfRange() async throws {
        let rootView = UIView()
        rootView.backgroundColor = .white
        rootView.addSubview(makeButton(label: "Save", frame: CGRect(x: 40, y: 120, width: 260, height: 44)))

        let window = try installModalWindow(rootView: rootView)
        defer {
            window.rootViewController?.view.accessibilityViewIsModal = false
            window.isHidden = true
        }
        _ = try await publishedVisibleObservation()

        let result = await brains.navigation.executeScrollToVisible(
            target: try resolvedScrollToVisibleTarget(
                ScrollToVisibleTarget(target: .target(.label("Save"), ordinal: 3))
            ),
            deadline: semanticRevealDeadline()
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .scrollToVisible)
        XCTAssertTrue(
            result.message?.contains("ordinal 3 requested") ?? false,
            "Expected ordinal diagnostic, got \(String(describing: result.message))"
        )
    }

    func testScrollToVisibleFailsWhenAdmittedIdentityBecomesAmbiguous() async throws {
        let rootView = UIView()
        let scrollView = AccessibilityRevealingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        let firstTarget = makeAccessibleView(label: "Jump Target", frame: CGRect(x: 40, y: 900, width: 240, height: 44))
        let secondTarget = makeAccessibleView(label: "Jump Target", frame: CGRect(x: 40, y: 960, width: 240, height: 44))
        scrollView.revealedElements = [firstTarget, secondTarget]
        scrollView.updateAccessibilityVisibility()
        scrollView.addSubview(firstTarget)
        scrollView.addSubview(secondTarget)
        rootView.addSubview(scrollView)

        let window = try installModalWindow(rootView: rootView)
        defer {
            window.rootViewController?.view.accessibilityViewIsModal = false
            window.isHidden = true
        }
        _ = try await publishedVisibleObservation()
        let scrollContainerPath = TreePath([0])
        let liveScreen = InterfaceObservation.makeForTests(
            elements: [:],
            hierarchy: [
                .container(
                    makeScrollableContainer(contentSize: scrollView.contentSize, frame: scrollView.frame),
                    children: []
                ),
            ],
            containerRefsByPath: [scrollContainerPath: .init(object: scrollView)],
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: [scrollContainerPath: .init(view: scrollView)]
        )
        await installSyntheticObservation(liveScreen)
        let prematureResolution = brains.vault.resolveTarget(literalTarget(ResolvedElementPredicate.label("Jump Target"), ordinal: 0))
        guard case .notFound = prematureResolution else {
            XCTFail("Parser exposed offscreen scroll content before semantic reveal: \(prematureResolution)")
            return
        }

        let interfaceElement = makeElement(
            label: "Jump Target",
            traits: .button,
            shape: .frame(AccessibilityRect(firstTarget.frame))
        )
        let knownEntry = InterfaceTree.Element(
            heistId: "known_reveal_target",
            scrollMembership: InterfaceTree.ScrollMembership(containerPath: scrollContainerPath, index: nil),
            geometry: HeistElement.Geometry(
                screen: .offscreen,
                view: viewSpace(
                    try ViewPoint(validating: CGPoint(
                        x: firstTarget.frame.midX,
                        y: firstTarget.frame.midY
                    )),
                    ownerPath: scrollContainerPath
                )
            ),
            element: interfaceElement
        )
        let knownElements = liveScreen.tree.elements.merging([knownEntry.heistId: knownEntry]) { _, new in new }
        let knownScreen = InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: knownElements,
                containers: liveScreen.tree.containers,
                viewportCapture: liveScreen.tree.viewportCapture
            ),
            liveCapture: liveScreen.liveCapture
        )
        await installSyntheticObservation(knownScreen)
        let revealedScreen = duplicateRevealObservation(
            knownEntry: knownEntry,
            firstTarget: firstTarget,
            secondTarget: secondTarget,
            scrollView: scrollView,
            containerPath: scrollContainerPath
        )
        let inflation = brains.navigation.elementInflation
        let originalMoveViewport = inflation.exploration.moveViewport
        inflation.exploration.moveViewport = { _, _ in
            self.visibleObservationSource.observation = revealedScreen
            let current = await self.brains.vault.semanticObservationStream
                .commitDiscoveryObservationAfterViewportMovementForTesting(revealedScreen)
                .current
            return Navigation.ViewportTransition(
                outcome: .moved,
                previousVisibleIds: [],
                current: current
            )
        }
        inflation.exploration.discoverTarget = { _, _ in nil }
        defer {
            inflation.exploration.moveViewport = originalMoveViewport
        }

        let result = await inflation.inflate(
            for: try resolvedTarget(.label("Jump Target")),
            method: .scrollToVisible,
            deadline: semanticRevealDeadline()
        )

        guard case .failed(let failure) = result else {
            return XCTFail("Expected uncommitted live identities to fail closed, got \(result)")
        }
        XCTAssertEqual(failure.failedStep, .ambiguous)
        XCTAssertEqual(failure.failureKind, .elementNotFound)
        XCTAssertTrue(failure.message.contains("[ambiguous]"))
    }

    private func duplicateRevealObservation(
        knownEntry: InterfaceTree.Element,
        firstTarget: UIView,
        secondTarget: UIView,
        scrollView: UIScrollView,
        containerPath: TreePath
    ) -> InterfaceObservation {
        let duplicateElement = makeElement(
            label: "Jump Target",
            traits: .button,
            shape: .frame(AccessibilityRect(secondTarget.frame))
        )
        let duplicateEntry = InterfaceTree.Element(
            heistId: "duplicate_reveal_target",
            scrollMembership: .init(containerPath: containerPath, index: nil),
            geometry: testGeometry(
                for: duplicateElement,
                ownerPath: containerPath,
                screen: TheVault.onscreenSpace(for: duplicateElement)
            ),
            element: duplicateElement
        )
        return InterfaceObservation.makeForTests(
            elements: [
                knownEntry.heistId: knownEntry,
                duplicateEntry.heistId: duplicateEntry,
            ],
            hierarchy: [
                .container(
                    makeScrollableContainer(contentSize: scrollView.contentSize, frame: scrollView.frame),
                    children: [
                        .element(knownEntry.element, traversalIndex: 0),
                        .element(duplicateElement, traversalIndex: 1),
                    ]
                ),
            ],
            heistIdsByPath: [
                containerPath.appending(0): knownEntry.heistId,
                containerPath.appending(1): duplicateEntry.heistId,
            ],
            elementRefs: [
                knownEntry.heistId: .init(object: firstTarget, scrollView: scrollView),
                duplicateEntry.heistId: .init(object: secondTarget, scrollView: scrollView),
            ],
            containerRefsByPath: [containerPath: .init(object: scrollView)],
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: [containerPath: .init(view: scrollView)]
        )
    }

}

#endif
