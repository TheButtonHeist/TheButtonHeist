#if canImport(UIKit)
import ButtonHeistSupport
import XCTest
import ThePlans
import UIKit
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

@MainActor
final class TheBrainsScrollTests: XCTestCase {

    @MainActor
    final class InflationResultBox {
        var value: ElementInflation.ElementInflationResult?
    }

    var brains: TheBrains!
    var visibleObservationSource: HostedVisibleObservationSource!
    var retainedLiveObjects: [NSObject] = []

    override func setUp() async throws {
        try await super.setUp()
        visibleObservationSource = HostedVisibleObservationSource(
            observation: nil,
            capturesLive: false
        )
        brains = TheBrains(
            tripwire: TheTripwire(),
            visibleObservationSource: visibleObservationSource.capture
        )
        brains.tripwire.startPulse()
        brains.vault.semanticObservationStream.start()
    }

    override func tearDown() async throws {
        brains?.vault.semanticObservationStream.stop()
        brains?.tripwire.stopPulse()
        brains = nil
        visibleObservationSource = nil
        retainedLiveObjects.removeAll()
        try await super.tearDown()
    }

    func retainLiveObject<Object: NSObject>(_ object: Object) -> Object {
        retainedLiveObjects.append(object)
        return object
    }

    func installSyntheticObservation(_ observation: InterfaceObservation) async {
        visibleObservationSource.observation = observation
        await brains.vault.semanticObservationStream
            .commitVisibleObservationForTesting(observation)
    }

    func publishedVisibleObservation() async throws -> InterfaceObservation {
        let outcome = await brains.vault.semanticObservationStream.refreshedVisibleObservation(
            boundary: .cancellation
        )
        let current: TheVault.State.Current? = switch outcome {
        case .committed(let current): current
        case .unavailable: nil
        }
        _ = try XCTUnwrap(current, "Expected a committed visible observation")
        return brains.vault.currentInterfaceObservation
    }

    func retainedLiveObject() -> NSObject {
        retainLiveObject(NSObject())
    }

    func resolvedTarget(
        _ target: AccessibilityTarget
    ) throws -> ResolvedAccessibilityTarget {
        try target.resolve(in: .empty)
    }

    func resolvedScrollTarget(
        _ target: ScrollTarget
    ) throws -> ResolvedScrollTarget {
        try target.resolve(in: .empty)
    }

    func resolvedScrollToEdgeTarget(
        _ target: ScrollToEdgeTarget
    ) throws -> ResolvedScrollToEdgeTarget {
        try target.resolve(in: .empty)
    }

    func resolvedScrollToVisibleTarget(
        _ target: ScrollToVisibleTarget
    ) throws -> ResolvedAccessibilityTarget {
        try resolvedTarget(target.target)
    }

    func viewSpace(
        _ activationPoint: ViewPoint,
        ownerPath: TreePath
    ) -> HeistElement.Geometry.ViewSpace {
        let point = activationPoint.cgPoint
        guard let frame = try? ViewRect(validating: CGRect(
            x: point.x - 1,
            y: point.y - 1,
            width: 2,
            height: 2
        )) else {
            preconditionFailure("Test parent-space frame must be finite")
        }
        return .available(.init(
            ownerPath: ownerPath,
            frame: frame,
            activationPoint: activationPoint
        ))
    }

    func semanticRevealDeadline() -> SemanticObservationDeadline {
        SemanticObservationDeadline(start: RuntimeElapsed.now, timeoutSeconds: 10)
    }

    func waitForSettledSemanticWaiter(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = CFAbsoluteTimeGetCurrent() + 1
        while brains.vault.semanticObservationStream.observationWaiterCount == 0,
              CFAbsoluteTimeGetCurrent() < deadline {
            await Task.yield()
            guard await Task.cancellableSleep(for: .milliseconds(5)) else { break }
        }
        XCTAssertEqual(
            brains.vault.semanticObservationStream.observationWaiterCount,
            1,
            file: file,
            line: line
        )
    }

    // MARK: - Programmatic Scroll Safety

    func testTargetUnavailableScrollFailureMapsToElementNotFoundErrorKind() async {
        let result = TheSafecracker.ActionDispatchResult.failure(
            .scrollToVisible,
            message: "element inflation failed [notFound]: missing",
            failureKind: .targetUnavailable
        )

        guard let failureKind = result.failureKind else {
            return XCTFail("Expected scroll_to_visible failure kind")
        }
        XCTAssertEqual(TheBrains.actionFailureKind(for: failureKind), .elementNotFound)
    }

