#if canImport(UIKit)
import UIKit
import XCTest
import ThePlans
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

private final class RotorActivationAccessibilityElement: UIAccessibilityElement {
    private(set) var activationCount = 0

    convenience init(container: UIView) {
        self.init(accessibilityContainer: container)
    }

    override func accessibilityActivate() -> Bool {
        activationCount += 1
        return true
    }
}

private final class RotorCustomActionHandler: NSObject {
    private(set) var actionCount = 0

    @objc func archive(_ action: UIAccessibilityCustomAction) -> Bool {
        actionCount += 1
        return true
    }
}

@MainActor
final class TheVaultCustomRotorTests: ButtonHeistTestCase {

    private var vault: TheVault!
    private var tripwire: TheTripwire!

    override func beforeEach() async throws {
        tripwire = TheTripwire()
        vault = TheVault(tripwire: tripwire)
        tripwire.startPulse()
        vault.semanticObservationStream.start()
    }

    override func afterEach() async throws {
        vault.semanticObservationStream.stop()
        tripwire.stopPulse()
        vault = nil
        tripwire = nil
    }

    private func liveTarget(
        for treeElement: InterfaceTree.Element
    ) -> TheVault.LiveActionTarget? {
        guard case .resolved(let liveTarget) = vault.resolveLiveActionTarget(for: treeElement) else {
            return nil
        }
        return liveTarget
    }

    func testRotorNextReturnsParsedLiveResultElement() async throws {
        let rootView = UIView(frame: UIScreen.main.bounds)
        rootView.backgroundColor = .white

        let rotorHost = UIView(frame: CGRect(x: 20, y: 40, width: 280, height: 44))
        rotorHost.isAccessibilityElement = true
        rotorHost.accessibilityLabel = "Validation Results"
        rotorHost.accessibilityIdentifier = "rotor_host"

        let resultLabel = UILabel(frame: CGRect(x: 20, y: 120, width: 280, height: 44))
        resultLabel.text = "Missing amount"
        resultLabel.accessibilityLabel = "Missing amount"
        resultLabel.accessibilityIdentifier = "missing_amount"
        resultLabel.isAccessibilityElement = true

        rotorHost.accessibilityCustomRotors = [
            UIAccessibilityCustomRotor(name: "Errors") { _ in
                UIAccessibilityCustomRotorItemResult(targetElement: resultLabel, targetRange: nil)
            }
        ]

        rootView.addSubview(rotorHost)
        rootView.addSubview(resultLabel)

        present(rotorHost: rootView)

        guard case .committed =
            await vault.semanticObservationStream.refreshedVisibleObservation(
                boundary: .cancellation
            )
        else { return XCTFail("Expected a committed live observation") }

        let resolvedHost = vault.resolveTarget(
            literalTarget(ResolvedElementPredicate.identifier("rotor_host"))
        ).resolvedElement
        guard let resolvedHost else {
            XCTFail("Expected rotor host to resolve")
            return
        }
        let liveHost = try XCTUnwrap(liveTarget(for: resolvedHost))

        let outcome = await vault.performRotor(
            selection: .named("Errors"),
            direction: .next,
            on: liveHost,
            history: vault.admitRotorHistory()
        )

        guard case .succeeded(let hit) = outcome else {
            XCTFail("Expected rotor to succeed, got \(outcome)")
            return
        }
        XCTAssertEqual(hit.rotor, "Errors")
        XCTAssertEqual(hit.treeElement?.element.identifier, "missing_amount")
        XCTAssertEqual(hit.treeElement?.element.label, "Missing amount")
        XCTAssertNil(hit.textRange)
    }

