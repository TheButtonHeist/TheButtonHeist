#if canImport(UIKit)
#if DEBUG
import Foundation
import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension HeistExecution {
    internal enum Decision {
        case perform(Effect)
        case wait(WaitRequest)
        case complete(Completion)
    }

    /// A boundary operation requested by the pure reducer.
    internal enum Effect {
        case currentSnapshot(
            EffectID,
            scope: SemanticObservationScope,
            deadline: SemanticObservationDeadline
        )
        case beginObservation(
            EffectID,
            scope: SemanticObservationScope,
            deadline: SemanticObservationDeadline
        )
        case dispatch(EffectID, ResolvedHeistActionCommand, deadline: SemanticObservationDeadline)
        case explore(EffectID, Predicate, deadline: SemanticObservationDeadline)
        case sampleObservationClose(
            effectID: EffectID,
            observationID: EffectID,
            exitPosition: Navigation.ViewportExitPosition,
            capture: ObservationCloseCapture,
            source: ObservationCloseSource
        )
        case commitObservationClose(EffectID, observationID: EffectID)
        case captureFailureScreenshot(
            EffectID,
            failedPath: HeistExecutionPath,
            mode: ScreenCaptureMode
        )
        case cancelObservation(EffectID, observationID: EffectID?)
    }

    /// A fact received by the pure reducer.
    internal enum Event {
        case currentSnapshot(EffectID, Observation.Snapshot?, at: RuntimeElapsed.Instant)
        case observationBegan(EffectID, baseline: Observation.Snapshot?, at: RuntimeElapsed.Instant)
        case observation(EffectID, Observation.Event, at: RuntimeElapsed.Instant)
        case dispatchCompleted(EffectID, TheSafecracker.ActionDispatchResult, at: RuntimeElapsed.Instant)
        case explorationCompleted(EffectID, Navigation.WaitExplorationResult, at: RuntimeElapsed.Instant)
        case observationCloseSampled(
            EffectID,
            source: ObservationCloseSource,
            observationID: EffectID,
            evidence: Observation.Evidence,
            close: ObservationClose,
            at: RuntimeElapsed.Instant
        )
        case failureScreenshotCaptured(EffectID, HeistFailureCapture, at: RuntimeElapsed.Instant)
        case deadlineElapsed(EffectID, at: RuntimeElapsed.Instant)
        case cancellationRequested(at: RuntimeElapsed.Instant)
        case cancellationCompleted(EffectID, at: RuntimeElapsed.Instant)
        case observationCloseCommitted(EffectID, at: RuntimeElapsed.Instant)
    }

    /// Raw boundary facts from one observation-close attempt.
    internal struct ObservationClose: Sendable, Equatable {
        internal let captureAvailable: Bool
        internal let viewportExit: Navigation.ViewportExit.Outcome?
        internal let lastTreeChangeAt: RuntimeElapsed.Instant?

    }

    /// The next external fact the reducer may admit.
    internal struct WaitRequest: Sendable, Equatable {
        internal let id: EffectID
        internal let deadline: SemanticObservationDeadline
    }

    internal struct Completion {
        internal enum Outcome: Sendable, Equatable {
            case completed
            case cancelled
        }

        internal let steps: [HeistExecutionStepResult]
        internal let failureCapture: HeistFailureCapture?
        internal let outcome: Outcome
    }

}

extension HeistExecution {
    internal struct EffectID: RawRepresentable, Sendable, Equatable, Hashable {
        internal let rawValue: UInt64
    }

    internal struct Predicate: Sendable, Equatable {
        internal let authored: AccessibilityPredicate
        internal let resolved: ObservationPredicate
        internal let bindings: HeistExecutionEnvironment

        internal init(
            authored: AccessibilityPredicate,
            bindings: HeistExecutionEnvironment
        ) throws {
            self.authored = authored
            self.resolved = try authored.resolve(in: bindings)
            self.bindings = bindings
        }

        internal var observationScope: SemanticObservationScope {
            resolved.observationScope
        }

        internal var isNotification: Bool {
            if case .notification = resolved { return true }
            return false
        }

        internal func canPrepareTarget(in snapshot: Observation.Snapshot?) -> Bool {
            guard case .elementsChanged(let assertions) = resolved,
                  assertions.count == 1,
                  case .missing(let target) = assertions[0]
            else { return true }
            return snapshot != nil && Expectation(
                [.elementsChanged([.exists(target)])], baseline: snapshot
            ).result != .satisfied
        }
    }

