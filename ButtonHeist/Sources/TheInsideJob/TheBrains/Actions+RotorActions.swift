#if canImport(UIKit)
#if DEBUG
import UIKit

import TheScore
import ThePlans

extension Actions {

    private static let rotorStringProfile = ElementDiagnosticSummary.RenderProfile.actionCapability

    func executeRotor(
        selection: RotorSelection,
        target: ResolvedAccessibilityTarget,
        direction: RotorDirection,
        deadline: SemanticObservationDeadline,
        timing: inout ActionTiming
    ) async -> TheSafecracker.ActionDispatchResult {
        let rotor = selection.rotorName
        let rotorIndex = selection.rotorIndex
        return await performElementAction(
            target: target,
            payload: .rotor(nil),
            deadline: deadline,
            timing: &timing,
            requireInteractive: false,
            activationPointPolicy: .liveObjectOnly
        ) { context in
            let rotorHistory = self.vault.admitRotorHistory()
            let outcome: TheVault.RotorOutcome
            let result: TheSafecracker.ActionDispatchResult
            switch self.vault.dispatchOnFreshLiveActionTarget(
                context.liveTarget,
                operation: { $0 }
            ) {
            case .success(let liveTarget):
                let dispatchedOutcome = await self.vault.performRotor(
                    selection: selection,
                    direction: direction,
                    on: liveTarget,
                    history: rotorHistory
                )
                outcome = dispatchedOutcome
                result = Self.rotorDispatchOutcome(
                    outcome: dispatchedOutcome,
                    rotor: rotor,
                    rotorIndex: rotorIndex,
                    direction: direction,
                    liveTarget: liveTarget
                )
            case .failure(let staleness):
                return self.staleLiveTargetFailure(staleness, payload: .rotor(nil))
            }
            if case .succeeded(let hit) = outcome {
                await self.exposeRotorResultIfPossible(
                    hit,
                    deadline: deadline
                )
            }
            return result
        }
    }

    private func exposeRotorResultIfPossible(
        _ hit: TheVault.RotorHit,
        deadline: SemanticObservationDeadline
    ) async {
        guard let treeElement = hit.treeElement else { return }

        if let ownerPath = treeElement.scrollContainerPath,
           case .available(let available) = treeElement.geometry.view.admitted(ownedBy: ownerPath),
           case .success(let target) = vault.liveScrollTarget(at: ownerPath) {
            let transition = await navigation.performViewportTransition(
                .revealViewPoint(
                    available.activationPoint,
                    in: .uiScrollView(
                        container: target.container,
                        scrollView: target.scrollView
                    )
                ),
                deadline: deadline
            )
            if transition.outcome == .moved { return }
        }

        if case .objectUnavailable = vault.resolveLiveActionTarget(for: treeElement) {
            _ = await navigation.elementInflation.revealSemanticTarget(
                treeElement,
                deadline: deadline
            )
        }

        guard case .resolved(let liveTarget) = vault.resolveLiveActionTarget(for: treeElement) else {
            return
        }

        let description = Navigation.ScrollTargetDescription(liveTarget.treeElement).description
        _ = await navigation.elementInflation.scrollActivationPointIntoBounds(
            liveTarget.activationPoint,
            in: vault.liveScrollView(for: liveTarget.treeElement),
            method: .rotor,
            noScrollViewFailure: .geometryNotActionable(
                "rotor result \(description) has no live scrollable ancestor to make activation point actionable"
            ),
            unsafeProgrammaticScrollMessage: nil,
            scrollFailedMessage: "rotor result \(description) activation point could not be brought on-screen",
            deadline: deadline
        )
    }

