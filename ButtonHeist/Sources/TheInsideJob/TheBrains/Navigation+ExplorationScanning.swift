#if canImport(UIKit)
#if DEBUG
import UIKit

import AccessibilitySnapshotParser

import TheScore
import ThePlans

extension Navigation {

    private struct ObservedViewport {
        let current: TheVault.State.Current
        let decision: ViewportExplorationDecision
    }

    private enum OriginRestoreOutcome {
        case observed(ObservedViewport)
        case unchanged
        case unavailable
        case interrupted
    }

    @MainActor
    private final class ViewportOrigin {
        let containerPath: TreePath
        let scrollViewID: ObjectIdentifier
        let visualOrigin: CGPoint
        let physicalContentOffset: CGPoint
        weak var originalScrollView: UIScrollView?

        init(
            containerPath: TreePath,
            scrollView: UIScrollView,
            visualOrigin: CGPoint,
            physicalContentOffset: CGPoint
        ) {
            self.containerPath = containerPath
            scrollViewID = ObjectIdentifier(scrollView)
            self.visualOrigin = visualOrigin
            self.physicalContentOffset = physicalContentOffset
            originalScrollView = scrollView
        }
    }

    @MainActor
    private struct ActiveContainerExploration {
        let semantic: ContainerExploration
        let scrollView: UIScrollView
    }

    private struct PendingContainer {
        let container: InterfaceTree.Container
        let overflow: CGFloat
    }

    @MainActor
    private struct ViewportExplorationState {
        var latestCurrent: TheVault.State.Current?
        var didMoveViewport = false
        var originWasSuperseded = false
        var exploredScrollViewIDs = Set<ObjectIdentifier>()
        var origins: [ViewportOrigin] = []

        mutating func resetSemanticViewportMemory() {
            exploredScrollViewIDs.removeAll()
        }

        mutating func recordOrigin(
            containerPath: TreePath,
            scrollView: UIScrollView,
            visualOrigin: CGPoint
        ) {
            let scrollViewID = ObjectIdentifier(scrollView)
            guard !origins.contains(where: { $0.scrollViewID == scrollViewID }) else { return }
            origins.append(ViewportOrigin(
                containerPath: containerPath,
                scrollView: scrollView,
                visualOrigin: visualOrigin,
                physicalContentOffset: scrollView.contentOffset
            ))
        }
    }

    @MainActor
    final class ViewportExplorer {
        private let navigation: Navigation
        private let revealRootScrollViewID: ObjectIdentifier?
        private let searchOrder: ViewportSearchOrder
        private var exploration: SemanticExploration
        private var state = ViewportExplorationState()

        init(
            navigation: Navigation,
            exploration: SemanticExploration,
            searchOrder: ViewportSearchOrder,
            revealRootScrollViewID: ObjectIdentifier? = nil,
        ) {
            self.navigation = navigation
            self.exploration = exploration
            self.searchOrder = searchOrder
            self.revealRootScrollViewID = revealRootScrollViewID
        }

        func exploreViewports(
            exitPosition: ViewportExitPosition,
            onObservation: (TheVault.State.Current) async -> ViewportExplorationDecision
        ) async -> InterfaceExplorationResult? {
            let startTime = CACurrentMediaTime()
            let outcome: InterfaceExplorationResult.Outcome

            if let initial = await observe(onObservation: onObservation) {
                if initial.decision == .goalSatisfied {
                    exploration.progress.clearPendingContainers()
                    outcome = .goalSatisfied
                } else {
                    outcome = await scanPendingContainers(
                        onObservation: onObservation
                    )
                }
            } else {
                outcome = Task.isCancelled ? .cancelled : .interrupted
            }

            // Only a found element earns its scroll position, because the caller
            // is about to act on it. A pass that ended any other way leaves the
            // screen as it found it: a discovery walked the containers to read
            // them, and a search that came back empty moved them for nothing.
            let viewportExit = await finalize(
                exitPosition: outcome == .goalSatisfied ? exitPosition : .origin,
                termination: outcome,
                notifyObservation: outcome != .goalSatisfied,
                onObservation: onObservation
            )
            guard let latestCurrent = state.latestCurrent else { return nil }
            return exploration.finish(
                startTime: startTime,
                current: latestCurrent,
                didMoveViewport: state.didMoveViewport,
                viewportExit: viewportExit,
                outcome: outcome
            )
        }

