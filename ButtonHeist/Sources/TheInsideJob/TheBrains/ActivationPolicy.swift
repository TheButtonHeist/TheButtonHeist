#if canImport(UIKit)
#if DEBUG
import UIKit

import AccessibilitySnapshotParser
import ThePlans
import TheScore

struct ActivationDispatchEvidence: Sendable {
    let outcome: AccessibilityActionDispatcher.ActivateOutcome
    let activationPoint: CGPoint
}

enum ActivationRefreshResult {
    case resolved(ElementInflation.InflatedElementTarget)
    case failure(TheSafecracker.ActionDispatchResult)
}

struct ActivationPolicy {
    let semanticTarget: ElementInflation.InflatedElementTarget
    var accessibilityActivate: @MainActor (
        TheVault.LiveActionTarget
    ) -> Result<ActivationDispatchEvidence, TheVault.LiveTargetStaleness<HeistId>>
    var resolveOnscreenFallbackTarget: @MainActor () async -> ActivationRefreshResult
    var tapActivationPoint: @MainActor (CGPoint) async -> Bool
    var showFingerprint: @MainActor (CGPoint) -> Void
    var textEntryActivationFailure: @MainActor (InterfaceTree.Element, ActivationTrace) async -> TheSafecracker.ActionDispatchResult?

    @MainActor
    func apply() async -> TheSafecracker.ActionDispatchResult {
        let semanticTreeElement = semanticTarget.treeElement
        let semanticLiveTarget = semanticTarget.liveTarget
        let semanticSubjectEvidence = semanticTarget.subjectEvidence(source: .resolvedSemanticTarget)
        let implementsAccessibilityActivation = TheVault.Interactivity
            .implementsAccessibilityActivation(semanticLiveTarget.object)

        let semanticDispatch: ActivationDispatchEvidence
        switch accessibilityActivate(semanticLiveTarget) {
        case .success(let dispatch):
            semanticDispatch = dispatch
        case .failure(let staleness):
            return .failure(
                .activate,
                message: staleness.message,
                subjectEvidence: semanticSubjectEvidence,
                activationTrace: ActivationTrace(.refreshFailed),
                failureKind: .elementNotFound
            )
        }
        switch semanticDispatch.outcome {
        case .success:
            return await accessibilityActivationResult(
                treeElement: semanticTreeElement,
                subjectEvidence: semanticSubjectEvidence,
                activationPoint: semanticDispatch.activationPoint
            )
        case .refused:
            return await activationPointFallback(
                semanticSubjectEvidence: semanticSubjectEvidence,
                implementsAccessibilityActivation: implementsAccessibilityActivation
            )
        }
    }

    @MainActor
    private func activationPointFallback(
        semanticSubjectEvidence: ActionSubjectEvidence,
        implementsAccessibilityActivation: Bool
    ) async -> TheSafecracker.ActionDispatchResult {
        let fallbackTarget: ElementInflation.InflatedElementTarget
        switch await resolveOnscreenFallbackTarget() {
        case .resolved(let target):
            fallbackTarget = target
        case .failure(let result):
            return result
                .withSubjectEvidence(semanticSubjectEvidence)
                .withActivationTrace(ActivationTrace(.accessibilityActivate(
                    axActivateReturned: false
                )))
        }
        let treeElement = fallbackTarget.treeElement
        let activationPoint = fallbackTarget.liveTarget.activationPoint
        let subjectEvidence = fallbackTarget.subjectEvidence(source: .resolvedSemanticTarget)

        guard let activationX = try? FiniteCoordinate(validating: Double(activationPoint.x)),
              let activationY = try? FiniteCoordinate(validating: Double(activationPoint.y)) else {
            return .failure(
                .activate,
                message: "activate failed: the fresh fallback accessibility activation point was not finite",
                subjectEvidence: subjectEvidence,
                activationTrace: ActivationTrace(.accessibilityActivate(axActivateReturned: false))
            )
        }
        let admittedActivationPoint = ScreenPoint(x: activationX, y: activationY)

        let tapActivationSucceeded = await tapActivationPoint(activationPoint)
        let trace = ActivationTrace(.activationPointFallback(
            axActivateReturned: false,
            tapActivationPoint: admittedActivationPoint,
            tapActivationSucceeded: tapActivationSucceeded
        ), implementsAccessibilityActivation: implementsAccessibilityActivation)
        if tapActivationSucceeded {
            if let failure = await textEntryActivationFailure(treeElement, trace) {
                return failure.withSubjectEvidence(subjectEvidence)
            }
            return .success(
                payload: .activate,
                subjectEvidence: subjectEvidence,
                activationTrace: trace
            )
        }

        return .failure(
            .activate,
            message: activationFailureMessage(
                treeElement: treeElement,
                implementsAccessibilityActivation: implementsAccessibilityActivation
            ),
            subjectEvidence: subjectEvidence,
            activationTrace: trace
        )
    }

    @MainActor
    private func accessibilityActivationResult(
        treeElement: InterfaceTree.Element,
        subjectEvidence: ActionSubjectEvidence,
        activationPoint: CGPoint
    ) async -> TheSafecracker.ActionDispatchResult {
        showFingerprint(activationPoint)
        let trace = ActivationTrace(.accessibilityActivate(
            axActivateReturned: true
        ))
        if let failure = await textEntryActivationFailure(treeElement, trace) {
            return failure.withSubjectEvidence(subjectEvidence)
        }
        return .success(
            payload: .activate,
            subjectEvidence: subjectEvidence,
            activationTrace: trace
        )
    }

    @MainActor
    private func activationFailureMessage(
        treeElement: InterfaceTree.Element,
        implementsAccessibilityActivation: Bool
    ) -> String {
        let implementationEvidence = implementsAccessibilityActivation
            ? "activationImplementation=present likelyConditionalState=true"
            : "activationImplementation=absent likelyInertTarget=true"
        return "activate failed: accessibilityActivate() declined after semantic refresh; " +
            "activation-point dispatch was attempted at the fresh " +
            "accessibility activation point and did not complete for " +
            "\(ActionCapabilityDiagnostic.elementObservation(treeElement)); \(implementationEvidence); " +
            "correction: target an element " +
            "with primary accessibility activation, or use an explicit mechanical gesture when the " +
            "test intent is viewport coordinate delivery"
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