    func testSystemRotorCanBeInvokedByDisplayedName() async throws {
        let rootView = UIView(frame: UIScreen.main.bounds)
        rootView.backgroundColor = .white

        let rotorHost = UIView(frame: CGRect(x: 20, y: 40, width: 280, height: 44))
        rotorHost.isAccessibilityElement = true
        rotorHost.accessibilityLabel = "Resources"
        rotorHost.accessibilityIdentifier = "system_rotor_host"

        let resultLabel = UILabel(frame: CGRect(x: 20, y: 120, width: 280, height: 44))
        resultLabel.text = "Open Docs"
        resultLabel.accessibilityLabel = "Open Docs"
        resultLabel.accessibilityIdentifier = "open_docs"
        resultLabel.isAccessibilityElement = true

        rotorHost.accessibilityCustomRotors = [
            UIAccessibilityCustomRotor(systemType: .link) { _ in
                UIAccessibilityCustomRotorItemResult(targetElement: resultLabel, targetRange: nil)
            }
        ]

        rootView.addSubview(rotorHost)
        rootView.addSubview(resultLabel)

        present(rotorHost: rootView)

        guard case .committed =
            await vault.semanticObservationStream.refreshedVisibleObservation(
                boundary: .cancellation
            )
        else { return XCTFail("Expected a committed live observation") }

        let resolvedHost = vault.resolveTarget(
            literalTarget(ResolvedElementPredicate.identifier("system_rotor_host"))
        ).resolvedElement
        guard let resolvedHost else {
            XCTFail("Expected rotor host to resolve")
            return
        }
        let liveHost = try XCTUnwrap(liveTarget(for: resolvedHost))

        XCTAssertEqual(rotorHost.accessibilityCustomRotors?.first?.name, "")
        XCTAssertEqual(resolvedHost.element.customRotors.map { $0.name }, ["Links"])

        let outcome = await vault.performRotor(
            selection: .named("Links"),
            direction: .next,
            on: liveHost,
            history: vault.admitRotorHistory()
        )

        guard case .succeeded(let hit) = outcome else {
            XCTFail("Expected rotor to succeed, got \(outcome)")
            return
        }
        XCTAssertEqual(hit.rotor, "Links")
        XCTAssertEqual(hit.treeElement?.element.identifier, "open_docs")
    }

    func testRotorReportsMissingRotorName() async throws {
        let host = UIAccessibilityElement(accessibilityContainer: NSObject())
        let frame = CGRect(x: 20, y: 40, width: 280, height: 44)
        host.accessibilityFrame = frame
        let element = AccessibilityElement.make(
            label: "Validation Results",
            identifier: "rotor_host",
            shape: .frame(AccessibilityRect(frame)),
            activationPoint: CGPoint(x: frame.midX, y: frame.midY),
            customRotors: [.init(name: "Warnings", resultMarkers: [], limit: .none)]
        )
        let treeElement = InterfaceTree.Element(
            heistId: "rotor_host",
            scrollMembership: nil,
            geometry: testGeometry(
                for: element,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: element)
            ),
            element: element
        )
        host.accessibilityCustomRotors = [
            UIAccessibilityCustomRotor(name: "Warnings") { _ in nil }
        ]
        await vault.installObservationForTesting(InterfaceObservation.makeForTests(
            elements: [treeElement.heistId: treeElement],
            hierarchy: [.element(element, traversalIndex: 0)],
            heistIdsByPath: [TreePath([0]): treeElement.heistId],
            elementRefs: [
                treeElement.heistId: .init(object: host, scrollView: nil)
            ],
            firstResponderHeistId: nil,
        ))

        let outcome = await vault.performRotor(
            selection: .named("Errors"),
            direction: .next,
            on: try XCTUnwrap(liveTarget(for: treeElement)),
            history: vault.admitRotorHistory()
        )

        guard case .noSuchRotor(let available) = outcome else {
            XCTFail("Expected missing rotor, got \(outcome)")
            return
        }
        XCTAssertEqual(available, ["Warnings"])
    }

}

extension ButtonHeistTestCase {
    /// Puts a rotor host on screen, over the app.
    ///
    /// A rotor is read off the live tree, so the host has to be somewhere the
    /// traversal reaches. Above, because what the app underneath holds is not
    /// this test's subject.
    fileprivate func present(
        rotorHost rootView: UIView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let viewController = UIViewController()
        rootView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        viewController.view.addSubview(rootView)
        present(viewController, above: true, file: file, line: line)
        rootView.frame = viewController.view.bounds
    }
}

/// What a rotor result outside the parsed tree does to a dispatched action.
///
/// This one goes through the runtime rather than the vault, because the claim
/// is about what an action reports. The host is on screen before observation
/// starts, so the baseline the action reads is the tree holding it.
@MainActor
final class RotorActionOutOfTreeResultTests: ButtonHeistRuntimeTestCase {

    private let customActionHandler = RotorCustomActionHandler()
    private var cachedResult: RotorActivationAccessibilityElement!
    private var virtualResult: RotorActivationAccessibilityElement!