        private func scanPendingContainers(
            onObservation: (TheVault.State.Current) async -> ViewportExplorationDecision
        ) async -> InterfaceExplorationResult.Outcome {
            while !exploration.progress.pendingScrollPaths.isEmpty {
                guard !Task.isCancelled else { return .cancelled }
                guard exploration.hasTimeRemaining else { return .interrupted }
                guard exploration.progress.scrollCount < exploration.progress.maxScrollsPerDiscovery else {
                    exploration.progress.markLimitHit(.discoveryScrollLimit)
                    return .exhausted
                }

                let batch = sortedPendingContainers()
                guard !batch.isEmpty else {
                    exploration.progress.clearPendingContainers()
                    return .exhausted
                }

                for container in batch {
                    guard !Task.isCancelled else { return .cancelled }
                    guard exploration.hasTimeRemaining else { return .interrupted }
                    guard exploration.progress.scrollCount < exploration.progress.maxScrollsPerDiscovery else {
                        exploration.progress.markLimitHit(.discoveryScrollLimit)
                        return .exhausted
                    }
                    guard let containerExploration = prepareContainerExploration(for: container) else {
                        exploration.markExplored(container)
                        continue
                    }
                    recordOrigin(of: containerExploration)

                    let outcome = await scanContainer(
                        containerExploration,
                        onObservation: onObservation
                    )
                    switch outcome {
                    case .goalSatisfied:
                        markExplored(containerExploration)
                        return .goalSatisfied
                    case .exhausted:
                        markExplored(containerExploration)
                    case .screenReplaced:
                        return .exhausted
                    case .limitHit(let reason):
                        exploration.progress.markOmitted(containerExploration.semantic.path, reason: reason)
                    case .interrupted:
                        return Task.isCancelled ? .cancelled : .interrupted
                    }
                }
            }
            return .exhausted
        }

        private func sortedPendingContainers() -> [InterfaceTree.Container] {
            var admittedScrollViewIDs = state.exploredScrollViewIDs
            return exploration.progress.pendingScrollPaths
                .sorted()
                .compactMap { navigation.vault.interfaceTree.viewportOnly.containers[$0] }
                .compactMap { container -> PendingContainer? in
                    guard let target = currentProgrammaticScrollTarget(for: container.path),
                          case .uiScrollView(_, let scrollView) = target,
                          admittedScrollViewIDs.insert(ObjectIdentifier(scrollView)).inserted
                    else { return nil }
                    return PendingContainer(
                        container: container,
                        overflow: totalOverflow(of: container.container)
                    )
                }
                .sorted {
                    $0.overflow == $1.overflow
                        ? $0.container.path < $1.container.path
                        : $0.overflow > $1.overflow
                }
                .map(\.container)
        }

        private func prepareContainerExploration(
            for semanticContainer: InterfaceTree.Container
        ) -> ActiveContainerExploration? {
            let container = semanticContainer.container
            guard let contentSize = container.scrollableContentSize else { return nil }
            guard let target = currentProgrammaticScrollTarget(for: semanticContainer.path),
                  case .uiScrollView(_, let scrollView) = target else { return nil }
            guard !state.exploredScrollViewIDs.contains(ObjectIdentifier(scrollView)),
                  scrollView.window != nil,
                  !scrollView.bhIsUnsafeForProgrammaticScrolling,
                  !Navigation.isObscuredByPresentation(view: scrollView) else { return nil }

            let savedVisualOrigin = Navigation.visualOrigin(in: scrollView)

            let hasHOverflow = contentSize.width > container.frame.width + 1
            let hasVOverflow = contentSize.height > container.frame.height + 1
            guard hasHOverflow || hasVOverflow else { return nil }

            return ActiveContainerExploration(
                semantic: ContainerExploration(
                    semanticContainer: semanticContainer,
                    savedVisualOrigin: savedVisualOrigin,
                    hasHOverflow: hasHOverflow,
                    hasVOverflow: hasVOverflow
                ),
                scrollView: scrollView
            )
        }

        private func scanContainer(
            _ container: ActiveContainerExploration,
            onObservation: (TheVault.State.Current) async -> ViewportExplorationDecision
        ) async -> ScrollScanOutcome {
            for (index, direction) in searchOrder.directions.enumerated() {
                let outcome = await runScrollScan(
                    container,
                    direction: direction,
                    onObservation: onObservation
                )
                guard outcome == .exhausted else { return outcome }

                guard index == 0 else { return .exhausted }
                switch await restoreOrigin(
                    visualOrigin: container.semantic.savedVisualOrigin,
                    physicalContentOffset: nil,
                    containerPath: container.semantic.path,
                    scrollViewID: ObjectIdentifier(container.scrollView),
                    originalScrollView: container.scrollView,
                    deadline: exploration.deadline,
                    observationBoundary: exploration.observationBoundary,
                    onObservation: onObservation
                ) {
                case .observed(let observation):
                    if observation.decision == .goalSatisfied { return .goalSatisfied }
                    if observation.current.continuity.isReplacement { return .screenReplaced }
                case .unchanged:
                    break
                case .unavailable, .interrupted:
                    return .interrupted
                }
            }
            return .exhausted
        }

