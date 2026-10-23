#if canImport(UIKit)
#if DEBUG
import UIKit

import AccessibilitySnapshotParser
import ButtonHeistSupport

import TheScore
import ThePlans

extension Navigation {

    enum DiscoveryCommitPolicy: Equatable, Sendable {
        case mergeIntoInterface
        case replaceInterface
    }

    enum ViewportExplorationDecision: Equatable, Sendable {
        case `continue`
        case goalSatisfied
    }

    enum ViewportExitPosition: Equatable, Sendable {
        case origin
        case current
    }

    enum ViewportExit {}
}

extension Navigation.ViewportExit {
    enum Outcome: Equatable, Sendable {
        case restored
        case retained
        case superseded
        case failed(Failure)
    }

    enum Failure: Equatable, Sendable {
        case originUnavailable
    }
}

extension Navigation {
    enum ViewportSearchOrder: Equatable, Sendable {
        case forwardFirst
        case backwardFirst

        var directions: [ScrollScanDirection] {
            switch self {
            case .forwardFirst:
                [.forward, .back]
            case .backwardFirst:
                [.back, .forward]
            }
        }
    }

    struct ContainerExploration {
        let semanticContainer: InterfaceTree.Container
        let savedVisualOrigin: CGPoint
        let hasHOverflow: Bool
        let hasVOverflow: Bool

        var container: AccessibilityContainer { semanticContainer.container }

        var path: TreePath { semanticContainer.path }
    }

    enum ScrollScanDirection: Equatable, Sendable {
        case forward
        case back
    }

    enum ScrollScanOutcome: Equatable, Sendable {
        case goalSatisfied
        case exhausted
        case screenReplaced
        case limitHit(InterfaceDiscoveryReasonCode)
        case interrupted
    }

    struct InterfaceExplorationResult {
        enum Outcome: Equatable, Sendable {
            case goalSatisfied
            case exhausted
            case cancelled
            case interrupted
        }

        let outcome: Outcome
        let current: TheVault.State.Current
        let progress: InterfaceExplorationProgress
        let didMoveViewport: Bool
        let viewportExit: ViewportExit.Outcome

        var waitResult: WaitExplorationResult {
            let complete: Bool = switch outcome {
            case .goalSatisfied:
                true
            case .exhausted:
                progress.pendingScrollPaths.isEmpty
                    && progress.omittedScrollPathReasons.isEmpty
                    && progress.limitReasons.isEmpty
            case .cancelled, .interrupted:
                false
            }
            return .init(
                viewportExit: viewportExit,
                coverage: complete ? .complete : .incomplete(.explorationIncomplete)
            )
        }

        internal init(
            current: TheVault.State.Current,
            progress: InterfaceExplorationProgress,
            didMoveViewport: Bool = false,
            viewportExit: ViewportExit.Outcome,
            outcome: Outcome
        ) {
            self.outcome = outcome
            self.current = current
            self.progress = progress
            self.didMoveViewport = didMoveViewport
            self.viewportExit = viewportExit
        }
    }

    struct SemanticExploration {
        var progress: InterfaceExplorationProgress
        private(set) var discoveryCommitPolicy: DiscoveryCommitPolicy
        let deadline: SemanticObservationDeadline?
        let observationBoundary: SemanticObservationWaitBoundary

        init(
            startingFresh: Bool,
            deadline: SemanticObservationDeadline? = nil,
            observationBoundary: SemanticObservationWaitBoundary = .cancellation,
            maxScrollsPerContainer: Int = InterfaceExplorationProgress.maxScrollsPerContainer,
            maxScrollsPerDiscovery: Int = InterfaceExplorationProgress.maxScrollsPerDiscovery
        ) {
            // Only the first page can replace: everything after it merges,
            // which is what `recordCommittedObservation` latches.
            discoveryCommitPolicy = startingFresh ? .replaceInterface : .mergeIntoInterface
            self.deadline = deadline
            self.observationBoundary = observationBoundary
            progress = InterfaceExplorationProgress(
                maxScrollsPerContainer: maxScrollsPerContainer,
                maxScrollsPerDiscovery: maxScrollsPerDiscovery
            )
        }

