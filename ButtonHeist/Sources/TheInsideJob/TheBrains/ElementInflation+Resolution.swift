#if canImport(UIKit) && DEBUG
import UIKit

import TheScore
import ThePlans

extension ElementInflation {

    internal func admitSemanticTarget(
        _ sourceTarget: ResolvedAccessibilityTarget,
        selectedElement: InterfaceTree.Element
    ) -> SemanticTargetAdmissionDecision {
        AdmittedSemanticTarget.admit(
            sourceTarget,
            selectedElement: selectedElement,
            resolve: vault.resolveTarget
        )
    }

    internal func stateAfterRefresh(
        target: ResolvedAccessibilityTarget,
        treeElement: InterfaceTree.Element,
        resolution: ActionSubjectResolution,
        method: ActionMethod,
        activationPointPolicy: ActivationPointPolicy,
        deadline: SemanticObservationDeadline
    ) async -> State {
        await stateAfterRefresh(
            identity: .captureLocal(target),
            treeElement: treeElement,
            resolution: resolution,
            method: method,
            activationPointPolicy: activationPointPolicy,
            deadline: deadline
        )
    }

    internal func stateAfterRefresh(
        identity: CrossCaptureTarget,
        treeElement: InterfaceTree.Element,
        resolution: ActionSubjectResolution,
        method: ActionMethod,
        activationPointPolicy: ActivationPointPolicy,
        deadline: SemanticObservationDeadline
    ) async -> State {
        let admittedResolution: ActionSubjectResolution
        if activationPointPolicy == .liveObjectOnly {
            switch await captureFreshLiveObjectResolution(
                identity: identity,
                treeElement: treeElement,
                resolution: resolution,
                method: method,
                deadline: deadline
            ) {
            case .success(let capturedResolution):
                admittedResolution = capturedResolution
            case .failure(let failure):
                return .failed(failure)
            }
        } else {
            admittedResolution = resolution
        }
        let currentElement: InterfaceTree.Element
        switch resolveCurrentElement(for: identity, pinnedElement: treeElement) {
        case .success(let resolved):
            currentElement = resolved
        case .failure(let failure):
            return .failed(failure)
        }
        switch resolveFreshElementTarget(
            identity: identity,
            treeElement: currentElement,
            method: method,
            deadline: deadline,
            resolution: admittedResolution
        ) {
        case .success(let inflatedTarget):
            return stateAfterResolvedFreshTarget(
                inflatedTarget,
                activationPointPolicy: activationPointPolicy
            )
        case .retry(let reason):
            return await stateAfterLiveTargetRetry(
                identity: identity,
                currentElement: currentElement,
                reason: reason,
                resolution: admittedResolution,
                method: method,
                activationPointPolicy: activationPointPolicy,
                deadline: deadline
            )
        case .failure(let failure):
            return .failed(failure)
        }
    }