    override func beforeEach() async throws {
        let rootView = UIView(frame: UIScreen.main.bounds)
        rootView.backgroundColor = .white

        let rotorHost = UIView(frame: CGRect(x: 20, y: 40, width: 280, height: 44))
        rotorHost.isAccessibilityElement = true
        rotorHost.accessibilityLabel = "Virtual Activation Results"
        rotorHost.accessibilityIdentifier = "virtual_activation_rotor_host"

        let virtualResult = RotorActivationAccessibilityElement(container: rootView)
        virtualResult.accessibilityLabel = "Open virtual result"
        virtualResult.accessibilityTraits = .button
        virtualResult.accessibilityFrameInContainerSpace = CGRect(x: 20, y: 120, width: 280, height: 44)
        virtualResult.accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: "Archive",
                target: customActionHandler,
                selector: #selector(RotorCustomActionHandler.archive(_:))
            )
        ]
        self.virtualResult = virtualResult

        let cachedRotorHost = UIView(frame: CGRect(x: 20, y: 200, width: 280, height: 44))
        cachedRotorHost.isAccessibilityElement = true
        cachedRotorHost.accessibilityLabel = "Cached Results"
        cachedRotorHost.accessibilityIdentifier = "cached_rotor_host"

        let cachedResult = RotorActivationAccessibilityElement(container: rootView)
        cachedResult.accessibilityLabel = "Cached virtual result"
        cachedResult.accessibilityTraits = .button
        cachedResult.accessibilityFrameInContainerSpace = CGRect(x: 20, y: 260, width: 280, height: 44)
        self.cachedResult = cachedResult

        cachedRotorHost.accessibilityCustomRotors = [
            UIAccessibilityCustomRotor(name: "Cached Items") { _ in
                UIAccessibilityCustomRotorItemResult(targetElement: cachedResult, targetRange: nil)
            }
        ]

        rotorHost.accessibilityCustomRotors = [
            UIAccessibilityCustomRotor(name: "Primary Action") { _ in
                UIAccessibilityCustomRotorItemResult(targetElement: virtualResult, targetRange: nil)
            }
        ]

        rootView.addSubview(rotorHost)
        rootView.addSubview(cachedRotorHost)
        present(rotorHost: rootView)
    }

    func testRotorResultDoesNotResolveCachedSemanticElementOutsideParsedHierarchy() async throws {
        guard case .committed =
            await brains.vault.semanticObservationStream.refreshedVisibleObservation(
                boundary: .cancellation
            )
        else { return XCTFail("Expected a committed live observation") }
        let observation = brains.vault.currentInterfaceObservation

        let cachedHeistId = HeistId(rawValue: "cached_virtual_result")
        var elements = observation.tree.elements
        let cachedElement = AccessibilityElement.make(
            label: "Cached virtual result",
            identifier: cachedHeistId.rawValue,
            traits: .button,
            frame: CGRect(x: 20, y: 260, width: 280, height: 44)
        )
        elements[cachedHeistId] = InterfaceTree.Element(
            heistId: cachedHeistId,
            scrollMembership: nil,
            geometry: testGeometry(
                for: cachedElement,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: cachedElement)
            ),
            element: cachedElement
        )
        await brains.vault.installObservationForTesting(InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: elements,
                containers: observation.tree.containers,
                viewportCapture: observation.tree.viewportCapture
            ),
            liveCapture: observation.liveCapture
        ))

        var timing = ActionTiming()
        let search = await brains.actions.executeRotor(
            selection: .named("Cached Items"),
            target: literalTarget(ResolvedElementPredicate.identifier("cached_rotor_host")),
            direction: .next,
            deadline: SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 10
            ),
            timing: &timing
        )

        XCTAssertFalse(search.success)
        XCTAssertTrue(
            search.message?.contains("returned a target outside the parsed hierarchy") == true,
            search.message ?? "<nil>"
        )
        XCTAssertEqual(search.payload, .rotor(nil))
        XCTAssertEqual(cachedResult.activationCount, 0)
    }

    func testOutOfTreeRotorResultFailsInsteadOfCreatingHiddenContinuationState() async throws {
        let searchResult = await brains.executeRuntimeAction(.rotor(
            selection: .named("Primary Action"),
            target: .identifier("virtual_activation_rotor_host"),
            direction: .next
        ))

        XCTAssertFalse(searchResult.outcome.isSuccess)
        XCTAssertEqual(searchResult.method, .rotor)
        XCTAssertTrue(
            searchResult.message?.contains("returned a target outside the parsed hierarchy") == true,
            searchResult.message ?? "<nil>"
        )
        XCTAssertEqual(searchResult.payload, .rotor(nil))
        XCTAssertEqual(virtualResult.activationCount, 0)
        XCTAssertEqual(customActionHandler.actionCount, 0)
    }
}

#endif
