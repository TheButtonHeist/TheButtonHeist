#if canImport(UIKit)
#if DEBUG
import UIKit

import TheScore
import ThePlans

extension TheVault {
    func firstResponderTarget(in tree: InterfaceTree) -> AccessibilityTarget? {
        tree.firstResponderTarget
    }

    func minimumUniqueTarget(for treeElement: InterfaceTree.Element) -> AccessibilityTarget? {
        minimumUniqueTarget(for: treeElement.heistId, in: interfaceTree)
    }

    func minimumUniqueTarget(for heistId: HeistId, in tree: InterfaceTree) -> AccessibilityTarget? {
        tree.minimumUniqueTarget(for: heistId)
    }
}

extension InterfaceTree {
    var firstResponderTarget: AccessibilityTarget? {
        firstResponderHeistId.flatMap(minimumUniqueTarget)
    }

    func minimumUniqueTarget(for heistId: HeistId) -> AccessibilityTarget? {
        let elements = orderedElements.map {
            PredicateSelectionSubjectElement(id: $0.heistId.predicateSelectionElementId, element: $0.element)
        }
        return MinimumPredicateSelector.minimumUniquePredicate(
            for: heistId.predicateSelectionElementId,
            in: elements
        )?.target
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
