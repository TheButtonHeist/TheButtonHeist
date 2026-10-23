#if canImport(UIKit)
import XCTest
import ThePlans

@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

@MainActor
final class ElementInflationProductTests: ButtonHeistRuntimeTestCase {

    var visibleObservationSource: HostedVisibleObservationSource!

    /// The keyboard the runtime types through.
    ///
    /// A keyboard bound to a live text field cannot exist before the field does,
    /// so a test that needs one sets it and calls `restartRuntime()`.
    var keyboardInput = SafecrackerKeyboardInput()

    override func beforeEach() async throws {
        visibleObservationSource = HostedVisibleObservationSource(
            observation: nil,
            capturesLive: true
        )
    }

    override func makeBrains(tripwire: TheTripwire) throws -> TheBrains {
        TheBrains(
            tripwire: tripwire,
            keyboardInput: keyboardInput,
            visibleObservationSource: visibleObservationSource.capture
        )
    }

    override func afterEach() async throws {
        visibleObservationSource = nil
    }

    func publishedVisibleObservation(
        in runtime: TheBrains? = nil
    ) async throws -> InterfaceObservation {
        let runtime = runtime ?? brains!
        let outcome = await runtime.vault.semanticObservationStream.refreshedVisibleObservation(
            boundary: .cancellation
        )
        let current: TheVault.State.Current? = switch outcome {
        case .committed(let current): current
        case .unavailable: nil
        }
        _ = try XCTUnwrap(current, "Expected a committed visible observation")
        return runtime.vault.currentInterfaceObservation
    }

    func installOffscreenActivationFixture(
        identifier: String,
        label: String,
        nestedInGroup: Bool = false
    ) throws -> SemanticRevealFixture {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .white
        viewController.view.accessibilityViewIsModal = true

        let scrollView = RevealingScrollView(frame: CGRect(x: 24, y: 80, width: 320, height: 280))
        scrollView.contentSize = CGSize(width: 320, height: 1_400)
        scrollView.backgroundColor = .white
        scrollView.isAccessibilityElement = false

        let anchor = UILabel(frame: CGRect(x: 24, y: 24, width: 240, height: 44))
        anchor.text = "Visible Anchor \(identifier)"
        anchor.accessibilityLabel = anchor.text
        anchor.accessibilityIdentifier = "visible_anchor_\(identifier)"
        anchor.isAccessibilityElement = true
        scrollView.addSubview(anchor)

        let target = SemanticActivationView(frame: CGRect(x: 40, y: 900, width: 220, height: 44))
        target.accessibilityLabel = label
        target.accessibilityIdentifier = identifier
        target.accessibilityTraits = .button

        let frameOrigin: CGPoint
        if nestedInGroup {
            let group = UIView(frame: CGRect(x: 24, y: 860, width: 272, height: 120))
            group.accessibilityLabel = "Payment Actions"
            group.accessibilityIdentifier = "payment_actions_\(identifier)"
            group.isAccessibilityElement = false
            target.frame = CGRect(x: 16, y: 40, width: 220, height: 44)
            group.addSubview(target)
            scrollView.addSubview(group)
            frameOrigin = CGPoint(x: group.frame.minX + target.frame.minX, y: group.frame.minY + target.frame.minY)
        } else {
            scrollView.addSubview(target)
            frameOrigin = target.frame.origin
        }

        scrollView.revealedElements = [target]
        scrollView.updateAccessibilityVisibility()
        viewController.view.addSubview(scrollView)

        present(viewController, above: true)

        return SemanticRevealFixture(
            viewController: viewController,
            scrollView: scrollView,
            target: target,
            identifier: identifier,
            label: label,
            knownHeistId: HeistId(rawValue: identifier),
            frameOrigin: frameOrigin
        )
    }

    func rememberTargetOutsideViewport(_ fixture: SemanticRevealFixture) async throws {
        fixture.scrollView.setContentOffset(CGPoint(x: 0, y: 800), animated: false)
        _ = try await publishedVisibleObservation()
        let origin = await brains.navigation.performViewportTransition(
            .restoreContentOffset(.zero, in: .original(fixture.scrollView))
        )
        XCTAssertEqual(origin.outcome, .moved)
    }