    func testExploreScreenReturnsNilWhenInitialSettlementIsCancelled() async {
        let explorationTask = Task { @MainActor in
            await brains.navigation.exploreScreen(startingFresh: false) != nil
        }
        explorationTask.cancel()

        let returnedResult = await explorationTask.value

        XCTAssertFalse(returnedResult)
    }

    func testSemanticTargetScanIsUnavailableWhenInitialSettlementIsCancelled() async throws {
        let staleId: HeistId = "stale_action_target"
        await installSyntheticObservation(.makeForTests([
            .init(
                AccessibilityElement.make(label: "Stale action target", traits: .button),
                heistId: staleId
            ),
        ]))
        let selected = try XCTUnwrap(brains.vault.interfaceElement(heistId: staleId))
        let sourceTarget = try resolvedTarget(.label("Stale action target").and(.traits([.button])))
        guard case .admitted(let target) = brains.navigation.elementInflation.admitSemanticTarget(
            sourceTarget,
            selectedElement: selected
        ) else {
            return XCTFail("Expected a portable semantic target")
        }
        let scrollView = UIScrollView()
        let deadline = semanticRevealDeadline()
        let scanTask = Task { @MainActor in
            await brains.navigation.scanForSemanticTarget(.init(
                target: target,
                revealRootScrollViewID: ObjectIdentifier(scrollView),
                deadline: deadline
            ))
        }
        scanTask.cancel()

        guard case .unavailable = await scanTask.value else {
            return XCTFail("Expected cancelled semantic scan to be unavailable")
        }
    }

    func testSemanticTargetScanIsUnavailableWhenDeadlineIsExpired() async throws {
        let targetId: HeistId = "stale_action_target"
        await installSyntheticObservation(.makeForTests([
            .init(
                AccessibilityElement.make(label: "Stale action target", traits: .button),
                heistId: targetId
            ),
        ]))
        let selected = try XCTUnwrap(brains.vault.interfaceElement(heistId: targetId))
        let sourceTarget = try resolvedTarget(.label("Stale action target").and(.traits([.button])))
        guard case .admitted(let target) = brains.navigation.elementInflation.admitSemanticTarget(
            sourceTarget,
            selectedElement: selected
        ) else {
            return XCTFail("Expected a portable semantic target")
        }
        let deadline = SemanticObservationDeadline(
            start: RuntimeElapsed.now,
            timeoutSeconds: 0
        )

        let result = await brains.navigation.scanForSemanticTarget(.init(
            target: target,
            revealRootScrollViewID: ObjectIdentifier(UIScrollView()),
            deadline: deadline
        ))

        guard case .unavailable = result else {
            return XCTFail("Expected expired semantic scan to be unavailable")
        }
    }

    func testOnscreenGeometryCrossingDeadlineDuringFrameAwaitTimesOut() async throws {
        let targetId: HeistId = "geometry_deadline_target"
        let element = makeElement(
            label: "Deadline Target",
            traits: .button,
            shape: .frame(AccessibilityRect(CGRect(x: 40, y: 120, width: 200, height: 44)))
        )
        let object = retainedLiveObject()
        await installSyntheticObservation(
            InterfaceObservation.makeForTests([
            .init(element, heistId: targetId, object: object),
            ])
        )
        let treeElement = try XCTUnwrap(brains.vault.interfaceElement(heistId: targetId))
        guard case .resolved(let liveTarget) = brains.vault.resolveLiveActionTarget(for: treeElement) else {
            return XCTFail("Expected live geometry fixture to resolve")
        }
        let inflation = brains.navigation.elementInflation
        let inflatedTarget = ElementInflation.InflatedElementTarget(
            target: try resolvedTarget(.label("Deadline Target")),
            treeElement: treeElement,
            liveTarget: liveTarget,
            deadline: SemanticObservationDeadline(start: RuntimeElapsed.now, timeoutSeconds: 0),
            resolution: ActionSubjectResolution(origin: .visible)
        )

        let state = await inflation.stateAfterPlacement(
            inflatedTarget,
            method: .activate,
            transaction: ElementInflation.RevealTransaction(vault: brains.vault)
        )

        guard case .failed(let failure) = state else {
            return XCTFail("Expected deadline crossed during frame await to fail, got \(state)")
        }
        XCTAssertEqual(failure.failedStep, .timedOut)
        XCTAssertEqual(failure.failureKind, .timeout)
        let dispatchOutcome = failure.actionDispatchResult(payload: .activate)
        guard let failureKind = dispatchOutcome.failureKind else {
            return XCTFail("Expected timed-out dispatch failure kind")
        }
        XCTAssertEqual(failureKind, .timeout)
        XCTAssertEqual(TheBrains.actionFailureKind(for: failureKind), .timeout)
    }