        private func runScrollScan(
            _ container: ActiveContainerExploration,
            direction: ScrollScanDirection,
            onObservation: (TheVault.State.Current) async -> ViewportExplorationDecision
        ) async -> ScrollScanOutcome {
            while exploration.hasTimeRemaining {
                guard !Task.isCancelled else { return .interrupted }
                if let reason = exploration.progress.recordScrollAttempt(in: container.semantic.path) {
                    return .limitHit(reason)
                }
                guard let target = currentProgrammaticScrollTarget(for: container) else { return .exhausted }

                let transition = await navigation.performViewportTransition(
                    .page(
                        target,
                        direction: pageDirection(for: container, scanDirection: direction),
                        animated: false
                    ),
                    deadline: exploration.deadline,
                    observationBoundary: exploration.observationBoundary,
                    discoveryCommitPolicy: exploration.discoveryCommitPolicy
                )
                switch transition.outcome {
                case .unchanged:
                    return .exhausted
                case .unavailable:
                    return Task.isCancelled ? .interrupted : .exhausted
                case .moved:
                    state.didMoveViewport = true
                }
                guard let current = transition.current else { return .interrupted }
                let observation = await record(
                    current,
                    notifyObservation: true,
                    onObservation: onObservation
                )
                if observation.decision == .goalSatisfied { return .goalSatisfied }
                if state.originWasSuperseded { return .screenReplaced }
                if container.scrollView.window == nil {
                    if let replacement = currentProgrammaticScrollTarget(
                        for: container.semantic.semanticContainer.path
                    ), case .uiScrollView(_, let replacementScrollView) = replacement,
                       ObjectIdentifier(replacementScrollView) != ObjectIdentifier(container.scrollView) {
                        state.originWasSuperseded = true
                        return .screenReplaced
                    }
                    return .interrupted
                }
                if let nestedOutcome = await scanNewlyVisibleNestedContainers(
                    inside: container,
                    onObservation: onObservation
                ) {
                    return nestedOutcome
                }
            }
            return .interrupted
        }

        private func scanNewlyVisibleNestedContainers(
            inside parent: ActiveContainerExploration,
            onObservation: (TheVault.State.Current) async -> ViewportExplorationDecision
        ) async -> ScrollScanOutcome? {
            guard let parentTarget = currentProgrammaticScrollTarget(for: ObjectIdentifier(parent.scrollView)),
                  case .uiScrollView(_, let parentScrollView) = parentTarget
            else {
                return .interrupted
            }
            let nestedContainers = sortedPendingContainers().filter {
                guard currentProgrammaticScrollTarget(for: $0.path) != nil else { return false }
                return navigation.vault.isDirectLiveScrollChild(
                    at: $0.path,
                    of: parentScrollView
                )
            }
            for semanticContainer in nestedContainers {
                guard !Task.isCancelled, exploration.hasTimeRemaining else { return .interrupted }
                guard let nested = prepareContainerExploration(for: semanticContainer) else {
                    exploration.markExplored(semanticContainer)
                    continue
                }
                recordOrigin(of: nested)
                let outcome = await scanContainer(
                    nested,
                    onObservation: onObservation
                )
                switch outcome {
                case .goalSatisfied:
                    markExplored(nested)
                    return outcome
                case .exhausted:
                    markExplored(nested)
                case .screenReplaced, .interrupted:
                    return outcome
                case .limitHit(let reason):
                    exploration.progress.markOmitted(nested.semantic.path, reason: reason)
                    if reason == .discoveryScrollLimit { return outcome }
                }
            }
            return nil
        }

        private func pageDirection(
            for container: ActiveContainerExploration,
            scanDirection: ScrollScanDirection
        ) -> UIAccessibilityScrollDirection {
            switch (container.semantic.hasVOverflow, scanDirection) {
            case (true, .forward):
                .down
            case (true, .back):
                .up
            case (false, .forward):
                .right
            case (false, .back):
                .left
            }
        }