    internal enum ActionObservationExpectation: Sendable {
        case authored(Predicate)
        case none

        internal init(
            _ policy: ActionExpectationPolicy,
            bindings: HeistExecutionEnvironment
        ) throws {
            switch policy {
            case .expect(let expectation):
                self = .authored(try Predicate(
                    authored: expectation.predicate,
                    bindings: bindings
                ))
            case .default, .waived:
                self = .none
            }
        }

        internal var authoredPredicates: [ObservationPredicate] {
            switch self {
            case .authored(let predicate):
                [predicate.resolved]
            case .none:
                []
            }
        }

        internal var authoredPredicate: Predicate? {
            guard case .authored(let predicate) = self else { return nil }
            return predicate
        }

        internal var observationScope: SemanticObservationScope {
            authoredPredicate?.observationScope ?? .visible
        }
    }

    internal enum LeafOutcome: Sendable, Equatable {
        case completed
        case timedOut
        case heistTimedOut
        case cancelled
        case unavailable
        case viewportExitFailed(Navigation.ViewportExit.Failure)
    }

    internal enum ObservationCloseSource: Sendable, Equatable {
        case request
        case deadline
    }

    internal enum ObservationCloseCapture: Sendable, Equatable {
        case coverage
        case refresh
        case nextCycle
    }
}

extension HeistExecution {
    internal struct Scope: Sendable {
        internal let rootPlan: HeistPlan
        internal let plan: HeistPlan
        internal let definitionPath: [HeistPlanName]
        internal let invocationStack: Set<HeistInvocationPath>

        internal init(
            plan: HeistPlan,
            rootPlan: HeistPlan? = nil,
            definitionPath: [HeistPlanName] = [],
            invocationStack: Set<HeistInvocationPath> = []
        ) {
            self.rootPlan = rootPlan ?? plan
            self.plan = plan
            self.definitionPath = definitionPath
            self.invocationStack = invocationStack
        }
    }

    internal struct StepContext: Sendable {
        internal let path: HeistExecutionPath
        internal let environment: HeistExecutionEnvironment
        internal let scope: Scope
    }

    /// The suspended control-flow operation resumed after the active leaf.
    internal enum Continuation: Sendable {
        case sequence(SequenceContinuation)
        case inline(InlineContinuation)
        case conditional(ConditionalContinuation)
        case forEachElement(ForEachElementContinuation)
        case forEachString(ForEachStringContinuation)
        case repeatUntil(RepeatUntilContinuation)
        case invocation(InvocationContinuation)
        case waitElse(WaitElseContinuation)
    }

    internal struct SequenceContinuation: Sendable {
        internal let steps: [HeistStep]
        internal let context: StepContext
        internal var nextIndex: Int
        internal var children: HeistExecutedChildren
    }

    internal struct InlineContinuation: Sendable {
        internal let plan: HeistPlan
        internal let context: StepContext
    }

    internal struct ConditionalContinuation: Sendable {
        internal let step: ConditionalStep
        internal let context: StepContext
        internal let progress: ConditionalProgress
    }

    internal enum ConditionalProgress: Sendable {
        case awaitingSnapshot
        case selected(HeistCaseSelectionResult)
    }

    internal struct ForEachElementContinuation: Sendable {
        internal let step: ForEachElementStep
        internal let context: StepContext
        internal let resolvedMatching: ResolvedElementPredicate
        internal let matchedCount: Int
        internal var iterationIndex: Int
        internal let progress: ForEachElementProgress
        internal var iterations: HeistExecutedChildren
    }

    internal enum ForEachElementProgress: Sendable {
        case awaitingSnapshot(previousMatchHash: SemanticHash?)
        case executing(targetOrdinal: Int, matchHash: SemanticHash)
    }

    internal struct ForEachStringContinuation: Sendable {
        internal let step: ForEachStringStep
        internal let context: StepContext
        internal var iterationIndex: Int
        internal var iterations: HeistExecutedChildren
    }

    internal struct RepeatUntilContinuation: Sendable {
        internal let step: RepeatUntilStep
        internal let resolved: ResolvedRepeatUntilStep
        internal let predicate: Predicate
        internal let context: StepContext
        internal var iterationIndex: Int
        internal var iterations: HeistExecutedChildren
    }

    internal struct InvocationContinuation: Sendable {
        internal let step: HeistInvocationStep
        internal let context: StepContext
        internal let resolvedPath: HeistInvocationPath
    }

