#if canImport(UIKit)
#if DEBUG
import UIKit

import TheScore
import ThePlans

extension Navigation {

    func executeScroll(
        _ target: ResolvedScrollTarget,
        deadline: SemanticObservationDeadline
    ) async -> TheSafecracker.ActionDispatchResult {
        await executeScroll(
            selection: target.selection,
            direction: target.direction,
            deadline: deadline
        )
    }

    func executeScroll(
        selection: ResolvedScrollContainerSelection,
        direction: ScrollDirection,
        deadline: SemanticObservationDeadline
    ) async -> TheSafecracker.ActionDispatchResult {
        guard await refreshVisibleScrollEvidence() else {
            return .failure(
                .scroll,
                message: "scroll failed: no committed visible observation was available",
                failureKind: .elementNotFound
            )
        }
        let axis = Self.requiredAxis(for: direction)
        switch resolveContainerScrollTarget(
            selection: selection,
            axis: axis,
            command: .scroll
        ) {
        case .resolved(let scrollTarget):
            let uiDirection = Self.uiScrollDirection(for: direction)
            let transition: ViewportTransition
            switch scrollTarget {
            case .uiScrollView:
                transition = await performViewportTransition(
                    .page(scrollTarget, direction: uiDirection, animated: false),
                    deadline: deadline
                )
            case .swipeable:
                transition = await performViewportTransition(
                    .swipe(scrollTarget, direction: uiDirection),
                    deadline: deadline
                )
            }
            switch transition.outcome {
            case .moved:
                return .success(payload: .scroll)
            case .unchanged:
                return .failure(.scroll, message: "scroll failed: observed target already at edge; try the opposite direction")
            case .unavailable:
                return .failure(.scroll, message: "scroll failed: selected container cannot be scrolled")
            }
        case .failed(let failure):
            return .failure(
                failure.command.payload,
                message: failure.message,
                failureKind: .elementNotFound
            )
        }
    }

    func executeScrollToEdge(
        _ target: ResolvedScrollToEdgeTarget,
        deadline: SemanticObservationDeadline
    ) async -> TheSafecracker.ActionDispatchResult {
        await executeScrollToEdge(
            selection: target.selection,
            edge: target.edge,
            deadline: deadline
        )
    }

    func executeScrollToEdge(
        selection: ResolvedScrollContainerSelection,
        edge: ScrollEdge,
        deadline: SemanticObservationDeadline
    ) async -> TheSafecracker.ActionDispatchResult {
        guard await refreshVisibleScrollEvidence() else {
            return .failure(
                .scrollToEdge,
                message: "scroll_to_edge failed: no committed visible observation was available",
                failureKind: .elementNotFound
            )
        }
        let axis = Self.requiredAxis(for: edge)
        switch resolveContainerScrollTarget(
            selection: selection,
            axis: axis,
            command: .scrollToEdge
        ) {
        case .resolved(let scrollTarget):
            guard case .uiScrollView = scrollTarget else {
                return .failure(
                    .scrollToEdge,
                    message: "scroll_to_edge failed: selected container cannot be scrolled programmatically"
                )
            }
            let transition = await performViewportTransition(
                .edge(scrollTarget, edge: edge),
                deadline: deadline
            )
            switch transition.outcome {
            case .moved:
                return .success(payload: .scrollToEdge)
            case .unchanged:
                return .success(payload: .scrollToEdge)
            case .unavailable:
                return .failure(
                    .scrollToEdge,
                    message: "scroll_to_edge failed: selected container cannot be scrolled programmatically"
                )
            }
        case .failed(let failure):
            return .failure(
                failure.command.payload,
                message: failure.message,
                failureKind: .elementNotFound
            )
        }
    }

    private func refreshVisibleScrollEvidence() async -> Bool {
        await vault.semanticObservationStream.refreshedVisibleObservation(
            boundary: .cancellation
        ).isCommitted
    }

}

#endif // DEBUG
#endif // canImport(UIKit)
