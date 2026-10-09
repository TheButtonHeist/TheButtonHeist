#if canImport(UIKit) && DEBUG
import UIKit

import TheScore
import ThePlans

extension ElementInflation {

    internal enum FirstResponderInflation {
        case unavailable
        case inflated(InflatedElementTarget)
        case failed(ElementInflationFailure)
    }

    internal func inflateFirstResponder(
        method: ActionMethod,
        deadline: SemanticObservationDeadline
    ) async -> FirstResponderInflation {
        await inflateFirstResponder(method: method) { target, method in
            await self.inflate(
                for: target,
                method: method,
                deadline: deadline
            )
        }
    }

    internal func inflateFirstResponder(
        method: ActionMethod,
        inflateTarget: @MainActor (ResolvedAccessibilityTarget, ActionMethod) async -> ElementInflationResult
    ) async -> FirstResponderInflation {
        guard let firstResponderHeistId = vault.firstResponderHeistId,
              let treeElement = vault.interfaceElement(heistId: firstResponderHeistId),
              let authoredTarget = vault.minimumUniqueTarget(for: treeElement) else { return .unavailable }
        let target: ResolvedAccessibilityTarget
        do {
            target = try authoredTarget.resolve(in: .empty)
        } catch {
            preconditionFailure("Stash-generated target must resolve without references: \(error)")
        }
        switch await inflateTarget(target, method) {
        case .inflated(let inflatedTarget):
            guard vault.firstResponderHeistId == firstResponderHeistId,
                  inflatedTarget.treeElement.heistId == firstResponderHeistId else {
                return .failed(.staleRefresh(
                    "first responder no longer matches captured HeistId \(firstResponderHeistId) after inflation",
                    failureKind: .elementNotFound
                ))
            }
            return .inflated(inflatedTarget)
        case .failed(let failure):
            return .failed(failure)
        }
    }
}

#endif // canImport(UIKit) && DEBUG