        private func observe(
            onObservation: (TheVault.State.Current) async -> ViewportExplorationDecision
        ) async -> ObservedViewport? {
            guard let current = await navigation.settledExplorationPage(
                deadline: exploration.deadline,
                observationBoundary: exploration.observationBoundary,
                discoveryCommitPolicy: exploration.discoveryCommitPolicy
            ) else { return nil }
            return await record(
                current,
                establishesBaseline: true,
                notifyObservation: true,
                onObservation: onObservation
            )
        }

        private func record(
            _ current: TheVault.State.Current,
            establishesBaseline: Bool = false,
            notifyObservation: Bool,
            onObservation: (TheVault.State.Current) async -> ViewportExplorationDecision
        ) async -> ObservedViewport {
            state.latestCurrent = current
            if current.continuity.isReplacement {
                if !establishesBaseline {
                    state.originWasSuperseded = true
                }
                state.resetSemanticViewportMemory()
            }
            exploration.recordCommittedObservation(
                continuity: current.continuity,
                scrollableContainers: currentScrollableContainers()
            )
            return ObservedViewport(
                current: current,
                decision: notifyObservation ? await onObservation(current) : .continue
            )
        }

        private func finalize(
            exitPosition: ViewportExitPosition,
            termination: InterfaceExplorationResult.Outcome,
            notifyObservation: Bool,
            onObservation: (TheVault.State.Current) async -> ViewportExplorationDecision
        ) async -> ViewportExit.Outcome {
            if state.originWasSuperseded { return .superseded }
            guard exitPosition == .origin else { return .retained }
            guard !state.origins.isEmpty else { return .restored }

            for viewportOrigin in state.origins.reversed() {
                switch await restoreOrigin(
                    visualOrigin: viewportOrigin.visualOrigin,
                    physicalContentOffset: termination == .cancelled
                        ? viewportOrigin.physicalContentOffset
                        : nil,
                    containerPath: viewportOrigin.containerPath,
                    scrollViewID: viewportOrigin.scrollViewID,
                    originalScrollView: viewportOrigin.originalScrollView,
                    deadline: nil,
                    observationBoundary: termination == .cancelled
                        ? .observationCycle
                        : exploration.observationBoundary,
                    notifyObservation: notifyObservation,
                    onObservation: onObservation
                ) {
                case .observed(let observation):
                    if observation.current.continuity.isReplacement { return .superseded }
                case .unchanged:
                    continue
                case .unavailable, .interrupted:
                    return .failed(.originUnavailable)
                }
            }
            return .restored
        }

        private func restoreOrigin(
            visualOrigin: CGPoint,
            physicalContentOffset: CGPoint?,
            containerPath: TreePath,
            scrollViewID: ObjectIdentifier,
            originalScrollView: UIScrollView?,
            deadline: SemanticObservationDeadline?,
            observationBoundary: SemanticObservationWaitBoundary,
            notifyObservation: Bool = true,
            onObservation: (TheVault.State.Current) async -> ViewportExplorationDecision
        ) async -> OriginRestoreOutcome {
            let intent: ViewportMovementIntent
            if let physicalContentOffset,
               let originalScrollView,
               ObjectIdentifier(originalScrollView) == scrollViewID,
               originalScrollView.window != nil,
               !originalScrollView.bhIsUnsafeForProgrammaticScrolling,
               !Navigation.isObscuredByPresentation(view: originalScrollView) {
                intent = .restoreContentOffset(physicalContentOffset, in: .original(originalScrollView))
            } else if let target = currentProgrammaticScrollTarget(for: containerPath),
               case .uiScrollView = target {
                intent = physicalContentOffset.map { .restoreContentOffset($0, in: .semantic(target)) }
                    ?? .restoreVisualOrigin(visualOrigin, in: .semantic(target))
            } else if let target = currentProgrammaticScrollTarget(for: scrollViewID),
               case .uiScrollView = target {
                intent = physicalContentOffset.map { .restoreContentOffset($0, in: .semantic(target)) }
                    ?? .restoreVisualOrigin(visualOrigin, in: .semantic(target))
            } else if let originalScrollView,
                      ObjectIdentifier(originalScrollView) == scrollViewID,
                      originalScrollView.window != nil,
                      !originalScrollView.bhIsUnsafeForProgrammaticScrolling,
                      !Navigation.isObscuredByPresentation(view: originalScrollView) {
                intent = physicalContentOffset.map { .restoreContentOffset($0, in: .original(originalScrollView)) }
                    ?? .restoreVisualOrigin(visualOrigin, in: .original(originalScrollView))
            } else {
                return .unavailable
            }
            let transition = await navigation.performViewportTransition(
                intent,
                deadline: deadline,
                observationBoundary: observationBoundary,
                discoveryCommitPolicy: exploration.discoveryCommitPolicy
            )
            switch transition.outcome {
            case .unavailable:
                return .unavailable
            case .unchanged:
                return .unchanged
            case .moved:
                state.didMoveViewport = true
                guard let current = transition.current else { return .interrupted }
                return .observed(await record(
                    current,
                    notifyObservation: notifyObservation,
                    onObservation: onObservation
                ))
            }
        }

