#if canImport(UIKit)
import XCTest
import ThePlans

@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

@MainActor
extension ElementInflationProductTests {

    // MARK: - Identity Pinning and Ambiguity

    func testElementInflationRejectsContainerTargetWithTypedResolutionFailure() async throws {
        let result = await brains.navigation.elementInflation.inflate(
            for: try AccessibilityTarget.container(.identifier("content")).resolve(in: .empty),
            method: .activate,
            deadline: SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 10
            )
        )

        guard case .failed(let failure) = result else {
            return XCTFail("Expected container target rejection")
        }
        XCTAssertEqual(failure.failedStep, .targetResolution)
        XCTAssertEqual(failure.targetResolutionFailure, .containerTarget)
    }

    func testAmbiguousSemanticActivateFailsBeforeGeometryOrAction() async throws {
        let fixture = try installAmbiguousActivationFixture()

        let result = await brains.executeRuntimeAction(
            .activate(
                .element(.label("Duplicate"), traits: [.button])
            )
        )

        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(result.outcome.failureKind, .elementNotFound)
        XCTAssertEqual(fixture.first.activationCount, 0)
        XCTAssertEqual(fixture.second.activationCount, 0)
        XCTAssertDiagnostic(result.message, contains: [
            "2 elements match",
            "use ordinal",
        ])
    }

    func testRefreshRetainsSelectedHeistIdWhenPredicateOrderingChanges() async throws {
        let fixture = try installAmbiguousActivationFixture()
        let target = try AccessibilityTarget.target(
            .element(.label("Duplicate"), traits: [.button]),
            ordinal: 0
        ).resolve(in: .empty)
        fixture.second.isHidden = true
        await brains.vault.installObservationForTesting(try observation(for: [fixture.first]))
        visibleObservationSource.useLiveCapture()
        guard case .success(let selected) = brains.navigation.elementInflation.knownSemanticTarget(target) else {
            return XCTFail("Expected the original element to satisfy the committed predicate")
        }
        XCTAssertEqual(selected.heistId, "duplicate_first")

        fixture.second.isHidden = false
        fixture.first.superview?.insertSubview(fixture.second, belowSubview: fixture.first)
        fixture.viewController.view.layoutIfNeeded()
        await brains.vault.installObservationForTesting(try observation(for: [fixture.second, fixture.first]))
        visibleObservationSource.useLiveCapture()

        let state = await brains.navigation.elementInflation.stateAfterRefresh(
            target: target,
            treeElement: selected,
            resolution: ActionSubjectResolution(origin: .visible),
            method: .activate,
            activationPointPolicy: .liveObjectOnly,
            deadline: SemanticObservationDeadline(start: RuntimeElapsed.now, timeoutSeconds: 1)
        )
        guard case .inflated(let inflatedTarget) = state else {
            return XCTFail("Expected refresh to reacquire live evidence for the selected identity, got \(state)")
        }
        XCTAssertEqual(inflatedTarget.treeElement.heistId, "duplicate_first")
        XCTAssertTrue(inflatedTarget.liveTarget.object === fixture.first)

        _ = AccessibilityActionDispatcher().activate(inflatedTarget.liveTarget)

        XCTAssertEqual(fixture.first.activationCount, 1)
        XCTAssertEqual(fixture.second.activationCount, 0)
    }

    func testRefreshFailsClosedWhenSelectedHeistIdIsRemoved() async throws {
        let fixture = try installAmbiguousActivationFixture()
        let target = try AccessibilityTarget.target(
            .element(.label("Duplicate"), traits: [.button]),
            ordinal: 0
        ).resolve(in: .empty)
        fixture.second.isHidden = true
        await brains.vault.installObservationForTesting(try observation(for: [fixture.first]))
        visibleObservationSource.useLiveCapture()
        guard case .success(let selected) = brains.navigation.elementInflation.knownSemanticTarget(target) else {
            return XCTFail("Expected the original element to satisfy the committed predicate")
        }

        fixture.first.removeFromSuperview()
        fixture.second.isHidden = false
        await brains.vault.installObservationForTesting(try observation(for: [fixture.second]))
        visibleObservationSource.useLiveCapture()

        let state = await brains.navigation.elementInflation.stateAfterRefresh(
            target: target,
            treeElement: selected,
            resolution: ActionSubjectResolution(origin: .visible),
            method: .activate,
            activationPointPolicy: .liveObjectOnly,
            deadline: SemanticObservationDeadline(start: RuntimeElapsed.now, timeoutSeconds: 1)
        )
        guard case .failed(let failure) = state else {
            return XCTFail("Expected removed selected identity to fail closed, got \(state)")
        }
        XCTAssertEqual(failure.failedStep, .staleRefresh)
        XCTAssertEqual(failure.failureKind, .elementNotFound)

        XCTAssertEqual(fixture.first.activationCount, 0)
        XCTAssertEqual(fixture.second.activationCount, 0)
    }

    func testSemanticActivateFailsAmbiguousDuplicateBeforeReachabilityChoosesCandidate() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "reachable_duplicate_submit",
            label: "Duplicate Submit"
        )
        try await seedOffViewportTarget(fixture)
        await seedKnownUnreachableDuplicate(
            label: fixture.label,
            identifier: "stale_\(fixture.identifier)",
            heistId: HeistId(rawValue: "stale_\(fixture.knownHeistId.rawValue)")
        )

        let result = await brains.executeRuntimeAction(
            .activate(
                .element(.label(fixture.label), traits: [.button])
            )
        )

        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(result.outcome.failureKind, .elementNotFound)
        XCTAssertEqual(fixture.target.activationCount, 0)
        XCTAssertFalse(fixture.scrollView.didReceiveRevealRequest)
        XCTAssertDiagnostic(result.message, contains: [
            "2 elements match",
            "use ordinal",
        ])
    }

    func testSemanticAdmissionKeepsDuplicateIdentityAcrossVisibilityAndCandidateOrder() async throws {
        let fixture = try installAmbiguousActivationFixture()
        let target = try AccessibilityTarget.element(
            .label("Duplicate"),
            .identifier("duplicate_first"),
            traits: [.button]
        ).resolve(in: .empty)
        let firstVisible = try observation(for: [fixture.first, fixture.second])
        let firstOffscreen = InterfaceObservation.makeForTests(
            tree: firstVisible.tree,
            liveCapture: .makeForTests()
        )

        let before = try await admittedSemanticTarget(target, observation: firstOffscreen)

        fixture.first.superview?.insertSubview(fixture.second, belowSubview: fixture.first)
        fixture.viewController.view.layoutIfNeeded()
        let reorderedVisible = try observation(for: [fixture.second, fixture.first])
        let during = try await admittedSemanticTarget(target, observation: reorderedVisible)
        let after = try await admittedSemanticTarget(
            target,
            observation: InterfaceObservation.makeForTests(
                tree: reorderedVisible.tree,
                liveCapture: .makeForTests()
            )
        )

        XCTAssertEqual(before.target, target)
        XCTAssertEqual(during.target, target)
        XCTAssertEqual(after.target, target)
        XCTAssertNil(before.scrollContainerPath)
        XCTAssertNil(during.scrollContainerPath)
        XCTAssertNil(after.scrollContainerPath)
    }

    private func installAmbiguousActivationFixture() throws -> AmbiguousActivationFixture {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .white
        viewController.view.accessibilityViewIsModal = true

        let first = SemanticActivationView(frame: CGRect(x: 32, y: 120, width: 220, height: 44))
        first.accessibilityLabel = "Duplicate"
        first.accessibilityIdentifier = "duplicate_first"
        first.accessibilityTraits = .button
        first.isAccessibilityElement = true

        let second = SemanticActivationView(frame: CGRect(x: 32, y: 184, width: 220, height: 44))
        second.accessibilityLabel = "Duplicate"
        second.accessibilityIdentifier = "duplicate_second"
        second.accessibilityTraits = .button
        second.isAccessibilityElement = true

        viewController.view.addSubview(first)
        viewController.view.addSubview(second)

        present(viewController, above: true)

        return AmbiguousActivationFixture(
            viewController: viewController,
            first: first,
            second: second
        )
    }
    private func seedKnownUnreachableDuplicate(
        label: String,
        identifier: String,
        heistId: HeistId
    ) async {
        let tree = brains.vault.interfaceTree
        let unreachableElement = makeElement(label: label, identifier: identifier)
        let entry = InterfaceTree.Element(
            heistId: heistId,
            scrollMembership: nil,
            geometry: testGeometry(
                for: unreachableElement,
                ownerPath: .root,
                screen: .offscreen
            ),
            element: unreachableElement
        )
        var elements = tree.elements
        elements[heistId] = entry
        await brains.vault.installObservationForTesting(InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: elements,
                containers: tree.containers,
                viewportCapture: tree.viewportCapture
            ),
            liveCapture: brains.vault.currentInterfaceObservation.liveCapture
        ))
    }
    private func observation(
        for views: [SemanticActivationView]
    ) throws -> InterfaceObservation {
        InterfaceObservation.makeForTests(try views.map { view in
            let label = try XCTUnwrap(view.accessibilityLabel)
            let identifier = try XCTUnwrap(view.accessibilityIdentifier)
            return InterfaceObservation.TestEntry(
                label: label,
                heistId: HeistId(rawValue: identifier),
                identifier: identifier,
                traits: .button,
                frame: view.convert(view.bounds, to: nil),
                object: view
            )
        })
    }

    private func admittedSemanticTarget(
        _ target: ResolvedAccessibilityTarget,
        observation: InterfaceObservation
    ) async throws -> ElementInflation.AdmittedSemanticTarget {
        await brains.vault.installObservationForTesting(observation)
        let resolvedElement: InterfaceTree.Element? = {
            guard case .resolved(.element(let element)) = brains.vault.resolveTarget(target) else {
                return nil
            }
            return element
        }()
        let selected = try XCTUnwrap(resolvedElement)
        let decision = brains.navigation.elementInflation.admitSemanticTarget(
            target,
            selectedElement: selected
        )
        let admittedTarget: ElementInflation.AdmittedSemanticTarget? = {
            guard case .admitted(let admitted) = decision else { return nil }
            return admitted
        }()
        return try XCTUnwrap(admittedTarget, "Expected semantic target admission, got \(decision)")
    }
}

private struct AmbiguousActivationFixture {
    let viewController: UIViewController
    let first: SemanticActivationView
    let second: SemanticActivationView
}

#endif // canImport(UIKit)