    internal struct WaitElseContinuation: Sendable {
        internal let step: WaitStep
        internal let context: StepContext
        internal let evidence: HeistPassedWaitEvidence
    }
}

extension HeistExecution {
    internal enum ActiveLeaf: Sendable {
        case beginningAction(ActionLeaf)
        case dispatching(ActionLeaf, expectation: Expectation, baseline: Observation.Snapshot?)
        case beginningWait(WaitLeaf)
        case observing(ObservedLeaf)
        case exploring(ObservedLeaf)
        case finishing(
            ObservedLeaf,
            source: ObservationCloseSource,
            didCaptureDeadlineStability: Bool
        )
        case committing(
            ObservedLeaf,
            evidence: Observation.Evidence,
            timing: HeistExpectationTiming,
            outcome: LeafOutcome
        )

        internal var id: EffectID {
            switch self {
            case .beginningAction(let leaf), .dispatching(let leaf, _, _):
                leaf.id
            case .beginningWait(let leaf):
                leaf.id
            case .observing(let leaf),
                 .exploring(let leaf),
                 .finishing(let leaf, _, _),
                 .committing(let leaf, _, _, _):
                leaf.id
            }
        }

        internal var observed: ObservedLeaf? {
            switch self {
            case .observing(let leaf),
                 .exploring(let leaf),
                 .finishing(let leaf, _, _),
                 .committing(let leaf, _, _, _):
                leaf
            case .beginningAction, .dispatching, .beginningWait:
                nil
            }
        }

        internal var action: ActionLeaf? {
            switch self {
            case .beginningAction(let leaf), .dispatching(let leaf, _, _):
                return leaf
            case .observing(let leaf),
                 .exploring(let leaf),
                 .finishing(let leaf, _, _),
                 .committing(let leaf, _, _, _):
                guard case .action(let action, _) = leaf.subject else { return nil }
                return action
            case .beginningWait:
                return nil
            }
        }

        internal var wait: WaitLeaf? {
            switch self {
            case .beginningWait(let leaf):
                return leaf
            case .observing(let leaf),
                 .exploring(let leaf),
                 .finishing(let leaf, _, _),
                 .committing(let leaf, _, _, _):
                guard case .wait(let wait) = leaf.subject else { return nil }
                return wait
            case .beginningAction, .dispatching:
                return nil
            }
        }
    }

    internal struct ObservedLeaf: Sendable {
        internal enum Subject: Sendable {
            case action(ActionLeaf, dispatch: TheSafecracker.ActionDispatchResult)
            case wait(WaitLeaf)
        }

        internal let subject: Subject
        internal var expectation: Expectation
        internal var explorationCoverage: Observation.Coverage = .complete

        internal var isExplorationSufficient: Bool {
            explorationCoverage == .complete || !expectation.requiresCompleteExploration
        }

        internal var id: EffectID {
            switch subject {
            case .action(let leaf, _):
                leaf.id
            case .wait(let leaf):
                leaf.id
            }
        }

        internal func expectationIsProven(
            by evidence: Observation.Evidence
        ) -> Bool {
            proves(by: evidence, requiringNoChange: true)
        }

        internal func needsStabilityCapture(
            after evidence: Observation.Evidence
        ) -> Bool {
            proves(by: evidence, requiringNoChange: false)
                && !expectationIsProven(by: evidence)
        }

        private func proves(
            by evidence: Observation.Evidence,
            requiringNoChange: Bool
        ) -> Bool {
            isExplorationSufficient && evidence.coverage == .complete && Expectation(
                authoredPredicates,
                baseline: evidence.baseline,
                events: evidence.events,
                requiringNoChange: requiringNoChange
            ).result == .satisfied
        }

        private var authoredPredicates: [ObservationPredicate] {
            switch subject {
            case .action(let leaf, _):
                leaf.expectation.authoredPredicates
            case .wait(let leaf):
                [leaf.predicate.resolved]
            }
        }
    }

    internal struct ActionLeaf: Sendable {
        internal let id: EffectID
        internal let step: ActionStep
        internal let command: ResolvedHeistActionCommand
        internal let expectation: ActionObservationExpectation
        internal let path: HeistExecutionPath
    }

    internal struct WaitLeaf: Sendable {
        internal let id: EffectID
        internal let predicate: Predicate
        internal let purpose: WaitPurpose
    }

    internal enum WaitPurpose: Sendable {
        case authored(step: WaitStep, context: StepContext)
        case repeatCheck(loop: RepeatUntilContinuation, bodyChildren: HeistPassingChildren)
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
