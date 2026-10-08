#if canImport(UIKit)
// Integration tests for whole-heist waits over the semantic accessibility
// observation stream. Requires the BH Demo test host.
import ButtonHeistSupport
import XCTest
import ThePlans
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@testable import TheScore

@MainActor
final class WaitForIntegrationTests: XCTestCase {

    private var insideJob: TheInsideJob!
    private var window: UIWindow!
    private var hostView: UIView!
    private var visibleObservationOverride: InterfaceObservation?
    private var runtimeResources: TheInsideJob.InsideJobRuntimeResources!

    override func setUp() async throws {
        let windowScene = try requireForegroundWindowScene()
        let viewController = UIViewController()
        viewController.view.backgroundColor = .white
        viewController.view.accessibilityViewIsModal = true

        let window = UIWindow(windowScene: windowScene)
        window.frame = UIScreen.main.bounds
        window.windowLevel = .alert + 60
        window.rootViewController = viewController
        window.isHidden = false

        self.window = window
        hostView = viewController.view
        insideJob = try TheInsideJob(
            token: "wait-for-test-token",
            visibleObservationSource: { [weak self] vault in
                self?.visibleObservationOverride ?? TheVault.captureVisibleObservation(from: vault)
            }
        )
        let runtimeResources = TheInsideJob.InsideJobRuntimeResources(
            transport: ServerTransport(token: "wait-for-test-token"),
            actualPort: 0,
            bonjourServiceName: nil,
            idleTimerBaseline: UIApplication.shared.isIdleTimerDisabled
        )
        self.runtimeResources = runtimeResources
        insideJob.activateRuntime()
    }

    override func tearDown() async throws {
        if let insideJob, let runtimeResources {
            insideJob.releaseRuntimeOwnedResources(
                policy: .stop,
                idleTimerBaseline: runtimeResources.idleTimerBaseline
            )
        }
        insideJob = nil
        runtimeResources = nil
        window?.rootViewController?.view.accessibilityViewIsModal = false
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        hostView = nil
        visibleObservationOverride = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func addLabel(_ text: String, identifier: String? = nil, y: CGFloat = 100) -> UILabel {
        let label = UILabel()
        label.text = text
        label.accessibilityLabel = text
        label.isAccessibilityElement = true
        label.frame = CGRect(x: 10, y: y, width: 200, height: 44)
        if let identifier {
            label.accessibilityIdentifier = identifier
        }
        hostView.addSubview(label)
        return label
    }

    private func addButton(_ title: String, y: CGFloat = 100) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityLabel = title
        button.frame = CGRect(x: 10, y: y, width: 200, height: 44)
        button.addAction(UIAction { _ in }, for: .primaryActionTriggered)
        hostView.addSubview(button)
        return button
    }

    private func waitFor(
        target: AccessibilityTarget,
        absent: Bool = false,
        timeout: WaitTimeout? = nil
    ) async throws -> HeistExecutionStepResult? {
        let predicate: AccessibilityPredicate = absent
            ? .missing(target)
            : .exists(target)
        let waitTarget = WaitTarget(predicate: predicate, timeout: timeout)
        let step = WaitStep(
            predicate: waitTarget.predicate,
            timeout: waitTarget.resolvedTimeout
        )
        return try await executeWaitStep(step)
    }

    private func waitFor(
        expectation: AccessibilityPredicate,
        timeout: Double? = nil
    ) async throws -> HeistExecutionStepResult {
        let waitTimeout = try WaitTimeout.seconds(timeout ?? 5.0)
        return try await executeWaitStep(WaitStep(
            predicate: expectation,
            timeout: waitTimeout
        ))
    }

    private func executeWaitStep(_ step: WaitStep) async throws -> HeistExecutionStepResult {
        let result = try await insideJob.brains.executeHeistPlan(
            try HeistPlan(body: [.wait(step)])
        ).get()
        return try XCTUnwrap(result.steps.first, "Expected one wait result")
    }

    private func executeHeistStep(_ step: HeistStep) async throws -> ActionResult {
        let result = try await insideJob.brains.executeHeistPlan(try HeistPlan(body: [step])).get()
        return try XCTUnwrap(
            result.steps.first?.reportActionResult,
            "Expected one heist step result"
        )
    }