    private func stateAfterLiveTargetRetry(
        identity: CrossCaptureTarget,
        currentElement: InterfaceTree.Element,
        reason: RetryReason,
        resolution: ActionSubjectResolution,
        method: ActionMethod,
        activationPointPolicy: ActivationPointPolicy,
        deadline: SemanticObservationDeadline
    ) async -> State {
        let refreshedResolution = resolution.adding(reason.adjustment)
        let pendingRetry: (reason: RetryReason, resolution: ActionSubjectResolution)
        if case .committed = await vault.semanticObservationStream
            .refreshedVisibleObservation(boundary: .cancellation) {
            let refreshedElement: InterfaceTree.Element
            switch resolveCurrentElement(for: identity, pinnedElement: currentElement) {
            case .success(let resolved):
                refreshedElement = resolved
            case .failure(let failure):
                return .failed(failure)
            }
            switch resolveCurrentLiveElementTarget(
                treeElement: refreshedElement,
                identity: identity,
                method: method,
                deadline: deadline,
                resolution: refreshedResolution
            ) {
            case .success(let inflatedTarget):
                return stateAfterResolvedFreshTarget(
                    inflatedTarget,
                    activationPointPolicy: activationPointPolicy
                )
            case .failure(let failure):
                return .failed(failure)
            case .retry(let refreshedReason):
                pendingRetry = (
                    refreshedReason,
                    refreshedResolution.adding(refreshedReason.adjustment)
                )
            }
        } else {
            pendingRetry = (reason, refreshedResolution)
        }
        let historyIndex = vault.state.history.endIndex
        let refresh: TargetRefreshTerminal
        switch identity {
        case .captureLocal(let target):
            refresh = await awaitLiveTargetRefresh(
                for: target,
                treeElement: currentElement,
                method: method,
                after: historyIndex,
                deadline: deadline,
                resolution: pendingRetry.resolution
            )
        case .admitted(let sourceTarget, let semanticTarget):
            refresh = await awaitLiveTargetRefresh(
                for: semanticTarget,
                sourceTarget: sourceTarget,
                pinnedElement: currentElement,
                method: method,
                after: historyIndex,
                deadline: deadline,
                resolution: pendingRetry.resolution
            )
        }
        switch refresh {
        case .inflated(let inflatedTarget):
            return stateAfterResolvedFreshTarget(
                inflatedTarget,
                activationPointPolicy: activationPointPolicy
            )
        case .failure(let failure):
            return .failed(failure)
        case .treeElement, .timedOut:
            return .failed(staleRefreshFailure(reason: pendingRetry.reason))
        case .cancelled:
            return .failed(.cancelled(
                "stale live target refresh was cancelled after \(pendingRetry.reason.failureDescription)"
            ))
        }
    }

    private func captureFreshLiveObjectResolution(
        identity: CrossCaptureTarget,
        treeElement: InterfaceTree.Element,
        resolution: ActionSubjectResolution,
        method: ActionMethod,
        deadline: SemanticObservationDeadline
    ) async -> Result<ActionSubjectResolution, ElementInflationFailure> {
        let admittedResolution: ActionSubjectResolution
        if case .retry(let reason) = resolveCurrentLiveElementTarget(
            treeElement: treeElement,
            identity: identity,
            method: method,
            deadline: deadline,
            resolution: resolution
        ) {
            admittedResolution = resolution.adding(reason.adjustment)
        } else {
            admittedResolution = resolution
        }
        switch await vault.semanticObservationStream.refreshedVisibleObservation(
            boundary: .externalDeadline(deadline)
        ) {
        case .committed:
            return .success(admittedResolution)
        case .unavailable(.cancelled):
            return .failure(.cancelled(
                "fresh live target capture was cancelled before \(method.rawValue) dispatch"
            ))
        case .unavailable:
            let description = Navigation.ScrollTargetDescription(treeElement).description
            if deadline.hasTimeRemaining(at: RuntimeElapsed.now) {
                return .failure(.staleRefresh(
                    "fresh visible accessibility evidence was unavailable for target \(description)",
                    failureKind: .elementNotFound
                ))
            }
            return .failure(.timedOut(
                "fresh live target capture reached the action deadline for target \(description)"
            ))
        }
    }

    func resolveCurrentElement(
        for identity: CrossCaptureTarget,
        pinnedElement: InterfaceTree.Element
    ) -> Result<InterfaceTree.Element, ElementInflationFailure> {
        switch identity {
        case .captureLocal:
            return .success(pinnedElement)
        case .admitted(_, let target):
            switch resolveAdmittedSemanticTarget(target) {
            case .success(let current):
                return .success(current)
            case .failure(let failure):
                return .failure(failure.inflationFailure)
            }
        }
    }