        private func currentProgrammaticScrollTarget(
            for container: ActiveContainerExploration
        ) -> ScrollableTarget? {
            if let exactTarget = currentProgrammaticScrollTarget(for: container.semantic.path),
               case .uiScrollView(_, let scrollView) = exactTarget,
               ObjectIdentifier(scrollView) == ObjectIdentifier(container.scrollView) {
                return exactTarget
            }
            return currentProgrammaticScrollTarget(for: ObjectIdentifier(container.scrollView))
        }

        private func currentProgrammaticScrollTarget(
            for scrollViewID: ObjectIdentifier
        ) -> ScrollableTarget? {
            for container in navigation.vault.interfaceTree.viewportOnly.orderedContainers {
                guard let target = currentProgrammaticScrollTarget(for: container.path),
                      case .uiScrollView(_, let scrollView) = target,
                      ObjectIdentifier(scrollView) == scrollViewID
                else { continue }
                return target
            }
            return nil
        }

        private func currentProgrammaticScrollTarget(for path: TreePath) -> ScrollableTarget? {
            guard let semanticContainer = navigation.vault.interfaceTree.viewportOnly.containers[path],
                  let target = navigation.scrollableTarget(for: semanticContainer),
                  case .uiScrollView(_, let scrollView) = target,
                  isDescendedFromRevealRoot(scrollView)
            else { return nil }
            return target
        }

        private func currentScrollableContainers() -> [InterfaceTree.Container] {
            navigation.vault.interfaceTree.viewportOnly.orderedContainers.filter { container in
                currentProgrammaticScrollTarget(for: container.path) != nil
            }
        }

        private func isDescendedFromRevealRoot(_ scrollView: UIScrollView) -> Bool {
            guard let revealRootScrollViewID else { return true }
            var current = ObjectIdentifier(scrollView)
            var visited = Set<ObjectIdentifier>()
            while visited.insert(current).inserted {
                if current == revealRootScrollViewID { return true }
                guard let parent = navigation.vault.currentLiveCapture.parentScrollViewID(of: current) else {
                    return false
                }
                current = parent
            }
            return false
        }

        private func markExplored(_ container: ActiveContainerExploration) {
            state.exploredScrollViewIDs.insert(ObjectIdentifier(container.scrollView))
            exploration.markExplored(container.semantic.semanticContainer)
        }

        private func recordOrigin(of container: ActiveContainerExploration) {
            state.recordOrigin(
                containerPath: container.semantic.path,
                scrollView: container.scrollView,
                visualOrigin: container.semantic.savedVisualOrigin
            )
        }

        private func totalOverflow(of container: AccessibilityContainer) -> CGFloat {
            guard let contentSize = container.scrollableContentSize else { return 0 }
            return max(0, contentSize.width - container.frame.width)
                + max(0, contentSize.height - container.frame.height)
        }

    }

    private enum SemanticTargetScanMatch {
        case visible(InterfaceTree.Element)
        case offscreen
        case failed(ElementInflation.SemanticTargetResolutionFailure)
    }

    /// What one stored seed did for a reveal request.
    private enum StoredSeedOutcome {
        /// The seed put the target on screen.
        case revealed(InterfaceTree.Element, InterfaceExplorationResult)
        /// The target could not be resolved at all.
        case failed(ElementInflation.SemanticTargetResolutionFailure)
        case continueExploration
    }

