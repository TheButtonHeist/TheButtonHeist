#if canImport(UIKit) && DEBUG
import UIKit

import ButtonHeistSupport
import TheScore
import ThePlans

@MainActor
internal final class ElementInflation {

    private struct PortableSemanticTarget {
        let target: ResolvedAccessibilityTarget
        let removedTerminalOrdinal: Bool
    }

    internal struct AdmittedSemanticTarget: Sendable {
        internal let target: ResolvedAccessibilityTarget
        internal let scrollContainerPath: TreePath?

        private init(
            target: ResolvedAccessibilityTarget,
            scrollContainerPath: TreePath?
        ) {
            self.target = target
            self.scrollContainerPath = scrollContainerPath
        }

        internal static func admit(
            _ sourceTarget: ResolvedAccessibilityTarget,
            selectedElement: InterfaceTree.Element,
            resolve: (ResolvedAccessibilityTarget) -> TheVault.TargetResolution
        ) -> SemanticTargetAdmissionDecision {
            let portableTarget = portableTarget(from: sourceTarget)
            switch resolve(portableTarget.target) {
            case .resolved(.element(let match)) where match == selectedElement:
                return .admitted(AdmittedSemanticTarget(
                    target: portableTarget.target,
                    scrollContainerPath: selectedElement.scrollMembership?.containerPath
                ))
            case .resolved(.element):
                return .rejected(.selectedElementMismatch)
            case .resolved(.container):
                return .rejected(.containerTarget)
            case .notFound(let facts):
                return .rejected(.notFound(facts))
            case .ambiguous(let facts):
                return .rejected(portableTarget.removedTerminalOrdinal
                    ? .ordinalDependent(facts)
                    : .ambiguous(facts))
            }
        }

        private static func portableTarget(
            from sourceTarget: ResolvedAccessibilityTarget
        ) -> PortableSemanticTarget {
            switch sourceTarget {
            case .predicate(let predicate, let ordinal):
                return PortableSemanticTarget(
                    target: .predicate(predicate, ordinal: nil),
                    removedTerminalOrdinal: ordinal != nil
                )
            case .container(let predicate, let ordinal):
                return PortableSemanticTarget(
                    target: .container(predicate, ordinal: nil),
                    removedTerminalOrdinal: ordinal != nil
                )
            case .within(let container, let nestedTarget):
                let nestedPortableTarget = portableTarget(from: nestedTarget)
                return PortableSemanticTarget(
                    target: .within(container: container, target: nestedPortableTarget.target),
                    removedTerminalOrdinal: nestedPortableTarget.removedTerminalOrdinal
                )
            }
        }
    }

    internal enum SemanticTargetAdmissionDecision {
        case admitted(AdmittedSemanticTarget)
        case rejected(SemanticTargetAdmissionRejection)
    }

    internal enum SemanticTargetAdmissionRejection: Equatable {
        case ordinalDependent(TheVault.TargetAmbiguityFacts)
        case notFound(TheVault.TargetNotFoundFacts)
        case ambiguous(TheVault.TargetAmbiguityFacts)
        case selectedElementMismatch
        case containerTarget
    }

    internal struct SemanticTargetRevealRequest {
        internal let target: AdmittedSemanticTarget
        internal let revealRootScrollViewID: ObjectIdentifier
        internal let deadline: SemanticObservationDeadline
    }

    internal typealias MoveViewport = @MainActor (
        Navigation.ViewportMovementIntent,
        SemanticObservationDeadline
    ) async -> Navigation.ViewportTransition

    internal struct Exploration {
        internal var discoverTarget: @MainActor (
            ResolvedAccessibilityTarget,
            SemanticObservationDeadline
        ) async -> Navigation.InterfaceExplorationResult?
        internal var revealKnownTarget: @MainActor (
            SemanticTargetRevealRequest,
        ) async -> SemanticTargetScanResult?
        internal var moveViewport: MoveViewport
    }

    internal struct CommittedElementTarget {
        private let identity: CrossCaptureTarget
        private let resolvedHeistId: HeistId
        private let resolution: ActionSubjectResolution

        internal init(_ inflatedTarget: InflatedElementTarget) {
            identity = inflatedTarget.identity
            resolvedHeistId = inflatedTarget.treeElement.heistId
            resolution = inflatedTarget.resolution
        }

        internal var target: ResolvedAccessibilityTarget { identity.sourceTarget }
        internal var crossCaptureTarget: CrossCaptureTarget { identity }
        internal var heistId: HeistId { resolvedHeistId }
        internal var subjectResolution: ActionSubjectResolution { resolution }
    }

    internal let vault: TheVault
    internal let safecracker: TheSafecracker
    internal var exploration: Exploration

    internal static let comfortMarginFraction: CGFloat = 1.0 / 6.0
    internal init(
        vault: TheVault,
        safecracker: TheSafecracker,
        exploration: Exploration
    ) {
        self.vault = vault
        self.safecracker = safecracker
        self.exploration = exploration
    }

