#if canImport(UIKit)
#if DEBUG
import UIKit

import TheScore
import ThePlans

import AccessibilitySnapshotParser

extension Navigation {
    /// Walk the whole screen and return the graph.
    ///
    /// No goal and no early exit: every scrollable container is scanned until
    /// the knobs or the deadline stop it, and what comes back is everything
    /// found along the way. Each page commits into the store as it is read, so
    /// the result is the accumulation, not a tree assembled at the end.
    ///
    /// Always starts fresh: the first page replaces whatever we knew and every
    /// page after it merges in.
    ///
    /// Searching is the other job — `exploreScreen(target:)` stops the moment
    /// it finds one element, keeps interface memory, and deliberately does not
    /// produce a full graph.
    func fullGraph(
        deadline: SemanticObservationDeadline? = nil,
        observationBoundary: SemanticObservationWaitBoundary = .cancellation,
        maxScrollsPerContainer: Int? = nil,
        maxScrollsPerDiscovery: Int? = nil
    ) async -> InterfaceExplorationResult? {
        await exploreScreen(
            startingFresh: true,
            exitPosition: .origin,
            deadline: deadline,
            observationBoundary: observationBoundary,
            maxScrollsPerContainer: maxScrollsPerContainer,
            maxScrollsPerDiscovery: maxScrollsPerDiscovery
        )
    }

    func exploreScreen(
        target: ResolvedAccessibilityTarget? = nil,
        startingFresh: Bool = false,
        exitPosition: ViewportExitPosition = .origin,
        searchOrder: ViewportSearchOrder = .forwardFirst,
        deadline: SemanticObservationDeadline? = nil,
        observationBoundary: SemanticObservationWaitBoundary = .cancellation,
        maxScrollsPerContainer: Int? = nil,
        maxScrollsPerDiscovery: Int? = nil,
        onObservation: ((TheVault.State.Current) async -> ViewportExplorationDecision)? = nil,
    ) async -> InterfaceExplorationResult? {
        var exploration = SemanticExploration(
            startingFresh: startingFresh,
            deadline: deadline,
            observationBoundary: observationBoundary,
            maxScrollsPerContainer: maxScrollsPerContainer ?? InterfaceExplorationProgress.maxScrollsPerContainer,
            maxScrollsPerDiscovery: maxScrollsPerDiscovery ?? InterfaceExplorationProgress.maxScrollsPerDiscovery
        )
        if let target,
           explorationGoalIsSatisfied(target),
           let current = vault.state.current {
            return exploration.finish(
                startTime: CACurrentMediaTime(),
                current: current,
                didMoveViewport: false,
                viewportExit: exitPosition == .origin ? .restored : .retained,
                outcome: .goalSatisfied
            )
        }
        let explorer = ViewportExplorer(
            navigation: self,
            exploration: exploration,
            searchOrder: searchOrder,
        )
        return await explorer.exploreViewports(exitPosition: exitPosition) { current in
            if let decision = await onObservation?(current), decision == .goalSatisfied {
                return .goalSatisfied
            }
            guard let target else { return .continue }
            return explorationGoalIsSatisfied(target)
                ? .goalSatisfied
                : .continue
        }
    }

    private func explorationGoalIsSatisfied(
        _ target: ResolvedAccessibilityTarget
    ) -> Bool {
        switch vault.resolveVisibleTarget(target) {
        case .resolved, .ambiguous:
            return true
        case .notFound:
            return false
        }
    }
}

extension Navigation {
    func settledExplorationPage(
        deadline: SemanticObservationDeadline?,
        observationBoundary: SemanticObservationWaitBoundary,
        discoveryCommitPolicy: DiscoveryCommitPolicy,
        afterViewportMovement: Bool = false
    ) async -> TheVault.State.Current? {
        guard afterViewportMovement
                || (!Task.isCancelled && hasTimeRemaining(before: deadline))
        else { return nil }
        if discoveryCommitPolicy == .replaceInterface {
            vault.semanticObservationStream.discardCurrentObservation()
        }
        return await vault.semanticObservationStream.nextObservation(
            scope: .discovery,
            after: nil,
            boundary: observationBoundary
        )
    }

    private func hasTimeRemaining(before deadline: SemanticObservationDeadline?) -> Bool {
        deadline?.hasTimeRemaining(at: RuntimeElapsed.now) ?? true
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