    internal func findTargetInTree(
        _ target: ResolvedAccessibilityTarget,
        deadline: SemanticObservationDeadline
    ) async -> Result<TreeTargetMatch, ElementInflationFailure> {
        guard await vault.semanticObservationStream.admittedVisibleObservation(
            boundary: .cancellation
        ) != nil else {
            return .failure(.notFound(
                "no admitted visible accessibility observation was available for target resolution"
            ))
        }
        switch visibleTargetResolution(target) {
        case .success(let visible):
            return .success(.visible(visible, ActionSubjectResolution(origin: .visible)))
        case .failure(let failure):
            return .failure(failure)
        case nil:
            break
        }
        switch knownSemanticTarget(target) {
        case .success(let known):
            return .success(.known(known, ActionSubjectResolution(origin: .known)))
        case .failure(let failure) where failure.failedStep == .ambiguous:
            return .failure(failure)
        case .failure:
            break
        }
        let explorationResult = await exploration.discoverTarget(target, deadline)
        switch visibleTargetResolution(target) {
        case .success(let visible):
            let resolution = ActionSubjectResolution(origin: .discovered)
            return .success(.visible(
                visible,
                explorationResult?.didMoveViewport == true
                    ? resolution.adding(.semanticReveal)
                    : resolution
            ))
        case .failure(let failure):
            return .failure(failure)
        case nil:
            break
        }
        switch knownSemanticTarget(target) {
        case .success(let treeElement):
            return .success(.known(treeElement, ActionSubjectResolution(origin: .discovered)))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    internal func knownSemanticTarget(
        _ target: ResolvedAccessibilityTarget
    ) -> Result<InterfaceTree.Element, ElementInflationFailure> {
        switch vault.resolveTarget(target) {
        case .resolved(.element(let treeElement)):
            return .success(treeElement)
        case .resolved(.container):
            return .failure(.targetResolution(.containerTarget))
        case .ambiguous(let facts):
            return .failure(.ambiguous(TargetResolutionDiagnostics.message(for: .ambiguous(facts))))
        case .notFound(let facts):
            return .failure(.notFound(TargetResolutionDiagnostics.message(for: .notFound(facts))))
        }
    }

    internal func visibleTargetResolution(
        _ target: ResolvedAccessibilityTarget
    ) -> Result<InterfaceTree.Element, ElementInflationFailure>? {
        switch vault.resolveVisibleTarget(target) {
        case .resolved(.element(let treeElement)):
            return .success(treeElement)
        case .resolved(.container):
            return .failure(.targetResolution(.containerTarget))
        case .ambiguous(let facts):
            return .failure(.ambiguous(TargetResolutionDiagnostics.message(for: .ambiguous(facts))))
        case .notFound:
            return nil
        }
    }

    internal func resolveCurrentLiveElementTarget(
        treeElement: InterfaceTree.Element,
        identity: CrossCaptureTarget,
        method: ActionMethod,
        deadline: SemanticObservationDeadline,
        resolution: ActionSubjectResolution
    ) -> FreshElementTargetResolution {
        let currentElement: InterfaceTree.Element
        switch identity {
        case .captureLocal:
            guard let committed = vault.interfaceElement(heistId: treeElement.heistId) else {
                return .retry(.staleTarget)
            }
            currentElement = committed
        case .admitted:
            currentElement = treeElement
        }
        switch vault.resolveLiveActionTarget(for: currentElement) {
        case .resolved(let liveTarget):
            return .success(InflatedElementTarget(
                identity: identity,
                treeElement: currentElement,
                liveTarget: liveTarget,
                deadline: deadline,
                resolution: resolution
            ))
        case .objectUnavailable:
            return .retry(.objectDeallocated)
        case .geometryUnavailable:
            return .failure(.geometryNotActionable(
                ActionCapabilityDiagnostic.gestureTargetUnavailable(
                    method: method,
                    element: currentElement,
                    isVisible: vault.liveContains(heistId: currentElement.heistId)
                )
            ))
        }
    }

    private func resolveFreshElementTarget(
        identity: CrossCaptureTarget,
        treeElement: InterfaceTree.Element,
        method: ActionMethod,
        deadline: SemanticObservationDeadline,
        resolution: ActionSubjectResolution
    ) -> FreshElementTargetResolution {
        resolveLiveElementTarget(
            identity: identity,
            treeElement: treeElement,
            method: method,
            deadline: deadline,
            resolution: resolution
        )
    }

    private func resolveLiveElementTarget(
        identity: CrossCaptureTarget,
        treeElement: InterfaceTree.Element,
        method: ActionMethod,
        deadline: SemanticObservationDeadline,
        resolution: ActionSubjectResolution
    ) -> FreshElementTargetResolution {
        resolveCurrentLiveElementTarget(
            treeElement: treeElement,
            identity: identity,
            method: method,
            deadline: deadline,
            resolution: resolution
        )
    }
}

#endif // canImport(UIKit) && DEBUG
