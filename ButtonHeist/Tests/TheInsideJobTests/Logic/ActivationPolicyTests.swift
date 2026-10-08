#if canImport(UIKit)
import XCTest
import ThePlans
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@testable import TheScore

@MainActor
final class ActivationPolicyTests: XCTestCase {

    private final class ActivationObject: NSObject {}

    private final class DecliningActivationObject: NSObject {
        override func accessibilityActivate() -> Bool { false }
    }

    func testElementInflationFailureMapsNoRevealPathToCommandMethod() async {
        let result = ElementInflation.ElementInflationFailure.noRevealPath("target has no reveal path")
            .actionDispatchResult(payload: .activate)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(result.message, "element inflation failed [noRevealPath]: target has no reveal path")
    }

    func testElementInflationFailurePreservesElementNotFoundMethod() async {
        let result = ElementInflation.ElementInflationFailure.notFound("no such element")
            .actionDispatchResult(payload: .activate)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(result.failureKind, .elementNotFound)
        XCTAssertEqual(result.message, "element inflation failed [notFound]: no such element")
    }

    func testElementInflationCancellationPreservesTypedTerminalFailure() async {
        let failure = ElementInflation.ElementInflationFailure.cancelled(
            "stale live target refresh was cancelled after the live target no longer matched"
        )

        XCTAssertEqual(failure.failedStep, .cancelled)
        XCTAssertEqual(failure.failureKind, .actionFailed)
        XCTAssertEqual(
            failure.message,
            "element inflation failed [cancelled]: stale live target refresh was cancelled "
                + "after the live target no longer matched"
        )
        let result = failure.actionDispatchResult(payload: .activate)
        XCTAssertEqual(result.method, .activate)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failureKind, .actionFailed)
    }

    func testSemanticActivationSuccessDoesNotResolveOnscreenFallback() async throws {
        let refreshedTarget = await makeLiveTarget(
            heistId: "refreshed",
            label: "Refreshed Target",
            activationPoint: CGPoint(x: 30, y: 1_400)
        )
        var events: [String] = []
        var dispatchedPoints: [CGPoint] = []
        var fingerprintPoints: [CGPoint] = []
        let inflatedTarget = try makeInflatedTarget(
            refreshedTarget,
            resolution: ActionSubjectResolution(
                origin: .known,
                adjustments: [.semanticReveal, .staleTargetRefresh]
            )
        )

        let result = await makePolicy(
            semanticTarget: inflatedTarget,
            accessibilityActivate: { target in
                events.append("activate:\(target.treeElement.heistId)")
                return .success
            },
            resolveOnscreenFallbackTarget: {
                events.append("onscreen-fallback")
                return .failure(.failure(.activate, message: "unexpected fallback resolution"))
            },
            tapActivationPoint: { point in
                dispatchedPoints.append(point)
                return true
            },
            showFingerprint: { point in
                fingerprintPoints.append(point)
            }
        ).apply()

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(events, ["activate:refreshed"])
        XCTAssertTrue(dispatchedPoints.isEmpty)
        XCTAssertEqual(fingerprintPoints, [CGPoint(x: 30, y: 1_400)])
        XCTAssertEqual(
            result.activationTrace,
            ActivationTrace(.accessibilityActivate(axActivateReturned: true))
        )
        XCTAssertEqual(
            result.subjectEvidence?.resolution,
            ActionSubjectResolution(
                origin: .known,
                adjustments: [.semanticReveal, .staleTargetRefresh]
            )
        )
        XCTAssertEqual(
            result.subjectEvidence?.element.semantics.assertable.label,
            "Refreshed Target"
        )
    }

    func testRefusedActivationResolvesFreshOnscreenTargetBeforeOneFallbackTap() async throws {
        let semanticTarget = await makeLiveTarget(
            heistId: "semantic",
            label: "Semantic Target",
            activationPoint: CGPoint(x: 30, y: 1_400)
        )
        let fallbackTarget = await makeLiveTarget(
            heistId: "fallback",
            label: "Fallback Target",
            activationPoint: CGPoint(x: 30, y: 40)
        )
        var activateCount = 0
        var activationPointDispatches = 0
        var dispatchedPoints: [CGPoint] = []
        var events: [String] = []
        let semanticInflatedTarget = try makeInflatedTarget(semanticTarget)
        let fallbackInflatedTarget = try makeInflatedTarget(fallbackTarget)

        let result = await makePolicy(
            semanticTarget: semanticInflatedTarget,
            accessibilityActivate: { target in
                activateCount += 1
                events.append("activate:\(target.treeElement.heistId)")
                return .refused
            },
            resolveOnscreenFallbackTarget: {
                events.append("onscreen-fallback")
                return .resolved(fallbackInflatedTarget)
            },
            tapActivationPoint: { point in
                activationPointDispatches += 1
                dispatchedPoints.append(point)
                return true
            }
        ).apply()

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(activateCount, 1)
        XCTAssertEqual(activationPointDispatches, 1)
        XCTAssertEqual(dispatchedPoints, [CGPoint(x: 30, y: 40)])
        XCTAssertEqual(events, ["activate:semantic", "onscreen-fallback"])
        XCTAssertEqual(result.subjectEvidence?.element.semantics.assertable.label, "Fallback Target")
        XCTAssertEqual(result.activationTrace, ActivationTrace(.activationPointFallback(
            axActivateReturned: false,
            tapActivationPoint: ScreenPoint(x: 30, y: 40),
            tapActivationSucceeded: true
        ), implementsAccessibilityActivation: false))
    }

    func testRefusedActivationReturnsFallbackResolutionFailureWithoutTap() async throws {
        let semanticTarget = await makeLiveTarget(
            heistId: "semantic",
            label: "Semantic Target",
            activationPoint: CGPoint(x: 30, y: 1_400)
        )
        let semanticInflatedTarget = try makeInflatedTarget(semanticTarget)
        var events: [String] = []
        var dispatchedPoints: [CGPoint] = []

        let result = await makePolicy(
            semanticTarget: semanticInflatedTarget,
            accessibilityActivate: { _ in
                events.append("activate")
                return .refused
            },
            resolveOnscreenFallbackTarget: {
                events.append("onscreen-fallback")
                return .failure(.failure(
                    .activate,
                    message: "element inflation failed [noRevealPath]: target has no reveal path"
                ))
            },
            tapActivationPoint: { point in
                dispatchedPoints.append(point)
                return true
            }
        ).apply()

        XCTAssertFalse(result.success)
        XCTAssertEqual(
            result.message,
            "element inflation failed [noRevealPath]: target has no reveal path"
        )
        XCTAssertEqual(events, ["activate", "onscreen-fallback"])
        XCTAssertTrue(dispatchedPoints.isEmpty)
        XCTAssertEqual(
            result.subjectEvidence?.element.semantics.assertable.label,
            "Semantic Target"
        )
        XCTAssertEqual(
            result.activationTrace,
            ActivationTrace(.accessibilityActivate(axActivateReturned: false))
        )
    }

    func testSemanticDispatchStalenessDoesNotAdmitMechanicalFallback() async throws {
        let semanticTarget = await makeLiveTarget(
            heistId: "semantic",
            label: "Semantic Target",
            activationPoint: CGPoint(x: 30, y: 40)
        )
        let semanticInflatedTarget = try makeInflatedTarget(semanticTarget)
        var fallbackResolutionCount = 0
        var dispatchedPoints: [CGPoint] = []

        let result = await ActivationPolicy(
            semanticTarget: semanticInflatedTarget,
            accessibilityActivate: { _ in
                .failure(.objectUnavailable("semantic"))
            },
            resolveOnscreenFallbackTarget: {
                fallbackResolutionCount += 1
                return .resolved(semanticInflatedTarget)
            },
            tapActivationPoint: { point in
                dispatchedPoints.append(point)
                return true
            },
            showFingerprint: { _ in },
            textEntryActivationFailure: { _, _ in nil }
        ).apply()

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failureKind, .elementNotFound)
        XCTAssertEqual(
            result.message,
            "Live target semantic has no current UIKit object at dispatch"
        )
        XCTAssertEqual(fallbackResolutionCount, 0)
        XCTAssertTrue(dispatchedPoints.isEmpty)
        XCTAssertEqual(result.activationTrace, ActivationTrace(.refreshFailed))
        XCTAssertEqual(
            result.subjectEvidence?.element.semantics.assertable.label,
            "Semantic Target"
        )
    }

    func testTextEntryActivationPointDispatchRequiresFocusConfirmation() async throws {
        let refreshedTarget = await makeLiveTarget(
            heistId: "refreshed",
            traits: .textEntry,
            activationPoint: CGPoint(x: 30, y: 40)
        )
        var focusConfirmationTrace: ActivationTrace?
        let inflatedTarget = try makeInflatedTarget(refreshedTarget)

        let result = await makePolicy(
            semanticTarget: inflatedTarget,
            accessibilityActivate: { _ in .refused },
            tapActivationPoint: { _ in true },
            textEntryActivationFailure: { _, trace in
                focusConfirmationTrace = trace
                return .failure(.activate, message: "text entry did not focus", activationTrace: trace)
            }
        ).apply()

        let expectedTrace = ActivationTrace(.activationPointFallback(
            axActivateReturned: false,
            tapActivationPoint: ScreenPoint(x: 30, y: 40),
            tapActivationSucceeded: true
        ), implementsAccessibilityActivation: false)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.message, "text entry did not focus")
        XCTAssertEqual(result.activationTrace, expectedTrace)
        XCTAssertEqual(focusConfirmationTrace, expectedTrace)
    }

    func testNonTextEntryActivationPointDispatchDoesNotRequireFocusConfirmation() async throws {
        let refreshedTarget = await makeLiveTarget(
            heistId: "refreshed",
            traits: .button,
            activationPoint: CGPoint(x: 30, y: 40)
        )
        var focusConfirmationCount = 0
        let inflatedTarget = try makeInflatedTarget(refreshedTarget)

        let result = await makePolicy(
            semanticTarget: inflatedTarget,
            accessibilityActivate: { _ in .refused },
            tapActivationPoint: { _ in true },
            textEntryActivationFailure: { _, _ in
                focusConfirmationCount += 1
                return .failure(.activate, message: "unexpected focus confirmation")
            }
        ).apply()

        XCTAssertTrue(result.success)
        XCTAssertEqual(focusConfirmationCount, 0)
    }

    func testFinalFailureUsesRefreshedTargetAndFreshActivationPoint() async throws {
        let refreshedTarget = await makeLiveTarget(
            heistId: "refreshed",
            label: "Refreshed Button",
            traits: .button,
            frame: CGRect(x: 12, y: 30, width: 80, height: 44),
            activationPoint: CGPoint(x: 52, y: 52),
            object: DecliningActivationObject()
        )
        var activateCount = 0
        var dispatchedPoints: [CGPoint] = []
        let inflatedTarget = try makeInflatedTarget(
            refreshedTarget,
            resolution: ActionSubjectResolution(
                origin: .discovered,
                adjustments: [.objectDeallocationRefresh]
            )
        )

        let result = await makePolicy(
            semanticTarget: inflatedTarget,
            accessibilityActivate: { _ in
                activateCount += 1
                return .refused
            },
            tapActivationPoint: { point in
                dispatchedPoints.append(point)
                return false
            }
        ).apply()

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(
            result.subjectEvidence?.resolution,
            ActionSubjectResolution(
                origin: .discovered,
                adjustments: [.objectDeallocationRefresh]
            )
        )
        XCTAssertEqual(
            result.subjectEvidence?.element.semantics.assertable.label,
            "Refreshed Button"
        )
        XCTAssertEqual(activateCount, 1)
        XCTAssertEqual(dispatchedPoints, [CGPoint(x: 52, y: 52)])
        XCTAssertEqual(result.activationTrace, ActivationTrace(.activationPointFallback(
            axActivateReturned: false,
            tapActivationPoint: ScreenPoint(x: 52, y: 52),
            tapActivationSucceeded: false
        ), implementsAccessibilityActivation: true))
        XCTAssertDiagnostic(result.message, contains: [
            "activate failed: accessibilityActivate() declined after semantic refresh",
            "activation-point dispatch was attempted at the fresh accessibility activation point",
            "label=\"Refreshed Button\"",
            "actions=[activate]",
            "activationImplementation=present",
            "likelyConditionalState=true",
            "correction: target an element with primary accessibility activation",
        ])
        XCTAssertDiagnostic(result.message, doesNotContain: [
            "fall" + "back",
            "re" + "covery",
            "synthetic " + "tap",
            "synthetic" + "Tap",
        ])
    }

    private func makePolicy(
        semanticTarget: ElementInflation.InflatedElementTarget,
        accessibilityActivate: @escaping @MainActor (TheVault.LiveActionTarget) -> AccessibilityActionDispatcher.ActivateOutcome,
        resolveOnscreenFallbackTarget: (@MainActor () async -> ActivationRefreshResult)? = nil,
        tapActivationPoint: @escaping @MainActor (CGPoint) async -> Bool,
        showFingerprint: @escaping @MainActor (CGPoint) -> Void = { _ in },
        textEntryActivationFailure: @escaping @MainActor (
            InterfaceTree.Element,
            ActivationTrace
        ) async -> TheSafecracker.ActionDispatchResult? = { _, _ in nil }
    ) -> ActivationPolicy {
        ActivationPolicy(
            semanticTarget: semanticTarget,
            accessibilityActivate: { target in
                .success(ActivationDispatchEvidence(
                    outcome: accessibilityActivate(target),
                    activationPoint: target.activationPoint
                ))
            },
            resolveOnscreenFallbackTarget: resolveOnscreenFallbackTarget ?? {
                .resolved(semanticTarget)
            },
            tapActivationPoint: tapActivationPoint,
            showFingerprint: showFingerprint,
            textEntryActivationFailure: { treeElement, trace in
                guard treeElement.element.traits.contains(.textEntry) else { return nil }
                return await textEntryActivationFailure(treeElement, trace)
            }
        )
    }

    private func makeLiveTarget(
        heistId: HeistId,
        label: String = "Target",
        traits: UIAccessibilityTraits = [],
        frame: CGRect = CGRect(x: 0, y: 0, width: 44, height: 44),
        activationPoint: CGPoint,
        object: NSObject = ActivationObject()
    ) async -> TheVault.LiveActionTarget {
        let element = AccessibilityElement.make(
            label: label,
            traits: traits,
            shape: .frame(AccessibilityRect(frame)),
            activationPoint: activationPoint,
            respondsToUserInteraction: false
        )
        let treeElement = InterfaceTree.Element(
            heistId: heistId,
            scrollMembership: nil,
            geometry: testGeometry(
                for: element,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: element)
            ),
            element: element
        )
        object.accessibilityFrame = frame
        let vault = TheVault(tripwire: TheTripwire())
        await vault.installObservationForTesting(.makeForTests(
            elements: [(element, heistId)],
            objects: [heistId: object]
        ))
        guard case .resolved(let target) = vault.resolveLiveActionTarget(for: treeElement) else {
            preconditionFailure("Activation policy fixture did not produce a live target")
        }
        return target
    }

    private func makeInflatedTarget(
        _ liveTarget: TheVault.LiveActionTarget,
        resolution: ActionSubjectResolution = ActionSubjectResolution(origin: .visible)
    ) throws -> ElementInflation.InflatedElementTarget {
        let label = try XCTUnwrap(
            liveTarget.treeElement.element.label,
            "Activation-policy fixtures must have an authored label target"
        )
        return ElementInflation.InflatedElementTarget(
            target: try AccessibilityTarget.label(label).resolve(in: .empty),
            treeElement: liveTarget.treeElement,
            liveTarget: liveTarget,
            deadline: SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 1
            ),
            resolution: resolution
        )
    }

}

#endif