    private static func rotorDispatchOutcome(
        outcome: TheVault.RotorOutcome,
        rotor: RotorName?,
        rotorIndex: Int?,
        direction: RotorDirection,
        liveTarget: TheVault.LiveActionTarget
    ) -> TheSafecracker.ActionDispatchResult {
        let element = liveTarget.treeElement
        let liveObject = liveTarget.object
        switch outcome {
        case .succeeded(let hit):
            return rotorSuccessResult(hit, direction: direction)
        case .deallocated:
            return rotorFailure(
                observed: "liveObject=deallocated before rotor step",
                rotor: rotor,
                rotorIndex: rotorIndex,
                direction: direction,
                element: element,
                liveObject: liveObject,
                suggestion: "retry the same semantic target after UI settles",
                failureKind: .elementNotFound
            )
        case .noRotors:
            return rotorFailure(observed: "customRotors=[]",
                                rotor: rotor, rotorIndex: rotorIndex, direction: direction,
                                element: element, liveObject: liveObject,
                                suggestion: "target an element exposing custom rotors")
        case .noSuchRotor(let available):
            let renderedAvailable = available.map(\.description)
            return rotorFailure(observed: "requestedRotor=\(rotorStringProfile.renderString(rotor?.description ?? "")) "
                                + "availableRotors=\(rotorStringProfile.renderList(renderedAvailable, itemStyle: .quoted))",
                                rotor: rotor, rotorIndex: rotorIndex, direction: direction,
                                element: element, liveObject: liveObject,
                                suggestion: "use one of available rotors \(rotorStringProfile.renderList(renderedAvailable, itemStyle: .quoted))")
        case .ambiguousRotor(let available):
            let renderedAvailable = available.map(\.description)
            return rotorFailure(observed: "ambiguousRotor=\(rotorStringProfile.renderString(rotor?.description ?? "")) "
                                + "availableRotors=\(rotorStringProfile.renderList(renderedAvailable, itemStyle: .quoted))",
                                rotor: rotor, rotorIndex: rotorIndex, direction: direction,
                                element: element, liveObject: liveObject,
                                suggestion: "specify rotorIndex or an exact rotor name")
        case .continuationInvalidated:
            return rotorFailure(
                observed: "rotor continuation belongs to a replaced screen generation",
                rotor: rotor,
                rotorIndex: rotorIndex,
                direction: direction,
                element: element,
                liveObject: liveObject,
                suggestion: "start a new rotor traversal on the current screen",
                failureKind: .elementNotFound
            )
        case .currentItemUnavailable(let heistId):
            return rotorFailure(
                observed: "rotor continuation target \(rotorStringProfile.renderString(heistId)) is not available",
                rotor: rotor,
                rotorIndex: rotorIndex,
                direction: direction,
                element: element,
                liveObject: liveObject,
                suggestion: "start from the semantic target again or use the current continuation returned by the previous rotor result",
                failureKind: .elementNotFound
            )
        case .continuationTextRangeUnavailable:
            return rotorFailure(observed: "continuation.textRange is not available",
                                rotor: rotor, rotorIndex: rotorIndex, direction: direction,
                                element: element, liveObject: liveObject,
                                suggestion: "use the text range returned by the previous rotor result")
        case .noResult(let rotorName):
            return rotorFailure(
                observed: "rotor=\(rotorStringProfile.renderString(rotorName.description)) returned no \(direction.rawValue) result",
                rotor: rotor,
                rotorIndex: rotorIndex,
                direction: direction,
                element: element,
                liveObject: liveObject,
                suggestion: "try the opposite rotor direction or stop at the current item"
            )
        case .resultTargetUnavailable(let rotorName):
            return rotorFailure(
                observed: "rotor=\(rotorStringProfile.renderString(rotorName.description)) returned a result without an accessibility target",
                rotor: rotor,
                rotorIndex: rotorIndex,
                direction: direction,
                element: element,
                liveObject: liveObject,
                suggestion: "retry the rotor from a semantic target that can be made actionable"
            )
        case .resultTargetUnresolved(let rotorName):
            return rotorFailure(
                observed: "rotor=\(rotorStringProfile.renderString(rotorName.description)) returned a target outside the parsed hierarchy",
                rotor: rotor,
                rotorIndex: rotorIndex,
                direction: direction,
                element: element,
                liveObject: liveObject,
                suggestion: "rerun the rotor and act on the returned semantic target after it is parsed"
            )
        }
    }

    private static func rotorSuccessResult(
        _ hit: TheVault.RotorHit,
        direction: RotorDirection
    ) -> TheSafecracker.ActionDispatchResult {
        let foundElement = hit.treeElement.map { treeElement in
            HeistElement(
                accessibilityElement: treeElement.element,
                geometry: treeElement.geometry
            )
        }
        var message = "Rotor '\(hit.rotor)' found"
        if let describedElement = foundElement?.semantics.assertable.label
            ?? foundElement?.semantics.spokenDescription {
            message += " \(describedElement)"
        }
        if let textRange = hit.textRange {
            message += " text range \(textRange.rangeDescription)"
        }
        return .success(
            payload: .rotor(RotorResult(
                rotor: hit.rotor,
                direction: direction,
                foundElement: foundElement,
                textRange: hit.textRange
            )),
            message: message
        )
    }

    private static func rotorFailure(
        observed: String,
        rotor: RotorName?,
        rotorIndex: Int?,
        direction: RotorDirection,
        element: InterfaceTree.Element,
        liveObject: NSObject,
        suggestion: String,
        failureKind: ActionFailure.Kind = .actionFailed
    ) -> TheSafecracker.ActionDispatchResult {
        .failure(
            .rotor(nil),
            message: rotorDiagnostic(
                observed: observed,
                rotor: rotor,
                rotorIndex: rotorIndex,
                direction: direction,
                element: element,
                liveObject: liveObject,
                suggestion: suggestion
            ),
            failureKind: failureKind
        )
    }

    private static func rotorDiagnostic(
        observed: String,
        rotor: RotorName?,
        rotorIndex: Int?,
        direction: RotorDirection,
        element: InterfaceTree.Element,
        liveObject: NSObject,
        suggestion: String
    ) -> String {
        var attempted: [String] = []
        if let rotor {
            attempted.append("rotor=\(rotorStringProfile.renderString(rotor.description))")
        } else {
            attempted.append("rotor")
        }
        if let rotorIndex {
            attempted.append("rotorIndex=\(rotorIndex)")
        }
        attempted.append("direction=\(direction.rawValue)")

        let availableRotors = ActionCapabilityDiagnostic.availableRotors(for: element, liveObject: liveObject)
        return "rotor failed: attempted \(attempted.joined(separator: " ")) "
            + "on \(ActionCapabilityDiagnostic.elementObservation(element, liveObject: liveObject)) "
            + "availableRotors=\(rotorStringProfile.renderList(availableRotors.map(\.description), itemStyle: .quoted)); "
            + "observed \(observed); try \(suggestion)."
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