    func seedOffViewportTarget(
        _ fixture: SemanticRevealFixture,
        in targetBrains: TheBrains? = nil,
        semanticIdentifier: String? = nil,
        semanticLabel: String? = nil,
        scrollContainerPathOverride: TreePath? = nil,
        refreshesFromUIKit: Bool = true
    ) async throws {
        let targetBrains = targetBrains ?? brains!
        let screen = try await publishedVisibleObservation(in: targetBrains)
        let identifier = semanticIdentifier ?? fixture.identifier
        let label = semanticLabel ?? fixture.label
        let scrollContainerPath: TreePath
        if let scrollContainerPathOverride {
            scrollContainerPath = scrollContainerPathOverride
        } else {
            scrollContainerPath = try XCTUnwrap(
                firstLiveScrollableContainerPath(in: screen),
                "Expected fixture to expose a live scroll container. \(scrollContainerDiagnostics(in: screen))"
            )
        }
        let element = makeElement(
            label: label,
            identifier: identifier,
            frame: CGRect(
                origin: fixture.frameOrigin,
                size: fixture.target.bounds.size
            )
        )
        let viewSpace = try viewSpace(
            origin: fixture.frameOrigin,
            size: fixture.target.bounds.size,
            ownerPath: scrollContainerPath
        )
        let entry = InterfaceTree.Element(
            heistId: fixture.knownHeistId,
            scrollMembership: InterfaceTree.ScrollMembership(containerPath: scrollContainerPath, index: nil),
            geometry: HeistElement.Geometry(screen: .offscreen, view: viewSpace),
            element: element
        )
        var elements = screen.tree.elements
        elements[entry.heistId] = entry

        await targetBrains.vault.semanticObservationStream
            .commitDiscoveryObservationForTesting(InterfaceObservation.makeForTests(
                tree: InterfaceTree(
                    elements: elements,
                    containers: screen.tree.containers,
                    viewportCapture: screen.tree.viewportCapture
                ),
                liveCapture: screen.liveCapture
            ))
        if refreshesFromUIKit, targetBrains === brains {
            visibleObservationSource.useLiveCapture()
        }
    }

    func viewSpace(
        origin: CGPoint,
        size: CGSize,
        ownerPath: TreePath
    ) throws -> HeistElement.Geometry.ViewSpace {
        .available(.init(
            ownerPath: ownerPath,
            frame: try ViewRect(validating: CGRect(origin: origin, size: size)),
            activationPoint: try ViewPoint(validating: CGPoint(
                x: origin.x + size.width / 2,
                y: origin.y + size.height / 2
            ))
        ))
    }
    func firstLiveScrollableContainerPath(in observation: InterfaceObservation) -> TreePath? {
        for item in observation.tree.viewportCapture.hierarchy.scrollablePathIndexedContainers {
            guard observation.liveCapture.scrollView(forContainerPath: item.path) != nil else { continue }
            return item.path
        }
        return nil
    }

    func liveScrollableContainerPath(
        for scrollView: UIScrollView,
        in observation: InterfaceObservation
    ) -> TreePath? {
        let matchingPaths = observation.liveCapture.dispatchReferences.scrollableContainerViewsByPath
            .compactMap { path, ref -> TreePath? in
                guard ref.view === scrollView else { return nil }
                return path
            }
            .sorted { $0.indices.lexicographicallyPrecedes($1.indices) }
        return matchingPaths.first {
            observation.liveCapture.containerObject(forPath: $0) === scrollView
        } ?? matchingPaths.first
    }

    func scrollContainerDiagnostics(in observation: InterfaceObservation) -> String {
        let summaries = observation.tree.viewportCapture.hierarchy.scrollablePathIndexedContainers
            .map { item -> String in
                let name = observation.tree.containers[item.path]?.containerName
                let hasLiveScroll = observation.liveCapture.scrollView(forContainerPath: item.path) != nil
                return "path=\(item.path.indices) name=\(name ?? "<nil>") liveScroll=\(hasLiveScroll)"
            }
        return "scrollContainers=[\(summaries.joined(separator: "; "))]"
    }

    func makeElement(
        label: String,
        identifier: String,
        traits: UIAccessibilityTraits = .button,
        frame: CGRect = CGRect(x: 20, y: 20, width: 160, height: 44)
    ) -> AccessibilityElement {
        .make(
            label: label,
            identifier: identifier,
            traits: traits,
            frame: frame,
            respondsToUserInteraction: true
        )
    }
}

struct SemanticRevealFixture {
    let viewController: UIViewController
    let scrollView: RevealingScrollView
    let target: SemanticActivationView
    let identifier: String
    let label: String
    let knownHeistId: HeistId
    let frameOrigin: CGPoint
}
final class SemanticActivationView: UIView {
    private(set) var activationCount = 0

    override var accessibilityTraits: UIAccessibilityTraits {
        get { super.accessibilityTraits.union(.button) }
        set { super.accessibilityTraits = newValue.union(.button) }
    }

    override func accessibilityActivate() -> Bool {
        activationCount += 1
        return true
    }
}
final class RevealingScrollView: UIScrollView {
    var revealedElements: [UIView] = []
    var revealedContainers: [UIView] = []
    var onFirstRevealRequest: (() -> Void)?
    private(set) var revealRequestCount = 0
    var didReceiveRevealRequest: Bool { revealRequestCount > 0 }
    var revealThreshold: CGFloat = 500

    override var contentOffset: CGPoint {
        didSet {
            updateAccessibilityVisibility()
        }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if contentOffset.y >= revealThreshold {
            if revealRequestCount == 0 {
                onFirstRevealRequest?()
            }
            revealRequestCount += 1
        }
        super.setContentOffset(contentOffset, animated: animated)
        updateAccessibilityVisibility(for: contentOffset)
    }

    func updateAccessibilityVisibility(for offset: CGPoint? = nil) {
        let isRevealed = (offset ?? contentOffset).y >= revealThreshold
        for container in revealedContainers {
            container.isHidden = !isRevealed
            container.accessibilityElementsHidden = !isRevealed
        }
        for element in revealedElements {
            element.isHidden = !isRevealed
            element.isAccessibilityElement = isRevealed
            element.accessibilityElementsHidden = !isRevealed
        }
    }
}

#endif // canImport(UIKit)