    private func waitForObservationDemand(after baseline: Int) async {
        for _ in 0..<1_000 {
            if insideJob.brains.vault.semanticObservationStream.activeObservationDemandCount > baseline {
                return
            }
            await Task.yield()
        }
        XCTFail("Wait did not arm observation demand")
    }

    @discardableResult
    private func waitForVisibleObservation() async -> Bool {
        await insideJob.brains.vault.semanticObservationStream.nextObservation(
            scope: .visible,
            after: nil,
            boundary: .externalDeadline(SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 1
            ))
        ) != nil
    }

    private func mutateVisibleHierarchy(_ body: () -> Void) async {
        body()
        insideJob.brains.vault.semanticObservationStream.invalidateCurrentAdmission()
    }

    private func assertPredicate(
        _ predicate: AccessibilityPredicate,
        isMet expected: Bool,
        in result: HeistExecutionStepResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try assertPredicate(
            predicate,
            isMet: expected,
            in: XCTUnwrap(result.waitEvidence?.observation, file: file, line: line),
            file: file,
            line: line
        )
    }

    private func assertPredicate(
        _ predicate: AccessibilityPredicate,
        isMet expected: Bool,
        in result: ActionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try assertPredicate(
            predicate,
            isMet: expected,
            in: XCTUnwrap(result.observationEvidence, file: file, line: line),
            file: file,
            line: line
        )
    }

    private func assertPredicate(
        _ predicate: AccessibilityPredicate,
        isMet expected: Bool,
        in evidence: Observation.Evidence,
        file: StaticString,
        line: UInt
    ) throws {
        XCTAssertEqual(
            evidence.coverage,
            .complete,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try predicate.resolve(in: .empty).evaluate(in: evidence).met,
            expected,
            file: file,
            line: line
        )
    }

    // MARK: - Passive Observation

    func testPassiveVisibleObservationPublishesStableAXTreeWhileLayerAnimationRuns() async throws {
        let label = addLabel("PassiveObservation-StableAX")
        defer { label.removeFromSuperview() }

        let animatedLayer = CALayer()
        animatedLayer.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        hostView.layer.addSublayer(animatedLayer)
        defer {
            animatedLayer.removeAllAnimations()
            animatedLayer.removeFromSuperlayer()
        }

        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = 0
        animation.toValue = 24
        animation.duration = 10.0
        animation.repeatCount = .infinity
        animatedLayer.add(animation, forKey: "semanticObservationRegressionMotion")

        XCTAssertNotNil(
            animatedLayer.animation(forKey: "semanticObservationRegressionMotion"),
            "Regression setup must keep an unrelated CALayer animation active"
        )

        insideJob.brains.vault.semanticObservationStream.invalidateCurrentAdmission()
        let observation = await insideJob.brains.vault.semanticObservationStream.nextObservation(
            scope: .visible,
            after: nil,
            boundary: .externalDeadline(SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 2
            ))
        )

        let current = try XCTUnwrap(observation)
        XCTAssertTrue(
            current.snapshot.interface.tree.sortedElements.contains {
                $0.label == "PassiveObservation-StableAX"
            },
            "Passive visible observation should publish a stable AX tree even while unrelated layer motion continues"
        )
    }

    // MARK: - 1. Element already present — returns immediately

    func testWaitForAlreadyPresentReturnsImmediately() async throws {
        let label = addLabel("WaitFor-AlreadyPresent")
        defer { label.removeFromSuperview() }

        let response = try await waitFor(
            target: .label("WaitFor-AlreadyPresent"),
            timeout: 5.0
        )
        let result = try XCTUnwrap(response)

        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertNil(result.outcome.failureKind)
        try assertPredicate(
            .exists(.label("WaitFor-AlreadyPresent")),
            isMet: true,
            in: result
        )
    }

    func testActionUsesObservedAccessibilityStateWhileAnimationRemainsActive() async throws {
        let button = addButton("Action-RepeatingAnimation")
        defer { button.removeFromSuperview() }

        let baseline = await insideJob.brains.vault.semanticObservationStream.nextObservation(
            scope: .visible,
            after: nil,
            boundary: .externalDeadline(SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 1
            ))
        )
        XCTAssertNotNil(baseline, "The action fixture must be observable before animation begins")

        UIView.animate(
            withDuration: 0.01,
            delay: 0,
            options: [.autoreverse, .repeat],
            animations: {
                button.alpha = 0.5
            }
        )
        defer { button.layer.removeAllAnimations() }

        let result = try await executeHeistStep(.action(ActionStep(
            command: .activate(.label("Action-RepeatingAnimation")),
            expectationPolicy: .expect(ActionExpectation(
                predicate: .exists(.label("Action-RepeatingAnimation")),
                timeout: try .seconds(1)
            ))
        )))

        XCTAssertTrue(result.outcome.isSuccess, result.message ?? "action failed")
        // The accessibility reading, not the animation, decides whether the
        // expectation is met while the repeat animation remains active.
        try assertPredicate(
            .exists(.label("Action-RepeatingAnimation")),
            isMet: true,
            in: result
        )
        XCTAssertFalse(
            (button.layer.animationKeys() ?? []).isEmpty,
            "The fixture animation must still be running, or this case proves nothing"
        )
    }

    func testWaitForAppearTimeoutReturnsCompleteUnmetEvidence() async throws {
        let label = addLabel("WaitFor-Known-Anchor")
        defer { label.removeFromSuperview() }

        let response = try await waitFor(
            target: .label("WaitFor-Missing-Target"),
            timeout: 1.0
        )
        let result = try XCTUnwrap(response)
        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(result.outcome.failureKind, .timeout)
        try assertPredicate(
            .exists(.label("WaitFor-Missing-Target")),
            isMet: false,
            in: result
        )
        try assertPredicate(
            .exists(.label("WaitFor-Known-Anchor")),
            isMet: true,
            in: result
        )
    }

    func testTimeoutEvidenceExcludesImperceptibleUIKitDescendants() async throws {
        let combined = UIView(frame: CGRect(x: 10, y: 100, width: 240, height: 44))
        combined.isAccessibilityElement = true
        combined.accessibilityLabel = "Ticket saved., Dismiss"
        combined.accessibilityTraits = .staticText
        let inner = UILabel(frame: combined.bounds)
        inner.text = "Ticket saved."
        inner.isAccessibilityElement = true
        combined.addSubview(inner)
        hostView.addSubview(combined)
        defer { combined.removeFromSuperview() }

        let response = try await waitFor(
            target: .label("Ticket saved."),
            timeout: 0.2
        )
        let result = try XCTUnwrap(response)
        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(result.outcome.failureKind, .timeout)
        try assertPredicate(
            .exists(.label("Ticket saved., Dismiss")),
            isMet: true,
            in: result
        )
        try assertPredicate(
            .exists(.label("Ticket saved.")),
            isMet: false,
            in: result
        )
    }

    func testSequentialWaitEvidenceRemainsScopedToEachOperation() async throws {
        let firstObservation = InterfaceObservation.makeForTests(elements: [(
            AccessibilityElement.make(
                label: "First candidate",
                traits: .staticText,
                respondsToUserInteraction: false
            ),
            "first_candidate"
        )])
        visibleObservationOverride = firstObservation
        await insideJob.brains.vault.installObservationForTesting(firstObservation)

        let firstResult = try await waitFor(
            target: .label("Missing candidate"),
            timeout: 0.2
        )
        let first = try XCTUnwrap(firstResult)

        let secondObservation = InterfaceObservation.makeForTests(elements: [(
            AccessibilityElement.make(
                label: "Second candidate",
                traits: .staticText,
                respondsToUserInteraction: false
            ),
            "second_candidate"
        )])
        visibleObservationOverride = secondObservation
        await insideJob.brains.vault.installObservationForTesting(secondObservation)

        let secondResult = try await waitFor(
            target: .label("Missing candidate"),
            timeout: 0.2
        )
        let second = try XCTUnwrap(secondResult)
        try assertPredicate(.exists(.label("First candidate")), isMet: true, in: first)
        try assertPredicate(.exists(.label("Second candidate")), isMet: false, in: first)
        try assertPredicate(.exists(.label("Second candidate")), isMet: true, in: second)
        try assertPredicate(.exists(.label("First candidate")), isMet: false, in: second)
    }

    // MARK: - 3. wait_for absent: true on a present element — should timeout

    func testWaitForAbsentOnPresentElementTimesOut() async throws {
        let label = addLabel("WaitFor-StillHere")
        defer { label.removeFromSuperview() }

        let response = try await waitFor(
            target: .label("WaitFor-StillHere"),
            absent: true,
            timeout: 2.0
        )
        let result = try XCTUnwrap(response)

        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(result.outcome.failureKind, .timeout)
        try assertPredicate(
            .missing(.label("WaitFor-StillHere")),
            isMet: false,
            in: result
        )
    }

    // MARK: - 6. wait_for with heistId vs matcher — both paths resolve

    func testWaitForWithMatcherByIdentifier() async throws {
        let label = addLabel("WaitFor-ById", identifier: "waitfor-test-id")
        defer { label.removeFromSuperview() }

        let response = try await waitFor(
            target: .identifier("waitfor-test-id"),
            timeout: 5.0
        )
        let result = try XCTUnwrap(response)

        XCTAssertTrue(result.outcome.isSuccess)
        try assertPredicate(
            .exists(.identifier("waitfor-test-id")),
            isMet: true,
            in: result
        )
    }

    func testWaitForAbsentTreatsKnownOffViewportElementAsPresent() async throws {
        let visibleElement = AccessibilityElement.make(
            label: "WaitFor-Offscreen-Anchor",
            traits: .staticText,
            respondsToUserInteraction: false
        )
        let offViewportElement = AccessibilityElement.make(
            label: "WaitFor-Offscreen-StillHere",
            traits: .staticText,
            respondsToUserInteraction: false
        )
        let offViewportHeistId: HeistId = "wait_for_offscreen_still_here_staticText"
        let screen = InterfaceObservation.makeForTests(
            elements: [(visibleElement, "wait_for_offscreen_anchor_staticText")],
            offViewport: [.init(offViewportElement, heistId: offViewportHeistId)]
        )
        visibleObservationOverride = screen
        await insideJob.brains.vault.installObservationForTesting(screen)
        XCTAssertTrue(insideJob.brains.semanticObservationIsActive)
        XCTAssertNotNil(insideJob.brains.vault.interfaceTree.findElement(heistId: offViewportHeistId))

        let response = try await waitFor(
            target: .label("WaitFor-Offscreen-StillHere"),
            absent: true,
            timeout: 2.0
        )
        let result = try XCTUnwrap(response)

        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(result.outcome.failureKind, .timeout)
        try assertPredicate(
            .exists(.label("WaitFor-Offscreen-StillHere")),
            isMet: true,
            in: result
        )
        try assertPredicate(
            .missing(.label("WaitFor-Offscreen-StillHere")),
            isMet: false,
            in: result
        )
    }

    // MARK: - Absent already absent returns immediately

    func testWaitForAbsentAlreadyAbsentReturnsImmediately() async throws {
        let response = try await waitFor(
            target: .label("WaitFor-NeverExisted"),
            absent: true,
            timeout: 5.0
        )
        let result = try XCTUnwrap(response)

        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertNil(result.outcome.failureKind)
        try assertPredicate(
            .missing(.label("WaitFor-NeverExisted")),
            isMet: true,
            in: result
        )
    }

    // MARK: - Wait evidence truth

    func testWaitForStatePresentOnNextEventReturnsThroughWaitPath() async throws {
        let baseline = addLabel("WaitForChange-Baseline")
        defer { baseline.removeFromSuperview() }
        let didObserveBaseline = await waitForVisibleObservation()
        XCTAssertTrue(didObserveBaseline)

        var delayedLabel: UILabel?
        defer { delayedLabel?.removeFromSuperview() }
        let baselineDemand = insideJob.brains.vault.semanticObservationStream
            .activeObservationDemandCount
        let mutationTask = Task { @MainActor in
            await self.waitForObservationDemand(after: baselineDemand)
            delayedLabel = self.addLabel("WaitForChange-Delayed")
            self.insideJob.brains.vault.semanticObservationStream.invalidateCurrentAdmission()
        }
        let result = try await waitFor(
            expectation: .exists(.label("WaitForChange-Delayed")),
            timeout: 5.0
        )
        await mutationTask.value

        XCTAssertTrue(result.outcome.isSuccess)
        try assertPredicate(
            .exists(.label("WaitForChange-Delayed")),
            isMet: true,
            in: result
        )
    }

    func testWaitForStateAbsentOnNextEventReturnsThroughWaitPath() async throws {
        let label = addLabel("WaitForChange-Removed")
        let didObserveBaseline = await waitForVisibleObservation()
        XCTAssertTrue(didObserveBaseline)
        XCTAssertTrue(
            insideJob.brains.vault.interfaceTree.orderedElements.contains {
                $0.element.label == "WaitForChange-Removed"
            },
            "Baseline must contain the element before waiting for absence"
        )

        let baselineDemand = insideJob.brains.vault.semanticObservationStream
            .activeObservationDemandCount
        let mutationTask = Task { @MainActor in
            await self.waitForObservationDemand(after: baselineDemand)
            await self.mutateVisibleHierarchy {
                label.removeFromSuperview()
            }
        }
        let result = try await waitFor(
            expectation: .missing(.label("WaitForChange-Removed")),
            timeout: 5.0
        )
        await mutationTask.value

        XCTAssertTrue(result.outcome.isSuccess, result.message ?? "missing wait message")
        try assertPredicate(
            .missing(.label("WaitForChange-Removed")),
            isMet: true,
            in: result
        )
    }

    func testWaitForElementsChangedRequiresFutureElementChange() async throws {
        let changed = addLabel("WaitForChange-ElementsChanged")
        defer { changed.removeFromSuperview() }
        let didObserveBaseline = await waitForVisibleObservation()
        XCTAssertTrue(didObserveBaseline)

        let result = try await waitFor(
            expectation: .elementsChanged,
            timeout: 0.2
        )

        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(result.outcome.failureKind, .timeout)
        try assertPredicate(.elementsChanged, isMet: false, in: result)
    }

    func testWaitForScreenChangedTimesOutWithoutScreenEvent() async throws {
        let label = addLabel("WaitForChange-ScreenChangedTimeout")
        defer { label.removeFromSuperview() }

        let result = try await waitFor(
            expectation: .screenChanged,
            timeout: 0.2
        )
        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(result.outcome.failureKind, .timeout)
        try assertPredicate(.screenChanged, isMet: false, in: result)
        let evidence = try XCTUnwrap(result.observationEvidence)
        XCTAssertFalse(evidence.events.contains {
            if case .screenChanged = $0 { return true }
            return false
        })
    }

    func testWaitForElementUpdatedWithOldValueRequiresObservedUpdate() async throws {
        let label = addLabel("WaitForChange-UpdateOldValue")
        label.accessibilityValue = "Ready"
        defer { label.removeFromSuperview() }

        let result = try await waitFor(
            expectation: .elementsChanged([.updated(
                .label("WaitForChange-UpdateOldValue"),
                .value(before: "Loading", after: "Ready")
            )]),
            timeout: 0.2
        )

        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(result.outcome.failureKind, .timeout)
        try assertPredicate(
            .elementsChanged([.updated(
                .label("WaitForChange-UpdateOldValue"),
                .value(before: "Loading", after: "Ready")
            )]),
            isMet: false,
            in: result
        )
    }

}

private extension HeistExecutionStepResult {
    var outcome: ActionResultOutcome {
        guard status != .passed else { return .success }
        let kind: ActionFailure.Kind = switch failure?.category {
        case .timeout: .timeout
        case .runtimeUnavailable: .accessibilityTreeUnavailable
        case .targetResolution: .elementNotFound
        case .validation: .validationError
        case .internalInvariant,
             .action,
             .expectation,
             .wait,
             .invocation,
             .loop,
             .explicitFailure,
             .none:
            .actionFailed
        }
        return .failure(kind)
    }

    var message: String? { reportMessage }

    var observationEvidence: Observation.Evidence? { waitEvidence?.observation }
}
#endif
