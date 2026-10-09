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

    func testOrdinalOnlyKnownTargetFailsBeforeViewportScan() async throws {
        let duplicate = makeElement(label: "Review PR", traits: .button)
        await installScreenWithOffViewportEntry(
            liveHierarchy: [(makeElement(label: "Overview"), "overview")],
            offViewport: [
                .init(duplicate, heistId: "duplicate_a", scrollContainerPath: TreePath([0])),
                .init(duplicate, heistId: "duplicate_b", scrollContainerPath: TreePath([0])),
            ]
        )
        let selected = try XCTUnwrap(brains.vault.interfaceElement(heistId: "duplicate_b"))
        var scanAttempts = 0
        brains.navigation.elementInflation.exploration.revealKnownTarget = { _ in
            scanAttempts += 1
            return nil
        }

        let state = await brains.navigation.elementInflation.stateAfterReveal(
            selected,
            target: try resolvedTarget(.target(.label("Review PR"), ordinal: 1)),
            deadline: semanticRevealDeadline(),
            resolution: ActionSubjectResolution(origin: .known),
            transaction: .init(vault: brains.vault)
        )

        guard case .failed(let failure) = state else {
            return XCTFail("Expected ordinal-only semantic identity to fail, got \(state)")
        }
        XCTAssertEqual(failure.failedStep, .ambiguous)
        XCTAssertEqual(scanAttempts, 0)
    }

    func testTargetDiscoveryMissDoesNotRevealStaleOffViewportTarget() async throws {
        let staleScrollView = RecordingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        staleScrollView.contentSize = CGSize(width: 320, height: 1_600)
        let staleVisible = makeElement(label: "Root Visible")
        let staleRootButton = makeElement(label: "Controls Demo", traits: .button)
        await installScreenWithOffViewport(
            visible: InterfaceObservation.TestEntry(staleVisible, heistId: "root_visible"),
            offscreen: OffViewportScrollTarget(
                staleRootButton,
                heistId: "stale_controls_button",
                viewActivationPoint: CGPoint(x: 0, y: 1_200),
                scrollView: staleScrollView
            )
        )

        let currentHeader = makeElement(label: "Controls Demo", traits: .header)
        let currentBackButton = makeElement(label: "ButtonHeist Demo", traits: [.button, .backButton])
        let currentScreen = InterfaceObservation.makeForTests(elements: [
            (currentHeader, "current_controls_header"),
            (currentBackButton, "current_back_button"),
        ])
        await installSyntheticObservation(currentScreen)
        var discoveryAttempts = 0
        brains.navigation.elementInflation.exploration.discoverTarget = { _, _ in
            discoveryAttempts += 1
            return nil
        }

        let result = await brains.navigation.elementInflation.inflate(
            for: try resolvedTarget(.label("Controls Demo").and(.traits([.button]))),
            method: .activate,
            deadline: semanticRevealDeadline()
        )

        guard case .failed(let failure) = result else {
            return XCTFail("Expected current-screen target miss, got \(result)")
        }
        XCTAssertEqual(discoveryAttempts, 1)
        XCTAssertEqual(failure.failedStep, .notFound)
        XCTAssertEqual(staleScrollView.setContentOffsetAnimations, [])
        XCTAssertTrue(
            failure.message.contains("traits=[button]"),
            "Expected current semantic miss to preserve the requested button traits, got \(failure.message)"
        )
    }

    func testActionTargetDiscoveryStartsFromCurrentVisibleScreen() async throws {
        let staleVisible = makeElement(label: "Root Visible")
        let staleRootButton = makeElement(label: "Controls Demo", traits: .button)
        let staleRootScreen = makeScreenWithOffViewportEntry(
            liveHierarchy: [(staleVisible, "root_visible")],
            offViewport: [
                InterfaceObservation.OffViewportEntry(
                    staleRootButton,
                    heistId: "stale_controls_button",
                    scrollContainerPath: TreePath([0])
                )
            ]
        )
        await brains.vault.semanticObservationStream.commitDiscoveryObservationForTesting(staleRootScreen)

        let currentHeader = makeElement(label: "Controls Demo", traits: .header)
        let currentBackButton = makeElement(label: "ButtonHeist Demo", traits: [.button, .backButton])
        let currentScreen = InterfaceObservation.makeForTests(elements: [
            (currentHeader, "current_controls_header"),
            (currentBackButton, "current_back_button"),
        ])
        await installSyntheticObservation(currentScreen)

        let discovered = await brains.navigation.elementInflation.exploration.discoverTarget(
            try resolvedTarget(.label("Controls Demo").and(.traits([.button]))),
            semanticRevealDeadline()
        )

        let controls = discovered?.current.snapshot.interface.projectedElements.filter {
            $0.semantics.assertable.label == "Controls Demo"
        } ?? []
        XCTAssertEqual(controls.count, 1)
        XCTAssertTrue(controls[0].semantics.assertable.traits.contains(.header))
        XCTAssertFalse(controls[0].semantics.assertable.traits.contains(.button))
    }

    func testFreshDiscoveryDropsRowsRememberedFromAnEarlierTree() async throws {
        let rootView = UIView()
        rootView.backgroundColor = .white
        let scrollView = AccessibilityRevealingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scrollView.contentSize = CGSize(width: 320, height: 1_200)
        scrollView.revealThreshold = 300

        let visibleWord = UILabel(frame: CGRect(x: 40, y: 80, width: 240, height: 44))
        visibleWord.text = "Words"
        visibleWord.accessibilityLabel = "Words"
        visibleWord.accessibilityTraits = .staticText
        visibleWord.isAccessibilityElement = true

        let discoveredWord = UILabel(frame: CGRect(x: 40, y: 760, width: 240, height: 44))
        discoveredWord.text = "zymurgy"
        discoveredWord.accessibilityLabel = "zymurgy"
        discoveredWord.accessibilityTraits = .staticText
        discoveredWord.isAccessibilityElement = true

        scrollView.revealedElements = [discoveredWord]
        scrollView.updateAccessibilityVisibility()
        scrollView.addSubview(visibleWord)
        scrollView.addSubview(discoveredWord)
        rootView.addSubview(scrollView)

        let window = try installModalWindow(rootView: rootView)
        defer {
            window.rootViewController?.view.accessibilityViewIsModal = false
            window.isHidden = true
        }
        let visibleScreen = try await publishedVisibleObservation()
        let scrollContainerPath = try XCTUnwrap(
            visibleScreen.tree.orderedContainers.compactMap { container -> TreePath? in
                guard container.container.isScrollable else { return nil }
                return container.path
            }.first,
            "Expected the parser to expose the fixture scroll view as a scroll container"
        )

        let staleRootRow = makeElement(label: "Auto-Settle Fixtures", traits: .button)
        let staleEntry = InterfaceTree.Element(
            heistId: "stale_auto_settle_fixtures",
            scrollMembership: InterfaceTree.ScrollMembership(containerPath: scrollContainerPath, index: nil),
            geometry: testGeometry(
                for: staleRootRow,
                ownerPath: scrollContainerPath,
                screen: .offscreen
            ),
            element: staleRootRow
        )
        var staleElements = visibleScreen.tree.elements
        staleElements[staleEntry.heistId] = staleEntry
        let staleScreen = InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: staleElements,
                containers: visibleScreen.tree.containers,
                viewportCapture: visibleScreen.tree.viewportCapture
            ),
            liveCapture: visibleScreen.liveCapture
        )
        await brains.vault.semanticObservationStream.commitDiscoveryObservationForTesting(staleScreen)

        guard let exploration = await brains.navigation.exploreScreen(
            startingFresh: true,
            maxScrollsPerContainer: 3,
            maxScrollsPerDiscovery: 3
        ) else {
            return XCTFail("Expected word-list exploration to settle")
        }
        let labels = try brains.vault.selectInterface(InterfaceQuery()).projectedElements.compactMap {
            $0.semantics.assertable.label
        }
        XCTAssertEqual(exploration.current.scope, .discovery)
        XCTAssertGreaterThan(exploration.progress.scrollCount, 0, "Expected discovery to scroll the word list")
        XCTAssertTrue(labels.contains("Words"), "Expected visible word in discovered interface: \(labels)")
        XCTAssertTrue(labels.contains("zymurgy"), "Expected scrolled word in discovered interface: \(labels)")
        XCTAssertFalse(
            labels.contains("Auto-Settle Fixtures"),
            "A fresh discovery reports the screen as it is now: \(labels)"
        )
    }

    func testDiscoveryCrossesBlankViewportBeforeUnknownTarget() async throws {
        let rootView = UIView()
        rootView.backgroundColor = .white
        let scrollView = AccessibilityRevealingScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 600)
        )
        scrollView.contentSize = CGSize(width: 320, height: 2_200)
        scrollView.revealThreshold = 1_000

        let visible = UILabel(frame: CGRect(x: 40, y: 80, width: 240, height: 44))
        visible.text = "Blank Page Anchor"
        visible.accessibilityLabel = "Blank Page Anchor"
        visible.isAccessibilityElement = true

        let target = UIButton(type: .system)
        target.frame = CGRect(x: 40, y: 1_500, width: 240, height: 44)
        target.setTitle("Beyond Blank Page", for: .normal)
        target.accessibilityLabel = "Beyond Blank Page"
        target.accessibilityTraits = .button
        target.isAccessibilityElement = true

        scrollView.revealedElements = [target]
        scrollView.updateAccessibilityVisibility()
        scrollView.addSubview(visible)
        scrollView.addSubview(target)
        rootView.addSubview(scrollView)

        let window = try installModalWindow(rootView: rootView)
        defer {
            window.rootViewController?.view.accessibilityViewIsModal = false
            window.isHidden = true
        }
        let initialVisualOrigin = Navigation.visualOrigin(in: scrollView)
        _ = try await publishedVisibleObservation()

        guard let exploration = await brains.navigation.exploreScreen(
            target: try resolvedTarget(.label("Beyond Blank Page")),
            startingFresh: true,
            exitPosition: .origin,
            maxScrollsPerContainer: 4,
            maxScrollsPerDiscovery: 4
        ) else {
            return XCTFail("Expected discovery to cross the blank viewport")
        }

        XCTAssertGreaterThanOrEqual(exploration.progress.scrollCount, 2)
        XCTAssertEqual(exploration.viewportExit, .restored)
        let discoveredTarget = try XCTUnwrap(
            exploration.current.snapshot.interface.projectedElements.first {
                $0.semantics.assertable.label == "Beyond Blank Page"
            }
        )
        XCTAssertEqual(discoveredTarget.geometry.screen, .offscreen)
        XCTAssertEqual(
            Navigation.visualOrigin(in: scrollView).y,
            initialVisualOrigin.y,
            accuracy: 0.01
        )
    }

    func testWaitDiscoveryRestoresViewportAfterOffscreenTargetMatch() async throws {
        let rootView = UIView()
        rootView.backgroundColor = .white
        let scrollView = AccessibilityRevealingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scrollView.contentSize = CGSize(width: 320, height: 1_200)
        scrollView.revealThreshold = 300

        let visible = UILabel(frame: CGRect(x: 40, y: 80, width: 240, height: 44))
        visible.text = "Wait Discovery Anchor"
        visible.accessibilityLabel = "Wait Discovery Anchor"
        visible.accessibilityTraits = .staticText
        visible.isAccessibilityElement = true

        let targetButton = UIButton(type: .system)
        targetButton.frame = CGRect(x: 40, y: 760, width: 240, height: 44)
        targetButton.setTitle("Wait Discovery Target", for: .normal)
        targetButton.accessibilityLabel = "Wait Discovery Target"
        targetButton.accessibilityTraits = .button
        targetButton.isAccessibilityElement = true

        scrollView.revealedElements = [targetButton]
        scrollView.updateAccessibilityVisibility()
        scrollView.addSubview(visible)
        scrollView.addSubview(targetButton)
        rootView.addSubview(scrollView)

        let window = try installModalWindow(rootView: rootView)
        defer {
            window.rootViewController?.view.accessibilityViewIsModal = false
            window.isHidden = true
        }
        let initialVisualOrigin = Navigation.visualOrigin(in: scrollView)

        _ = try await publishedVisibleObservation()
        guard let exploration = await brains.navigation.exploreScreen(
            target: try resolvedTarget(.label("Wait Discovery Target")),
            startingFresh: true,
            exitPosition: .origin,
            maxScrollsPerContainer: 3,
            maxScrollsPerDiscovery: 3
        ) else {
            return XCTFail("Expected wait discovery to find the offscreen target")
        }

        let target = try XCTUnwrap(
            exploration.current.snapshot.interface.projectedElements.first {
                $0.semantics.assertable.label == "Wait Discovery Target"
            }
        )
        XCTAssertEqual(exploration.viewportExit, .restored)
        XCTAssertEqual(
            Navigation.visualOrigin(in: scrollView).y,
            initialVisualOrigin.y,
            accuracy: 0.01
        )
        XCTAssertEqual(target.geometry.screen, .offscreen)
    }

    func testPagedHorizontalDiscoveryRestoresStartingPage() async throws {
        let fixture = try await explorationViewport(
            frame: CGRect(x: 0, y: 0, width: 390, height: 300),
            contentSize: CGSize(width: 1_170, height: 300),
            contentOffset: CGPoint(x: 390, y: 0),
            isPagingEnabled: true,
            label: "Page 1"
        )
        defer { fixture.close() }
        let initialOrigin = Navigation.visualOrigin(in: fixture.scrollView)
        fixture.scrollView.onSetContentOffset = { [unowned self] scrollView in
            let requestedX = scrollView.requestedContentOffsets.last?.x ?? scrollView.contentOffset.x
            self.visibleObservationSource.observation = self.explorationObservation(
                label: "Page \(Int((requestedX / 390).rounded()))",
                scrollView: scrollView
            )
        }

        guard let exploration = await exploreViewport(maxScrolls: 8) else {
            return XCTFail("Expected paged discovery to complete")
        }

        XCTAssertEqual(exploration.viewportExit, .restored)
        XCTAssertTrue(exploration.didMoveViewport)
        XCTAssertEqual(Navigation.visualOrigin(in: fixture.scrollView).x, initialOrigin.x, accuracy: 0.01)
    }

    func testExplorationCallbackReceivesCurrentStateAndRestoresOrigin() async throws {
        let fixture = try await explorationViewport()
        defer { fixture.close() }
        publishVerticalOffsetObservations(from: fixture.scrollView)
        var stopRequested = false
        var observedLabels: [String] = []

        guard let exploration = await exploreViewport(onObservation: { current in
            observedLabels += current.snapshot.interface.projectedElements.compactMap {
                $0.semantics.assertable.label
            }
            stopRequested = stopRequested || fixture.scrollView.contentOffset.y > 0
            return stopRequested ? .goalSatisfied : .continue
        }) else {
            return XCTFail("Expected stopped discovery to report its viewport exit")
        }

        XCTAssertTrue(stopRequested)
        XCTAssertTrue(observedLabels.contains("Scrolled"))
        XCTAssertEqual(exploration.viewportExit, .restored)
        XCTAssertEqual(Navigation.visualOrigin(in: fixture.scrollView).y, 0, accuracy: 0.01)
    }

    func testViewportMovementReturnsCommittedPublishedObservation() async throws {
        let fixture = try await explorationViewport()
        defer { fixture.close() }
        publishVerticalOffsetObservations(from: fixture.scrollView)
        let capturesBeforeMovement = visibleObservationSource.captureCount
        let scrollTarget = try XCTUnwrap(
            Navigation.ScrollableTarget.programmatic(fixture.scrollView, in: brains.vault)
        )

        let transition = await brains.navigation.performViewportTransition(
            .page(scrollTarget, direction: .down, animated: false)
        )

        XCTAssertEqual(transition.outcome, .moved)
        XCTAssertGreaterThan(visibleObservationSource.captureCount, capturesBeforeMovement)
        XCTAssertTrue(transition.current?.snapshot.interface.projectedElements.contains {
            $0.semantics.assertable.label == "Scrolled"
        } == true)
        let committed = brains.vault.state.current
        XCTAssertEqual(
            transition.current?.snapshot,
            committed?.snapshot
        )
    }

    func testCancelledBusinessOperationStillCompletesViewportRestoration() async throws {
        let fixture = try await explorationViewport()
        defer { fixture.close() }
        publishVerticalOffsetObservations(from: fixture.scrollView)
        fixture.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        await installSyntheticObservation(explorationObservation(
            label: "Scrolled",
            scrollView: fixture.scrollView
        ))
        let cleanupTask = Task { @MainActor in
            await brains.navigation.performViewportTransition(
                .restoreVisualOrigin(.zero, in: .original(fixture.scrollView)),
                deadline: nil,
                discoveryCommitPolicy: .replaceInterface
            )
        }
        cleanupTask.cancel()
        let cleanup = await cleanupTask.value

        XCTAssertEqual(cleanup.outcome, .moved)
        XCTAssertEqual(Navigation.visualOrigin(in: fixture.scrollView).y, 0, accuracy: 0.01)
        XCTAssertTrue(cleanup.current?.snapshot.interface.projectedElements.contains {
            $0.semantics.assertable.label == "Origin"
        } == true)
    }

    func testExpiredBusinessDeadlineStillCompletesViewportRestoration() async throws {
        let fixture = try await explorationViewport()
        defer { fixture.close() }
        publishVerticalOffsetObservations(from: fixture.scrollView)
        fixture.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        await installSyntheticObservation(explorationObservation(
            label: "Scrolled",
            scrollView: fixture.scrollView
        ))

        let deadline = SemanticObservationDeadline(
            start: RuntimeElapsed.now,
            timeoutSeconds: 0
        )
        let cleanup = await brains.navigation.performViewportTransition(
            .restoreVisualOrigin(.zero, in: .original(fixture.scrollView)),
            deadline: deadline,
            observationBoundary: .externalDeadline(deadline),
            discoveryCommitPolicy: .replaceInterface
        )

        XCTAssertEqual(cleanup.outcome, .moved)
        XCTAssertEqual(Navigation.visualOrigin(in: fixture.scrollView).y, 0, accuracy: 0.01)
    }

    func testCurrentExitRetainsReachedViewport() async throws {
        let fixture = try await explorationViewport()
        defer { fixture.close() }
        publishVerticalOffsetObservations(from: fixture.scrollView, movedLabel: "Reached")

        guard let exploration = await exploreViewport(exitPosition: .current, onObservation: { _ in
            fixture.scrollView.contentOffset.y > 0 ? .goalSatisfied : .continue
        }) else {
            return XCTFail("Expected retained discovery to complete")
        }

        XCTAssertEqual(exploration.viewportExit, .retained)
        XCTAssertGreaterThan(Navigation.visualOrigin(in: fixture.scrollView).y, 0)
    }

    func testScreenReplacementSupersedesOriginWithoutMovingReplacementViewport() async throws {
        let fixture = try await explorationViewport(label: "Original")
        defer { fixture.close() }
        let replacement = RecordingScrollView(frame: fixture.scrollView.frame)
        replacement.contentSize = fixture.scrollView.contentSize
        var replaced = false
        fixture.scrollView.onSetContentOffset = { [unowned self] _ in
            guard !replaced else { return }
            replaced = true
            fixture.scrollView.removeFromSuperview()
            fixture.rootView.addSubview(replacement)
            self.visibleObservationSource.observation = self.explorationObservation(
                label: "Replacement Back",
                traits: [.button, .backButton],
                scrollView: replacement,
                heistId: "replacement_back"
            )
        }

        guard let exploration = await exploreViewport() else {
            return XCTFail("Expected replacement discovery to report supersession")
        }

        XCTAssertTrue(replaced)
        XCTAssertEqual(exploration.viewportExit, .superseded)
        XCTAssertTrue(replacement.requestedContentOffsets.isEmpty)
    }

    func testSemanticOmissionRestoresThroughOriginalViewportEvidence() async throws {
        let fixture = try await explorationViewport()
        defer { fixture.close() }
        fixture.scrollView.onSetContentOffset = { [unowned self] scrollView in
            let requestedY = scrollView.requestedContentOffsets.last?.y ?? scrollView.contentOffset.y
            self.visibleObservationSource.observation = .makeForTests(elements: [
                (
                    self.makeElement(label: requestedY > 0 ? "Viewport Omitted" : "Origin Restored"),
                    HeistId(rawValue: "stable_marker")
                ),
            ])
        }

        guard let exploration = await exploreViewport(onObservation: { _ in
            fixture.scrollView.contentOffset.y > 0 ? .goalSatisfied : .continue
        }) else {
            return XCTFail("Expected weak viewport evidence to restore the omitted semantic target")
        }

        XCTAssertEqual(exploration.viewportExit, .restored)
        XCTAssertGreaterThanOrEqual(fixture.scrollView.requestedContentOffsets.count, 2)
        XCTAssertEqual(Navigation.visualOrigin(in: fixture.scrollView).y, 0, accuracy: 0.01)
    }

    func testRestorationRetriesAfterTransientUnavailableCapture() async throws {
        let fixture = try await explorationViewport()
        defer { fixture.close() }
        fixture.scrollView.onSetContentOffset = { [unowned self] scrollView in
            let requestedY = scrollView.requestedContentOffsets.last?.y
                ?? scrollView.contentOffset.y
            self.visibleObservationSource.observation = self.explorationObservation(
                label: requestedY > 0 ? "Scrolled" : "Origin Restored",
                scrollView: scrollView
            )
            if requestedY == 0 {
                self.visibleObservationSource.failNextCapture()
            }
        }

        guard let exploration = await exploreViewport(onObservation: { _ in
            fixture.scrollView.contentOffset.y > 0 ? .goalSatisfied : .continue
        }) else {
            return XCTFail("Expected restoration to survive one unavailable capture")
        }

        XCTAssertEqual(exploration.viewportExit, .restored)
        XCTAssertEqual(Navigation.visualOrigin(in: fixture.scrollView).y, 0, accuracy: 0.01)
        XCTAssertEqual(
            exploration.current.snapshot.interface.projectedElements.first?
                .semantics.assertable.label,
            "Origin Restored"
        )
    }

    func testRestorationRetryEndsWhenCallerIsCancelled() async throws {
        let fixture = try await explorationViewport()
        defer { fixture.close() }
        fixture.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        visibleObservationSource.observation = nil

        let cleanup = Task { @MainActor in
            await brains.navigation.performViewportTransition(
                .restoreVisualOrigin(.zero, in: .original(fixture.scrollView))
            )
        }
        await waitForSettledSemanticWaiter()
        cleanup.cancel()
        let transition = await cleanup.value

        XCTAssertEqual(transition.outcome, .unavailable)
        XCTAssertEqual(Navigation.visualOrigin(in: fixture.scrollView).y, 0, accuracy: 0.01)
        XCTAssertEqual(brains.vault.semanticObservationStream.observationWaiterCount, 0)
    }

    func testRestorationUsesCurrentViewForUnchangedSemanticContainer() async throws {
        let fixture = try await explorationViewport()
        defer { fixture.close() }
        let replacement = RecordingScrollView(frame: fixture.scrollView.frame)
        replacement.contentSize = fixture.scrollView.contentSize
        var replaced = false
        fixture.scrollView.onSetContentOffset = { [unowned self] scrollView in
            guard !replaced else { return }
            replaced = true
            scrollView.removeFromSuperview()
            fixture.rootView.addSubview(replacement)
            self.visibleObservationSource.observation = self.explorationObservation(
                label: "Origin",
                scrollView: replacement
            )
        }

        guard let exploration = await exploreViewport(onObservation: { _ in
            replaced ? .goalSatisfied : .continue
        }) else {
            return XCTFail("Expected discovery to restore through the replacement view")
        }

        XCTAssertTrue(replaced)
        XCTAssertEqual(exploration.viewportExit, .restored)
        XCTAssertNotNil(replacement.window)
        XCTAssertEqual(Navigation.visualOrigin(in: replacement).y, 0, accuracy: 0.01)
    }

    func testScrollToVisibleDiscoversTargetAboveCurrentViewport() async throws {
        let rootView = UIView()
        rootView.backgroundColor = .white
        let scrollView = AccessibilityRevealingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        scrollView.contentSize = CGSize(width: 320, height: 1_200)
        scrollView.revealMode = .atOrAbove
        scrollView.revealThreshold = 10

        let target = UIButton(type: .system)
        target.setTitle("Top Target", for: .normal)
        target.accessibilityLabel = "Top Target"
        target.accessibilityTraits = .button
        target.isAccessibilityElement = true
        target.frame = CGRect(x: 40, y: 40, width: 240, height: 44)

        let visibleMarker = UILabel(frame: CGRect(x: 40, y: 620, width: 240, height: 44))
        visibleMarker.text = "Visible Marker"
        visibleMarker.accessibilityLabel = "Visible Marker"
        visibleMarker.accessibilityTraits = .staticText
        visibleMarker.isAccessibilityElement = true

        scrollView.revealedElements = [target]
        scrollView.addSubview(target)
        scrollView.addSubview(visibleMarker)
        scrollView.contentOffset = CGPoint(x: 0, y: 520)
        scrollView.updateAccessibilityVisibility()
        rootView.addSubview(scrollView)

        let window = try installModalWindow(rootView: rootView)
        defer {
            window.rootViewController?.view.accessibilityViewIsModal = false
            window.isHidden = true
        }
        _ = try await publishedVisibleObservation()

        let result = await brains.navigation.executeScrollToVisible(
            target: try resolvedScrollToVisibleTarget(
                ScrollToVisibleTarget(target: .label("Top Target"))
            ),
            deadline: semanticRevealDeadline()
        )

        XCTAssertTrue(result.success, "Expected scroll_to_visible to discover the target above; got \(result)")
        XCTAssertLessThanOrEqual(scrollView.contentOffset.y, 10)
        let current = brains.vault.state.current
        let visibleTarget = try XCTUnwrap(
            current?.snapshot.interface.projectedElements.first {
                $0.semantics.assertable.label == "Top Target"
            }
        )
        guard case .onscreen = visibleTarget.geometry.screen else {
            return XCTFail("Expected Top Target to be onscreen after scroll_to_visible")
        }
    }

    func testKnownSemanticRevealIgnoresStaleDetachedScrollView() async throws {
        let staleScrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        staleScrollView.contentSize = CGSize(width: 320, height: 1_600)
        let visible = makeElement(label: "Visible")
        await installSyntheticObservation(.makeForTests(
            elements: [(visible, HeistId(rawValue: "visible_element"))]
        ))

        let result = await brains.navigation.executeScrollToVisible(
            target: try resolvedScrollToVisibleTarget(
                ScrollToVisibleTarget(target: .label("Offscreen"))
            ),
            deadline: semanticRevealDeadline()
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .scrollToVisible)
        XCTAssertEqual(staleScrollView.contentOffset, .zero)
        XCTAssertFalse(
            result.message?.contains("after semantic reveal") ?? false,
            "Detached scroll views should not authorize semantic reveal"
        )
    }

    func testStaleKnownRevealWaitsForSettledRecoveryWithoutRediscovery() async throws {
        brains.tripwire.stopPulse()
        let staleScrollView = RecordingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        staleScrollView.contentSize = CGSize(width: 320, height: 1_600)
        let visible = makeElement(label: "Visible")
        let staleTarget = makeElement(label: "Target")
        await installScreenWithOffViewport(
            visible: InterfaceObservation.TestEntry(visible, heistId: "visible_element"),
            offscreen: OffViewportScrollTarget(
                staleTarget,
                heistId: "target_button",
                viewActivationPoint: CGPoint(x: 0, y: 1_200),
                scrollView: staleScrollView
            )
        )

        let recoveredFrame = CGRect(x: 40, y: 160, width: 240, height: 44)
        let recoveredTarget = AccessibilityElement.make(
            label: "Target",
            traits: .button,
            frame: recoveredFrame
        )
        let recoveredObject = retainedLiveObject()
        let recoveredEntry = InterfaceTree.Element(
            heistId: "target_button",
            scrollMembership: nil,
            geometry: testGeometry(
                for: recoveredTarget,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: recoveredTarget)
            ),
            element: recoveredTarget
        )
        let recoveredScreen = InterfaceObservation.makeForTests(
            elements: [recoveredEntry.heistId: recoveredEntry],
            hierarchy: [.element(recoveredTarget, traversalIndex: 0)],
            heistIdsByPath: [TreePath([0]): recoveredEntry.heistId],
            elementRefs: [
                recoveredEntry.heistId: .init(object: recoveredObject, scrollView: nil)
            ],
            firstResponderHeistId: nil,
        )
        var discoveryAttempts = 0
        brains.navigation.elementInflation.exploration.discoverTarget = { _, _ in
            discoveryAttempts += 1
            return nil
        }

        let target = try resolvedTarget(AccessibilityTarget.label("Target"))
        let resultBox = InflationResultBox()
        let inflation = Task { @MainActor in
            resultBox.value = await self.brains.navigation.elementInflation.inflate(
                for: target,
                method: .scrollToVisible,
                deadline: self.semanticRevealDeadline()
            )
        }
        await waitForSettledSemanticWaiter()
        await brains.vault.semanticObservationStream
            .commitDiscoveryObservationAfterViewportMovementForTesting(
                recoveredScreen
            )
        await waitForSettledSemanticWaiter()
        await installSyntheticObservation(recoveredScreen)

        await inflation.value
        guard case .inflated(let inflatedTarget)? = resultBox.value else {
            return XCTFail("Expected settled observation to recover stale reveal, got \(String(describing: resultBox.value))")
        }
        XCTAssertEqual(discoveryAttempts, 0)
        XCTAssertEqual(staleScrollView.setContentOffsetAnimations, [false])
        XCTAssertEqual(staleScrollView.contentOffset.y, 1_000, accuracy: 0.01)
        XCTAssertEqual(inflatedTarget.treeElement.heistId, recoveredEntry.heistId)
        XCTAssertEqual(inflatedTarget.liveTarget.activationPoint.x, recoveredFrame.midX, accuracy: 0.01)
        XCTAssertEqual(inflatedTarget.liveTarget.activationPoint.y, recoveredFrame.midY, accuracy: 0.01)
    }

    func testKnownTargetWithMissingLiveScrollAncestorRecapturesVisibleActionableTarget() async throws {
        brains.tripwire.stopPulse()
        let targetId: HeistId = "known_coke_button"
        let staleScrollView = RecordingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        staleScrollView.contentSize = CGSize(width: 320, height: 1_600)
        let visible = makeElement(label: "Visible")
        let knownTarget = makeElement(label: "Coke", traits: .button)
        await installScreenWithOffViewport(
            visible: InterfaceObservation.TestEntry(visible, heistId: "visible_element"),
            offscreen: OffViewportScrollTarget(
                knownTarget,
                heistId: targetId,
                viewActivationPoint: CGPoint(x: 160, y: 1_200),
                scrollView: staleScrollView
            ),
            includeLiveScrollAncestor: false
        )

        let comfortZone = ElementInflation.interactionComfortZone
        let recoveredFrame = CGRect(
            x: comfortZone.midX - 100,
            y: comfortZone.midY - 22,
            width: 200,
            height: 44
        )
        let recoveredTarget = AccessibilityElement.make(
            label: "Coke",
            traits: .button,
            frame: recoveredFrame
        )
        let recoveredObject = retainLiveObject(makeButton(label: "Coke", frame: recoveredFrame))
        let scrollContainerPath = TreePath([0])
        let recoveredEntry = InterfaceTree.Element(
            heistId: targetId,
            scrollMembership: InterfaceTree.ScrollMembership(containerPath: scrollContainerPath, index: nil),
            geometry: testGeometry(
                for: recoveredTarget,
                ownerPath: scrollContainerPath,
                screen: TheVault.onscreenSpace(for: recoveredTarget)
            ),
            element: recoveredTarget
        )
        let recoveredScreen = InterfaceObservation.makeForTests(
            elements: [recoveredEntry.heistId: recoveredEntry],
            hierarchy: [
                .container(makeScrollableContainer(), children: [
                    .element(recoveredTarget, traversalIndex: 0)
                ])
            ],
            containerNamesByPath: [scrollContainerPath: "current_drinks_scroll"],
            heistIdsByPath: [scrollContainerPath.appending(0): recoveredEntry.heistId],
            elementRefs: [
                recoveredEntry.heistId: .init(object: recoveredObject, scrollView: nil)
            ],
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: [:]
        )
        let recoveredProjection = TheVault.WireConversion.convert(
            recoveredEntry.element,
            geometry: recoveredEntry.geometry
        )
        XCTAssertEqual(recoveredProjection.semantics.assertable.label, "Coke")
        guard case .onscreen = recoveredProjection.geometry.screen else {
            return XCTFail("Expected recovered Coke target to be onscreen")
        }
        XCTAssertNotNil(recoveredScreen.liveCapture.object(for: recoveredEntry.heistId))
        let target = try resolvedTarget(AccessibilityTarget.label("Coke").and(.traits([.button])))
        var revealAttempts = 0
        brains.navigation.elementInflation.exploration.revealKnownTarget = { request in
            XCTAssertEqual(request.target.target, target)
            revealAttempts += 1
            return nil
        }
        let resultBox = InflationResultBox()
        let inflation = Task { @MainActor in
            resultBox.value = await self.brains.navigation.elementInflation.inflate(
                for: target,
                method: .activate,
                deadline: self.semanticRevealDeadline()
            )
        }
        await waitForSettledSemanticWaiter()
        await installSyntheticObservation(recoveredScreen)
        await waitForSettledSemanticWaiter()
        await installSyntheticObservation(recoveredScreen)
        await inflation.value

        guard case .inflated(let inflatedTarget)? = resultBox.value else {
            return XCTFail("Expected current visible target recovery, got \(String(describing: resultBox.value))")
        }
        XCTAssertEqual(revealAttempts, 0)
        XCTAssertEqual(staleScrollView.setContentOffsetAnimations, [])
        XCTAssertEqual(inflatedTarget.treeElement.heistId, recoveredEntry.heistId)
        XCTAssertEqual(inflatedTarget.liveTarget.activationPoint.x, recoveredFrame.midX, accuracy: 0.01)
        XCTAssertEqual(inflatedTarget.liveTarget.activationPoint.y, recoveredFrame.midY, accuracy: 0.01)
        XCTAssertTrue(inflatedTarget.liveTarget.object === recoveredObject)
        XCTAssertFalse(brains.vault.liveScrollView(for: inflatedTarget.treeElement) === staleScrollView)
    }

    func testScrollReturnsReasonInsteadOfRevealingOffViewportTarget() async throws {
        // Contract: Scroll either reveals the requested target or returns a reason it cannot.
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        let visible = makeElement(label: "Visible")
        let offscreen = makeElement(label: "Offscreen")
        await installScreenWithOffViewport(
            visible: InterfaceObservation.TestEntry(visible, heistId: "visible_element"),
            offscreen: OffViewportScrollTarget(
                offscreen,
                heistId: "offscreen_button",
                viewActivationPoint: CGPoint(x: 0, y: 1_200),
                scrollView: scrollView
            )
        )

        let result = await brains.navigation.executeScroll(
            try resolvedScrollTarget(ScrollTarget(target: .label("Offscreen"), direction: .down)),
            deadline: semanticRevealDeadline()
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .scroll)
        XCTAssertEqual(result.failureKind, .elementNotFound)
        XCTAssertEqual(scrollView.contentOffset, .zero)
        XCTAssertTrue(
            result.message?.contains("exists in the interface tree but is outside the current viewport") == true,
            "Expected offscreen guidance, got \(String(describing: result.message))"
        )
        XCTAssertTrue(result.message?.contains("scroll_to_visible") == true)
    }

    func testScrollToEdgeReturnsReasonInsteadOfRevealingOffViewportTarget() async throws {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        let visible = makeElement(label: "Visible")
        let offscreen = makeElement(label: "Offscreen")
        await installScreenWithOffViewport(
            visible: InterfaceObservation.TestEntry(visible, heistId: "visible_element"),
            offscreen: OffViewportScrollTarget(
                offscreen,
                heistId: "offscreen_button",
                viewActivationPoint: CGPoint(x: 0, y: 1_200),
                scrollView: scrollView
            )
        )

        let result = await brains.navigation.executeScrollToEdge(
            try resolvedScrollToEdgeTarget(
                ScrollToEdgeTarget(target: .label("Offscreen"), edge: .bottom)
            ),
            deadline: semanticRevealDeadline()
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .scrollToEdge)
        XCTAssertEqual(result.failureKind, .elementNotFound)
        XCTAssertEqual(scrollView.contentOffset, .zero)
        XCTAssertTrue(
            result.message?.contains("exists in the interface tree but is outside the current viewport") == true,
            "Expected offscreen guidance, got \(String(describing: result.message))"
        )
        XCTAssertTrue(result.message?.contains("scroll_to_visible") == true)
    }

    private struct ExplorationViewportFixture {
        let rootView: UIView
        let scrollView: RecordingScrollView
        let window: UIWindow

        @MainActor
        func close() {
            window.rootViewController?.view.accessibilityViewIsModal = false
            window.isHidden = true
        }
    }

    private func explorationViewport(
        frame: CGRect = CGRect(x: 0, y: 0, width: 320, height: 300),
        contentSize: CGSize = CGSize(width: 320, height: 900),
        contentOffset: CGPoint = .zero,
        isPagingEnabled: Bool = false,
        label: String = "Origin"
    ) async throws -> ExplorationViewportFixture {
        let rootView = UIView()
        rootView.backgroundColor = .white
        let scrollView = RecordingScrollView(frame: frame)
        scrollView.contentSize = contentSize
        scrollView.contentOffset = contentOffset
        scrollView.isPagingEnabled = isPagingEnabled
        rootView.addSubview(scrollView)
        let window = try installModalWindow(rootView: rootView)
        _ = try await publishedVisibleObservation()
        await installSyntheticObservation(explorationObservation(label: label, scrollView: scrollView))
        return ExplorationViewportFixture(rootView: rootView, scrollView: scrollView, window: window)
    }

    private func publishVerticalOffsetObservations(
        from scrollView: RecordingScrollView,
        movedLabel: String = "Scrolled"
    ) {
        scrollView.onSetContentOffset = { [unowned self] scrollView in
            let requestedY = scrollView.requestedContentOffsets.last?.y ?? scrollView.contentOffset.y
            self.visibleObservationSource.observation = self.explorationObservation(
                label: requestedY > 0 ? movedLabel : "Origin",
                scrollView: scrollView
            )
        }
    }

    private func exploreViewport(
        exitPosition: Navigation.ViewportExitPosition = .origin,
        maxScrolls: Int = 3,
        onObservation: ((TheVault.State.Current) async -> Navigation.ViewportExplorationDecision)? = nil
    ) async -> Navigation.InterfaceExplorationResult? {
        await brains.navigation.exploreScreen(
            startingFresh: true,
            exitPosition: exitPosition,
            maxScrollsPerContainer: maxScrolls,
            maxScrollsPerDiscovery: maxScrolls,
            onObservation: onObservation
        )
    }

    private func explorationObservation(
        label: String,
        traits: UIAccessibilityTraits = .staticText,
        scrollView: UIScrollView,
        heistId: HeistId = "exploration_marker"
    ) -> InterfaceObservation {
        makePlacementScreen(
            targetId: heistId,
            element: makeElement(label: label, traits: traits),
            object: retainedLiveObject(),
            scrollView: scrollView
        )
    }

}

#endif
