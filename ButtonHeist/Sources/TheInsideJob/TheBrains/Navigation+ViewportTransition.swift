#if canImport(UIKit)
#if DEBUG
import UIKit

import ThePlans
import TheScore

extension Navigation {

    /// Below this there is no point starting a viewport transition: the move
    /// would not have time to be read before the budget ran out.
    private static let viewportTransitionMinimumBudget: Duration = .milliseconds(32)

    @MainActor enum ViewportRestorationTarget {
        case semantic(ScrollableTarget)
        case original(UIScrollView)
    }

    @MainActor enum ViewportMovementIntent {
        case page(ScrollableTarget, direction: UIAccessibilityScrollDirection, animated: Bool)
        case edge(ScrollableTarget, edge: ScrollEdge)
        case swipe(ScrollableTarget, direction: UIAccessibilityScrollDirection)
        case revealPoint(
            CGPoint,
            in: ScrollableTarget,
            preferredScreenRect: CGRect,
            minimumScreenRect: CGRect
        )
        case revealViewPoint(ViewPoint, in: ScrollableTarget)
        case restoreVisualOrigin(CGPoint, in: ViewportRestorationTarget)
        case restoreContentOffset(CGPoint, in: ViewportRestorationTarget)

    }

    enum ScrollSettleOutcome: Equatable {
        case moved
        case unchanged
        case unavailable
    }

    struct ViewportTransition {
        let outcome: ScrollSettleOutcome
        let previousVisibleIds: Set<HeistId>
        let current: TheVault.State.Current?

        static func unavailable(previousVisibleIds: Set<HeistId> = []) -> ViewportTransition {
            ViewportTransition(
                outcome: .unavailable,
                previousVisibleIds: previousVisibleIds,
                current: nil
            )
        }
    }

    func performViewportTransition(
        _ intent: ViewportMovementIntent,
        deadline: SemanticObservationDeadline? = nil,
        observationBoundary: SemanticObservationWaitBoundary = .cancellation,
        discoveryCommitPolicy: DiscoveryCommitPolicy = .mergeIntoInterface
    ) async -> ViewportTransition {
        await vault.semanticObservationStream.movingViewport {
            await performViewportTransitionMovingViewport(
                intent,
                deadline: deadline,
                observationBoundary: observationBoundary,
                discoveryCommitPolicy: discoveryCommitPolicy
            )
        }
    }

    /// Every viewport move Button Heist makes runs here, so a reading taken
    /// while one is in flight can say the viewport moved and be believed.
    private func performViewportTransitionMovingViewport(
        _ intent: ViewportMovementIntent,
        deadline: SemanticObservationDeadline?,
        observationBoundary: SemanticObservationWaitBoundary,
        discoveryCommitPolicy: DiscoveryCommitPolicy
    ) async -> ViewportTransition {
        guard admitsEffect(intent, deadline: deadline) else { return .unavailable() }
        let previousVisibleIds = vault.viewportElementIDs
        let primitiveOutcome = await dispatchViewportMovement(
            intent,
            deadline: deadline
        )
        switch primitiveOutcome {
        case .moved:
            let current: TheVault.State.Current?
            switch intent {
            case .restoreVisualOrigin, .restoreContentOffset:
                current = await observeRestoredViewport(
                    boundary: observationBoundary,
                    discoveryCommitPolicy: discoveryCommitPolicy
                )
            default:
                current = await settledExplorationPage(
                    deadline: deadline,
                    observationBoundary: observationBoundary,
                    discoveryCommitPolicy: discoveryCommitPolicy,
                    afterViewportMovement: true
                )
            }
            if case .restoreContentOffset = intent {
                let finalOffsetOutcome = await dispatchViewportMovement(intent, deadline: nil)
                guard finalOffsetOutcome != .unavailable else {
                    return .unavailable(previousVisibleIds: previousVisibleIds)
                }
            }
            guard let current else {
                return .unavailable(previousVisibleIds: previousVisibleIds)
            }
            return ViewportTransition(
                outcome: movementOutcome(
                    for: intent,
                    previousVisibleIds: previousVisibleIds
                ),
                previousVisibleIds: previousVisibleIds,
                current: current
            )
        case .alreadyInPosition:
            return ViewportTransition(
                outcome: .unchanged,
                previousVisibleIds: previousVisibleIds,
                current: nil
            )
        case .unavailable:
            return .unavailable(previousVisibleIds: previousVisibleIds)
        }
    }