    func testLiveObjectOnlyDoesNotAwaitGeometryAfterFreshResolution() async throws {
        let targetId: HeistId = "semantic_dispatch_target"
        let element = makeElement(
            label: "Semantic Dispatch Target",
            traits: .button,
            shape: .frame(AccessibilityRect(CGRect(x: 40, y: 120, width: 200, height: 44)))
        )
        let object = retainedLiveObject()
        await installSyntheticObservation(
            InterfaceObservation.makeForTests([
                .init(element, heistId: targetId, object: object),
            ])
        )
        let treeElement = try XCTUnwrap(brains.vault.interfaceElement(heistId: targetId))
        guard case .resolved(let liveTarget) = brains.vault.resolveLiveActionTarget(for: treeElement) else {
            return XCTFail("Expected semantic dispatch fixture to resolve")
        }
        let inflatedTarget = ElementInflation.InflatedElementTarget(
            target: try resolvedTarget(.label("Semantic Dispatch Target")),
            treeElement: treeElement,
            liveTarget: liveTarget,
            deadline: SemanticObservationDeadline(start: RuntimeElapsed.now, timeoutSeconds: 0),
            resolution: ActionSubjectResolution(origin: .visible)
        )

        let state = brains.navigation.elementInflation.stateAfterResolvedFreshTarget(
            inflatedTarget,
            activationPointPolicy: .liveObjectOnly
        )

        guard case .inflated(let resolvedTarget) = state else {
            return XCTFail("Fresh semantic dispatch evidence must not wait for geometry, got \(state)")
        }
        XCTAssertEqual(resolvedTarget.treeElement.heistId, targetId)
        XCTAssertTrue(resolvedTarget.liveTarget.object === object)
    }

    func testExploreScreenSkipsUIPageViewControllerQueuingScrollView() async throws {
        let windowScene = try requireForegroundWindowScene()
        let pageViewController = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        let pages = [
            PageContentViewController(label: "Page One Visible Label"),
            PageContentViewController(label: "Page Two Hidden Label"),
            PageContentViewController(label: "Page Three Hidden Label"),
        ]
        let dataSource = PageDataSource(pages: pages)
        pageViewController.dataSource = dataSource
        pageViewController.setViewControllers([pages[0]], direction: .forward, animated: false)
        pageViewController.view.accessibilityViewIsModal = true

        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 20
        window.rootViewController = pageViewController
        window.frame = UIScreen.main.bounds
        window.isHidden = false

        defer {
            window.isHidden = true
            pageViewController.view.accessibilityViewIsModal = false
        }

        window.layoutIfNeeded()
        visibleObservationSource.useLiveCapture()
        _ = try await publishedVisibleObservation()

        var seenUnsafeTargets = Set<ObjectIdentifier>()
        let unsafeTargets = brains.vault.scrollableContainerViewsByPath.values.filter {
            guard $0.bhIsUnsafeForProgrammaticScrolling else { return false }
            return seenUnsafeTargets.insert(ObjectIdentifier($0)).inserted
        }
        let unsafeOffsets = Dictionary(
            uniqueKeysWithValues: unsafeTargets.map { (ObjectIdentifier($0), $0.contentOffset) }
        )

        guard let exploration = await brains.navigation.exploreScreen() else {
            return XCTFail("Expected UIPageViewController exploration to settle")
        }
        let progress = exploration.progress

        XCTAssertEqual(progress.scrollCount, 0)
        for scrollView in unsafeTargets {
            XCTAssertEqual(Optional(scrollView.contentOffset), unsafeOffsets[ObjectIdentifier(scrollView)])
        }
        XCTAssertTrue(
            exploration.current.snapshot.interface.projectedElements.contains {
                $0.semantics.assertable.label == "Page One Visible Label"
            },
            "Visible page content should remain discoverable without scrolling the private queuing scroll view"
        )
    }