    internal func inflate(
        for target: ResolvedAccessibilityTarget,
        method: ActionMethod,
        activationPointPolicy: ActivationPointPolicy = .requireOnscreen,
        deadline: SemanticObservationDeadline
    ) async -> ElementInflationResult {
        guard !Task.isCancelled else {
            return .failed(.cancelled("element inflation was cancelled before resolution"))
        }
        let validatedTarget: ResolvedAccessibilityTarget
        do {
            validatedTarget = try target.validatedForElementAction()
        } catch {
            return .failed(.targetResolution(error))
        }
        return await runInflation(
            for: validatedTarget,
            method: method,
            activationPointPolicy: activationPointPolicy,
            deadline: deadline
        )
    }

    private func runInflation(
        for target: ResolvedAccessibilityTarget,
        method: ActionMethod,
        activationPointPolicy: ActivationPointPolicy,
        deadline: SemanticObservationDeadline,
        initialState: State = .resolving
    ) async -> ElementInflationResult {
        var state = initialState
        let revealTransaction = RevealTransaction(vault: vault)
        revealTransaction.captureScrollableHierarchy()

        while true {
            switch state {
            case .resolving:
                let nextState: State
                switch await findTargetInTree(target, deadline: deadline) {
                case .success(.visible(let treeElement, let resolution)):
                    nextState = .refreshing(
                        target: .captureLocal(target),
                        treeElement: treeElement,
                        deadline: deadline,
                        resolution: resolution
                    )
                case .success(.known(let treeElement, let resolution)):
                    nextState = .revealing(
                        target: .captureLocal(target),
                        treeElement: treeElement,
                        deadline: deadline,
                        resolution: resolution
                    )
                case .failure(let failure):
                    nextState = .failed(failure)
                }
                state = transition(from: state, to: nextState)

            case .revealing(let target, let treeElement, let deadline, let resolution):
                let nextState = await stateAfterReveal(
                    treeElement,
                    identity: target,
                    deadline: deadline,
                    resolution: resolution,
                    transaction: revealTransaction
                )
                state = transition(from: state, to: nextState)

            case .refreshing(let target, let treeElement, let deadline, let resolution):
                let nextState = await stateAfterRefresh(
                    identity: target,
                    treeElement: treeElement,
                    resolution: resolution,
                    method: method,
                    activationPointPolicy: activationPointPolicy,
                    deadline: deadline
                )
                state = transition(from: state, to: nextState)

            case .placing(let inflatedTarget):
                let nextState = await stateAfterPlacement(
                    inflatedTarget,
                    method: method,
                    transaction: revealTransaction
                )
                state = transition(from: state, to: nextState)

            case .inflated(let result):
                revealTransaction.commit()
                return .inflated(result)

            case .failed(let failure):
                await revealTransaction.rollBack(
                    using: exploration.moveViewport,
                    deadline: deadline
                )
                return .failed(failure)
            }
        }
    }

    internal func refreshCommittedTarget(
        _ target: CommittedElementTarget,
        method: ActionMethod,
        activationPointPolicy: ActivationPointPolicy,
        deadline: SemanticObservationDeadline
    ) async -> ElementInflationResult {
        guard !Task.isCancelled else {
            return .failed(.cancelled("element inflation was cancelled before committed target refresh"))
        }
        let treeElement: InterfaceTree.Element
        switch target.crossCaptureTarget {
        case .captureLocal:
            guard let current = vault.interfaceElement(heistId: target.heistId) else {
                return .failed(.staleRefresh(
                    "committed target \(target.heistId) disappeared before \(method.rawValue) refresh",
                    failureKind: .elementNotFound
                ))
            }
            treeElement = current
        case .admitted(_, let semanticTarget):
            switch resolveAdmittedSemanticTarget(semanticTarget) {
            case .success(let current):
                treeElement = current
            case .failure(let failure):
                return .failed(failure.inflationFailure)
            }
        }
        let initialState: State = vault.liveContains(heistId: treeElement.heistId)
            ? .refreshing(
                target: target.crossCaptureTarget,
                treeElement: treeElement,
                deadline: deadline,
                resolution: target.subjectResolution
            )
            : .revealing(
                target: target.crossCaptureTarget,
                treeElement: treeElement,
                deadline: deadline,
                resolution: target.subjectResolution
            )
        return await runInflation(
            for: target.target,
            method: method,
            activationPointPolicy: activationPointPolicy,
            deadline: deadline,
            initialState: initialState
        )
    }

    private func transition(
        from state: State,
        to proposedState: State
    ) -> State {
        let nextState: State
        if proposedState.isCancellationFailure {
            nextState = proposedState
        } else if Task.isCancelled {
            nextState = .failed(.cancelled(
                "element inflation was cancelled while \(state)"
            ))
        } else {
            nextState = proposedState
        }
        return nextState
    }
}

extension ElementInflation.InflatedElementTarget {
    internal var committedTarget: ElementInflation.CommittedElementTarget {
        ElementInflation.CommittedElementTarget(self)
    }
}

#endif // canImport(UIKit) && DEBUG