    private func observeRestoredViewport(
        boundary: SemanticObservationWaitBoundary,
        discoveryCommitPolicy: DiscoveryCommitPolicy
    ) async -> TheVault.State.Current? {
        let effectiveBoundary: SemanticObservationWaitBoundary = Task.isCancelled
            ? .observationCycle
            : boundary
        if let current = await settledExplorationPage(
            deadline: nil,
            observationBoundary: effectiveBoundary,
            discoveryCommitPolicy: discoveryCommitPolicy,
            afterViewportMovement: true
        ) {
            return current
        }
        guard effectiveBoundary != .observationCycle else { return nil }
        return await settledExplorationPage(
            deadline: nil,
            observationBoundary: .observationCycle,
            discoveryCommitPolicy: discoveryCommitPolicy,
            afterViewportMovement: true
        )
    }

    private func dispatchViewportMovement(
        _ intent: ViewportMovementIntent,
        deadline: SemanticObservationDeadline?
    ) async -> TheSafecracker.ScrollPrimitiveOutcome {
        guard admitsEffect(intent, deadline: deadline) else { return .unavailable }
        switch intent {
        case .page(let target, let direction, let animated):
            return target.dispatchOnFreshScrollView(in: vault) { scrollView in
                safecracker.scrollByPage(scrollView, direction: direction, animated: animated)
            } ?? .unavailable
        case .edge(let target, let edge):
            return target.dispatchOnFreshScrollView(in: vault) { scrollView in
                safecracker.scrollToEdge(scrollView, edge: edge, animated: false)
            } ?? .unavailable
        case .swipe(let target, let direction):
            guard case .swipeable(let container, _) = target else {
                return .unavailable
            }
            let frameResult = vault.dispatchOnFreshLiveContainerTarget(
                container,
            ) { currentContainer -> CGRect? in
                guard let frame = self.safeSwipeFrame(from: currentContainer.frame) else {
                    return nil
                }
                return frame
            }
            guard case .success(let frame) = frameResult,
                  let frame else { return .unavailable }
            guard admitsEffect(intent, deadline: deadline) else { return .unavailable }
            return await safecracker.scrollBySwipe(
                frame: frame,
                direction: direction,
                duration: Self.swipeGestureDuration
            ) ? .moved : .unavailable
        case .revealPoint(let point, let target, let preferredScreenRect, let minimumScreenRect):
            return target.dispatchOnFreshScrollView(in: vault) { scrollView in
                safecracker.scrollToMakeScreenPointVisible(
                    point,
                    in: scrollView,
                    animated: false,
                    preferredScreenRect: preferredScreenRect,
                    minimumScreenRect: minimumScreenRect
                )
            } ?? .unavailable
        case .revealViewPoint(let point, let target):
            return target.dispatchOnFreshScrollView(in: vault) { scrollView in
                safecracker.revealViewPoint(point, in: scrollView)
            } ?? .unavailable
        case .restoreVisualOrigin(let origin, let target):
            switch target {
            case .semantic(let semantic):
                return semantic.dispatchOnFreshScrollView(in: vault) { scrollView in
                    safecracker.restoreVisualOrigin(origin, in: scrollView)
                } ?? .unavailable
            case .original(let scrollView):
                guard scrollView.window != nil,
                      !scrollView.bhIsUnsafeForProgrammaticScrolling,
                      !Navigation.isObscuredByPresentation(view: scrollView)
                else { return .unavailable }
                return safecracker.restoreVisualOrigin(origin, in: scrollView)
            }
        case .restoreContentOffset(let contentOffset, let target):
            switch target {
            case .semantic(let semantic):
                return semantic.dispatchOnFreshScrollView(in: vault) { scrollView in
                    safecracker.restoreContentOffset(contentOffset, in: scrollView)
                } ?? .unavailable
            case .original(let scrollView):
                guard scrollView.window != nil,
                      !scrollView.bhIsUnsafeForProgrammaticScrolling,
                      !Navigation.isObscuredByPresentation(view: scrollView)
                else { return .unavailable }
                return safecracker.restoreContentOffset(contentOffset, in: scrollView)
            }
        }
    }

    private func admitsEffect(
        _ intent: ViewportMovementIntent,
        deadline: SemanticObservationDeadline?
    ) -> Bool {
        switch intent {
        case .restoreVisualOrigin, .restoreContentOffset:
            return true
        default:
            break
        }
        guard !Task.isCancelled else { return false }
        return deadline.map {
            $0.remainingDuration() >= Self.viewportTransitionMinimumBudget
        } ?? true
    }

    private func movementOutcome(
        for intent: ViewportMovementIntent,
        previousVisibleIds: Set<HeistId>
    ) -> ScrollSettleOutcome {
        guard case .swipe = intent else { return .moved }
        return vault.viewportElementIDs == previousVisibleIds ? .unchanged : .moved
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