        var hasTimeRemaining: Bool {
            deadline?.hasTimeRemaining(at: RuntimeElapsed.now) ?? true
        }

        mutating func recordCommittedObservation(
            continuity: ScreenContinuity,
            scrollableContainers: [InterfaceTree.Container]
        ) {
            discoveryCommitPolicy = .mergeIntoInterface
            if continuity.isReplacement {
                let scrollCount = progress.scrollCount
                progress = InterfaceExplorationProgress(
                    maxScrollsPerContainer: progress.maxScrollsPerContainer,
                    maxScrollsPerDiscovery: progress.maxScrollsPerDiscovery
                )
                progress.scrollCount = scrollCount
            }
            addDiscoveredContainers(scrollableContainers)
        }

        mutating func markExplored(_ container: InterfaceTree.Container) {
            progress.markExplored(container.path)
        }

        mutating func addDiscoveredContainers(_ containers: [InterfaceTree.Container]) {
            let newContainers = containers.filter {
                !progress.exploredScrollPaths.contains($0.path)
                    && !progress.pendingScrollPaths.contains($0.path)
            }
            progress.addPendingContainers(newContainers)
        }

        mutating func finish(
            startTime: CFTimeInterval,
            current: TheVault.State.Current,
            didMoveViewport: Bool,
            viewportExit: ViewportExit.Outcome,
            outcome: InterfaceExplorationResult.Outcome
        ) -> InterfaceExplorationResult {
            progress.explorationTime = CACurrentMediaTime() - startTime
            return InterfaceExplorationResult(
                current: current,
                progress: progress,
                didMoveViewport: didMoveViewport,
                viewportExit: viewportExit,
                outcome: outcome
            )
        }
    }

    struct WaitExplorationResult: Sendable, Equatable {
        let viewportExit: ViewportExit.Outcome
        let coverage: Observation.Coverage
    }

    func exploreForWait(
        target: ResolvedAccessibilityTarget?,
        deadline: SemanticObservationDeadline,
        maxScrollsPerDiscovery: Int? = nil,
        stopWhen: @escaping @MainActor () -> Bool
    ) async -> WaitExplorationResult {
        guard !stopWhen() else {
            return .init(viewportExit: .restored, coverage: .complete)
        }
        guard deadline.hasTimeRemaining(at: RuntimeElapsed.now) else {
            return .init(viewportExit: .restored, coverage: .incomplete(.explorationIncomplete))
        }
        // Knowing where the element is makes it a seed, not a different search.
        // Inflation goes straight there, then cleanup restores the origin. The
        // same stop condition decides whether that seed answered the wait or
        // the exhaustive pass still needs to search.
        if let target,
           target.isElementTarget,
           case .resolved(.element) = vault.resolveTarget(target) {
            let viewportExit = await elementInflation.inflateForObservation(
                for: target,
                deadline: deadline
            )
            guard viewportExit == .restored else {
                return .init(viewportExit: viewportExit, coverage: .incomplete(.explorationIncomplete))
            }
            if stopWhen() {
                return .init(viewportExit: .restored, coverage: .complete)
            }
            if Task.isCancelled || !deadline.hasTimeRemaining(at: RuntimeElapsed.now) {
                return .init(viewportExit: .restored, coverage: .incomplete(.explorationIncomplete))
            }
        }

        guard let exploration = await exploreScreen(
            target: target,
            startingFresh: true,
            exitPosition: .origin,
            deadline: deadline,
            maxScrollsPerDiscovery: maxScrollsPerDiscovery,
            onObservation: { _ in
                stopWhen() ? .goalSatisfied : .continue
            }
        ) else {
            return .init(viewportExit: .restored, coverage: .incomplete(.explorationIncomplete))
        }
        return exploration.waitResult
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