    func scanForSemanticTarget(
        _ request: ElementInflation.SemanticTargetRevealRequest
    ) async -> ElementInflation.SemanticTargetScanResult {
        var visibleTarget: InterfaceTree.Element?
        var resolutionFailure: ElementInflation.SemanticTargetResolutionFailure?
        switch await moveToStoredSeed(request: request) {
        case .revealed(let current, let exploration):
            return .revealed(current, exploration)
        case .failed(let failure):
            return .failed(failure)
        case .continueExploration:
            break
        }
        let explorer = ViewportExplorer(
            navigation: self,
            exploration: SemanticExploration(
                startingFresh: false,
                deadline: request.deadline
            ),
            searchOrder: .forwardFirst,
            revealRootScrollViewID: request.revealRootScrollViewID,
        )
        let explored = await explorer.exploreViewports(exitPosition: .current) { _ in
            switch self.semanticTargetScanMatch(request.target) {
            case .visible(let current):
                visibleTarget = current
                return .goalSatisfied
            case .failed(let failure):
                resolutionFailure = failure
                return .goalSatisfied
            case .offscreen:
                return .continue
            }
        }
        if let resolutionFailure {
            return .failed(resolutionFailure)
        }
        guard let visibleTarget, let explored else { return .unavailable }
        return .revealed(visibleTarget, explored)
    }

    /// Scrolls straight to where the target was last seen.
    ///
    /// A seed is one remembered content point in one scroll container, so it is
    /// spent in a single move and either puts the target on screen or does not.
    /// Sweeping every viewport is the slower answer the caller falls back on.
    private func moveToStoredSeed(
        request: ElementInflation.SemanticTargetRevealRequest
    ) async -> StoredSeedOutcome {
        guard storedSeedPoint(for: request.target) != nil else {
            return .continueExploration
        }
        guard case .committed =
            await vault.semanticObservationStream.refreshedVisibleObservation(
                boundary: .cancellation
            )
        else {
            return .continueExploration
        }
        guard let rememberedOwnerPath = request.target.scrollContainerPath else {
            return .continueExploration
        }
        guard let point = storedSeedPoint(for: request.target) else {
            return .continueExploration
        }
        guard let semanticContainer = vault.interfaceTree.containers[rememberedOwnerPath] else {
            return .continueExploration
        }
        guard let liveTarget = vault.liveScrollTarget(reacquiring: semanticContainer) else {
            return .continueExploration
        }
        guard !liveTarget.scrollView.bhIsUnsafeForProgrammaticScrolling else {
            return .continueExploration
        }
        let transition = await performViewportTransition(
            .revealViewPoint(
                point,
                in: .uiScrollView(
                    container: liveTarget.container,
                    scrollView: liveTarget.scrollView
                )
            ),
            deadline: request.deadline
        )
        guard transition.outcome == .moved,
              let current = transition.current
        else { return .continueExploration }
        let exploration = InterfaceExplorationResult(
            current: current,
            progress: .init(),
            didMoveViewport: true,
            viewportExit: .retained,
            outcome: .goalSatisfied
        )
        switch semanticTargetScanMatch(request.target) {
        case .visible(let current):
            return .revealed(current, exploration)
        case .failed(let failure):
            return .failed(failure)
        case .offscreen:
            return .continueExploration
        }
    }

    private func storedSeedPoint(
        for target: ElementInflation.AdmittedSemanticTarget
    ) -> ViewPoint? {
        guard case .resolved(.element(let currentElement)) = vault.resolveTarget(target.target),
              let ownerPath = target.scrollContainerPath
        else { return nil }
        guard case .available(let available) = currentElement.geometry.view.admitted(ownedBy: ownerPath) else {
            return nil
        }
        return available.activationPoint
    }

    private func semanticTargetScanMatch(
        _ target: ElementInflation.AdmittedSemanticTarget
    ) -> SemanticTargetScanMatch {
        switch vault.resolveVisibleTarget(target.target) {
        case .resolved(.element(let current)):
            return .visible(current)
        case .resolved(.container):
            return .failed(.containerTarget)
        case .notFound:
            break
        case .ambiguous(let facts):
            return .failed(.ambiguous(
                TargetResolutionDiagnostics.message(for: .ambiguous(facts))
            ))
        }

        switch vault.resolveTarget(target.target) {
        case .resolved(.element):
            return .offscreen
        case .resolved(.container):
            return .failed(.containerTarget)
        case .notFound(let facts):
            return .failed(.notFound(
                TargetResolutionDiagnostics.message(for: .notFound(facts))
            ))
        case .ambiguous(let facts):
            return .failed(.ambiguous(
                TargetResolutionDiagnostics.message(for: .ambiguous(facts))
            ))
        }
    }

    static func visualOrigin(in scrollView: UIScrollView) -> CGPoint {
        CGPoint(
            x: scrollView.contentOffset.x + scrollView.adjustedContentInset.left,
            y: scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        )
    }

}

#endif // DEBUG
#endif // canImport(UIKit)