    func testLiveVisibleScreenPreservesDuplicateEqualElementsByPath() async {
        let duplicate = makeElement(label: "Duplicate", traits: .button)
        let firstPath = TreePath([0])
        let secondPath = TreePath([1])
        let firstEntry = InterfaceTree.Element(
            heistId: "duplicate_button_1",
            scrollMembership: nil,
            geometry: testGeometry(
                for: duplicate,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: duplicate)
            ),
            element: duplicate
        )
        let secondEntry = InterfaceTree.Element(
            heistId: "duplicate_button_2",
            scrollMembership: nil,
            geometry: testGeometry(
                for: duplicate,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: duplicate)
            ),
            element: duplicate
        )

        await installSyntheticObservation(
            InterfaceObservation.makeForTests(
            elements: [
                firstEntry.heistId: firstEntry,
                secondEntry.heistId: secondEntry,
            ],
            hierarchy: [
                .element(duplicate, traversalIndex: 0),
                .element(duplicate, traversalIndex: 1),
            ],
            heistIdsByPath: [
                firstPath: firstEntry.heistId,
                secondPath: secondEntry.heistId,
            ],
            elementRefs: [
                firstEntry.heistId: .init(object: NSObject(), scrollView: nil),
                secondEntry.heistId: .init(object: NSObject(), scrollView: nil),
            ],
            firstResponderHeistId: nil,
            )
        )

        XCTAssertEqual(
            brains.vault.currentInterfaceObservation.tree.orderedElements.map(\.heistId),
            [firstEntry.heistId, secondEntry.heistId]
        )
    }

    func testResolveLiveActionTargetFailsClosedWhenWeakObjectIsStale() async {
        let element = makeElement(label: "Detached", traits: .button)
        let entry = InterfaceTree.Element(
            heistId: "detached_button",
            scrollMembership: nil,
            geometry: testGeometry(
                for: element,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: element)
            ),
            element: element
        )
        var object: NSObject? = NSObject()
        await installSyntheticObservation(
            InterfaceObservation.makeForTests(
            elements: [entry.heistId: entry],
            hierarchy: [.element(element, traversalIndex: 0)],
            heistIdsByPath: [TreePath([0]): entry.heistId],
            elementRefs: [entry.heistId: .init(object: object, scrollView: nil)],
            firstResponderHeistId: nil,
            )
        )
        object = nil

        switch brains.vault.resolveLiveActionTarget(for: entry) {
        case .objectUnavailable:
            break
        case .resolved(let target):
            XCTFail("Expected stale weak object to fail closed, got \(target)")
        case .geometryUnavailable:
            XCTFail("Expected stale weak object failure before geometry lookup")
        }
    }

    // MARK: - Known Offscreen Entry

    /// Install a InterfaceObservation whose `elements` includes an entry that's not in the
    /// live hierarchy — simulating an element retained from a previous
    /// exploration commit that has since scrolled off.
    func makeScreenWithOffViewportEntry(
        liveHierarchy: [(AccessibilityElement, HeistId)],
        offViewport: [InterfaceObservation.OffViewportEntry]
    ) -> InterfaceObservation {
        .makeForTests(
            elements: liveHierarchy.map { ($0.0, $0.1) },
            offViewport: offViewport
        )
    }

    func installScreenWithOffViewportEntry(
        liveHierarchy: [(AccessibilityElement, HeistId)],
        offViewport: [InterfaceObservation.OffViewportEntry]
    ) async {
        let observation = makeScreenWithOffViewportEntry(
            liveHierarchy: liveHierarchy,
            offViewport: offViewport
        )
        await installSyntheticObservation(observation)
    }

    struct OffViewportScrollTarget {
        let element: AccessibilityElement
        let heistId: HeistId
        let viewActivationPoint: ViewPoint
        let scrollView: UIScrollView

        init(
            _ element: AccessibilityElement,
            heistId: HeistId,
            viewActivationPoint: CGPoint,
            scrollView: UIScrollView
        ) {
            guard let viewActivationPoint = try? ViewPoint(validating: viewActivationPoint) else {
                preconditionFailure("Test content activation point must be finite")
            }
            self.element = element
            self.heistId = heistId
            self.viewActivationPoint = viewActivationPoint
            self.scrollView = scrollView
        }
    }

    func installScreenWithOffViewport(
        visible: InterfaceObservation.TestEntry,
        offscreen: OffViewportScrollTarget,
        includeLiveScrollAncestor: Bool = true
    ) async {
        let scrollContainerPath = TreePath([0])
        let scrollMembership = InterfaceTree.ScrollMembership(
            containerPath: scrollContainerPath,
            index: nil
        )
        let visibleEntry = InterfaceTree.Element(
            heistId: visible.heistId,
            scrollMembership: scrollMembership,
            geometry: testGeometry(
                for: visible.element,
                ownerPath: scrollContainerPath,
                screen: TheVault.onscreenSpace(for: visible.element)
            ),
            element: visible.element
        )
        let scrollContainer = makeScrollableContainer(
            contentSize: offscreen.scrollView.contentSize,
            frame: offscreen.scrollView.frame
        )
        let containerName: ContainerName = "known_offscreen_scroll"
        let offscreenEntry = InterfaceTree.Element(
            heistId: offscreen.heistId,
            scrollMembership: scrollMembership,
            geometry: HeistElement.Geometry(
                screen: .offscreen,
                view: viewSpace(
                    offscreen.viewActivationPoint,
                    ownerPath: scrollContainerPath
                )
            ),
            element: offscreen.element
        )
        let observation = InterfaceObservation.makeForTests(
            elements: [
                visibleEntry.heistId: visibleEntry,
                offscreenEntry.heistId: offscreenEntry,
            ],
            hierarchy: [
                .container(scrollContainer, children: [
                    .element(visible.element, traversalIndex: 0)
                ])
            ],
            containerNamesByPath: [scrollContainerPath: containerName],
            heistIdsByPath: [scrollContainerPath.appending(0): visible.heistId],
            containerRefsByPath: includeLiveScrollAncestor
                ? [scrollContainerPath: .init(object: offscreen.scrollView)]
                : [:],
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: includeLiveScrollAncestor
                ? [scrollContainerPath: .init(view: offscreen.scrollView)]
                : [:]
        )
        await installSyntheticObservation(observation)
    }

    // MARK: - Helpers

    func makeElement(
        label: String? = nil,
        traits: UIAccessibilityTraits = .none,
        shape: AccessibilityElement.Shape = .frame(AccessibilityRect.zero)
    ) -> AccessibilityElement {
        .make(label: label, traits: traits, shape: shape, respondsToUserInteraction: false)
    }

    func makePlacementScreen(
        targetId: HeistId,
        element: AccessibilityElement,
        object: NSObject,
        scrollView: UIScrollView
    ) -> InterfaceObservation {
        let containerPath = TreePath([0])
        let scrollMembership = InterfaceTree.ScrollMembership(containerPath: containerPath, index: nil)
        let treeElement = InterfaceTree.Element(
            heistId: targetId,
            scrollMembership: scrollMembership,
            geometry: testGeometry(
                for: element,
                ownerPath: containerPath,
                screen: TheVault.onscreenSpace(for: element)
            ),
            element: element
        )
        let container = makeScrollableContainer(
            contentSize: scrollView.contentSize,
            frame: scrollView.frame
        )
        return InterfaceObservation.makeForTests(
            elements: [targetId: treeElement],
            hierarchy: [
                .container(container, children: [
                    .element(element, traversalIndex: 0),
                ]),
            ],
            heistIdsByPath: [containerPath.appending(0): targetId],
            elementRefs: [targetId: .init(object: object, scrollView: scrollView)],
            containerRefsByPath: [containerPath: .init(object: scrollView)],
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: [containerPath: .init(view: scrollView)]
        )
    }

    func makeScrollableContainer(
        contentSize: CGSize = CGSize(width: 320, height: 2000),
        frame: CGRect = CGRect(x: 0, y: 0, width: 320, height: 400)
    ) -> AccessibilityContainer {
        AccessibilityContainer(
            type: .none, scrollableContentSize: AccessibilitySize(contentSize),
            frame: AccessibilityRect(frame)
        )
    }

    func installScrollableContainers(_ containers: [AccessibilityContainer]) async {
        let containerRefs = Dictionary(uniqueKeysWithValues: containers.indices.map { index in
            (TreePath([index]), LiveCapture.ContainerRef(object: retainedLiveObject()))
        })
        let observation = InterfaceObservation.makeForTests(
            elements: [:],
            hierarchy: containers.map { .container($0, children: []) },
            containerRefsByPath: containerRefs,
            firstResponderHeistId: nil,
        )
        await installSyntheticObservation(observation)
    }

    func installLiveScrollTarget(
        _ treeElement: InterfaceTree.Element,
        scrollView: UIScrollView,
        containerName: ContainerName
    ) async {
        let container = makeScrollableContainer(
            contentSize: scrollView.contentSize,
            frame: scrollView.frame
        )
        let observation = InterfaceObservation.makeForTests(
            elements: [treeElement.heistId: treeElement],
            hierarchy: [
                .container(container, children: [
                    .element(treeElement.element, traversalIndex: 0)
                ])
            ],
            containerNamesByPath: [TreePath([0]): containerName],
            heistIdsByPath: [TreePath([0, 0]): treeElement.heistId],
            elementRefs: [
                treeElement.heistId: .init(object: nil, scrollView: scrollView)
            ],
            containerRefsByPath: [TreePath([0]): .init(object: scrollView)],
            firstResponderHeistId: nil,
            scrollableContainerViewsByPath: [
                TreePath([0]): .init(view: scrollView)
            ]
        )
        await installSyntheticObservation(observation)
    }

    func makeButton(label: String, frame: CGRect) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(label, for: .normal)
        button.accessibilityLabel = label
        button.isAccessibilityElement = true
        button.frame = frame
        return button
    }

    func makeAccessibleView(label: String, frame: CGRect) -> UIView {
        let view = UIView(frame: frame)
        view.backgroundColor = .white
        view.accessibilityLabel = label
        view.accessibilityTraits = .button
        view.isAccessibilityElement = true
        return view
    }

    func installModalWindow(rootView: UIView) throws -> UIWindow {
        visibleObservationSource.useLiveCapture()
        let windowScene = try requireForegroundWindowScene()
        let viewController = UIViewController()
        viewController.view = rootView
        viewController.view.frame = UIScreen.main.bounds
        viewController.view.accessibilityViewIsModal = true

        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 30
        window.rootViewController = viewController
        window.frame = UIScreen.main.bounds
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private final class PageDataSource: NSObject, UIPageViewControllerDataSource {
        let pages: [UIViewController]

        init(pages: [UIViewController]) {
            self.pages = pages
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let index = pages.firstIndex(of: viewController),
                  index > 0 else {
                return nil
            }
            return pages[index - 1]
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let index = pages.firstIndex(of: viewController),
                  index < pages.count - 1 else {
                return nil
            }
            return pages[index + 1]
        }
    }

    private final class PageContentViewController: UIViewController {
        private let pageLabel: String

        init(label: String) {
            self.pageLabel = label
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .white

            let label = UILabel()
            label.text = pageLabel
            label.accessibilityLabel = pageLabel
            label.isAccessibilityElement = true
            label.frame = CGRect(x: 40, y: 120, width: 280, height: 44)
            view.addSubview(label)
        }
    }

    enum AccessibilityRevealMode {
        case atOrAbove
        case atOrBelow
    }

    final class AccessibilityRevealingScrollView: UIScrollView {
        var revealedElements: [UIView] = []
        var revealThreshold: CGFloat = 500
        var revealMode: AccessibilityRevealMode = .atOrBelow

        override var contentOffset: CGPoint {
            didSet {
                updateAccessibilityVisibility()
            }
        }

        override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            super.setContentOffset(contentOffset, animated: animated)
            updateAccessibilityVisibility(for: contentOffset)
        }

        func updateAccessibilityVisibility(for offset: CGPoint? = nil) {
            let y = (offset ?? contentOffset).y
            let isRevealed: Bool
            switch revealMode {
            case .atOrAbove:
                isRevealed = y <= revealThreshold
            case .atOrBelow:
                isRevealed = y >= revealThreshold
            }
            for element in revealedElements {
                element.isHidden = !isRevealed
                element.isAccessibilityElement = isRevealed
            }
        }
    }

    final class RecordingScrollView: UIScrollView {
        var setContentOffsetAnimations: [Bool] = []
        var requestedContentOffsets: [CGPoint] = []
        var onSetContentOffset: (@MainActor (RecordingScrollView) -> Void)?

        override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            setContentOffsetAnimations.append(animated)
            requestedContentOffsets.append(contentOffset)
            onSetContentOffset?(self)
            super.setContentOffset(contentOffset, animated: animated)
        }
    }
}

#endif
