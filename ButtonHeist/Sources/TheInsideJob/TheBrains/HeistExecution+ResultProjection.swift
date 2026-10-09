#if canImport(UIKit)
#if DEBUG
import Foundation
import ThePlans
import TheScore

extension HeistExecution {
    internal enum ResultProjector {
        internal static func actionResolutionFailure(
            step: ActionStep,
            path: HeistExecutionPath,
            error: Error
        ) -> HeistExecutionStepResult {
            let evidence = HeistActionEvidence.commandResolutionFailure
            return .action(
                path: path,
                execution: .failed(
                    command: step.command,
                    evidence: .init(admitted: evidence),
                    failure: HeistFailureDetail(
                        category: .targetResolution,
                        contract: "action command resolves before dispatch",
                        observed: "could not resolve heist action command: \(error)",
                        expected: step.command.reportTarget.map(String.init(describing:))
                    )
                )
            )
        }

        internal static func expectationResolutionFailure(
            step: ActionStep,
            command: ResolvedHeistActionCommand,
            path: HeistExecutionPath,
            error: Error
        ) -> HeistExecutionStepResult {
            let observed = "could not resolve heist expectation: \(error)"
            let actionResult = ActionResult.failure(
                payload: .empty(for: command.type),
                failureKind: .validationError,
                message: observed
            )
            let evidence = HeistActionEvidence.completed(
                result: actionResult,
                expectation: unavailableExpectationEvidence()
            )
            return .action(
                path: path,
                execution: .failed(
                    command: step.command,
                    evidence: .init(admitted: evidence),
                    failure: HeistFailureDetail(
                        category: .expectation,
                        contract: "action expectation predicate resolves before evaluation",
                        observed: observed,
                        expected: step.expectationPolicy.expectedExpectation?.predicate.description
                    )
                )
            )
        }

        internal static func waitResolutionFailure(
            step: WaitStep,
            context: StepContext,
            error: Error
        ) -> HeistExecutionStepResult {
            .wait(
                path: context.path,
                predicate: step.predicate,
                timeout: step.timeout,
                completion: .failed(
                    evidence: nil,
                    failure: HeistFailureDetail(
                        category: .wait,
                        contract: "wait predicate resolves before evaluation",
                        observed: "could not resolve heist wait predicate: \(error)",
                        expected: step.predicate.description
                    )
                )
            )
        }

        internal static func heistTimeout(
            action leaf: ActionLeaf
        ) -> HeistExecutionStepResult {
            let result = ActionResult.failure(
                payload: .empty(for: leaf.command.type),
                failureKind: .timeout,
                message: "whole-heist deadline expired before action dispatch"
            )
            let evidence = HeistActionEvidence.completed(
                result: result,
                expectation: unavailableExpectationEvidence(
                    predicate: leaf.expectation.authoredPredicate
                )
            )
            return .action(
                path: leaf.path,
                execution: .failed(
                    command: leaf.step.command,
                    evidence: .init(admitted: evidence),
                    failure: HeistFailureDetail(
                        category: .action,
                        contract: "action begins within the whole-heist deadline",
                        observed: "whole-heist deadline expired before action dispatch"
                    )
                )
            )
        }

        internal static func heistTimeout(
            wait step: WaitStep,
            path: HeistExecutionPath
        ) -> HeistExecutionStepResult {
            .wait(
                path: path,
                predicate: step.predicate,
                timeout: step.timeout,
                completion: .failed(
                    evidence: nil,
                    failure: HeistFailureDetail(
                        category: .timeout,
                        contract: "wait begins within the whole-heist deadline",
                        observed: "whole-heist deadline expired before wait observation",
                        expected: step.predicate.description
                    )
                )
            )
        }

        internal static func project(
            action leaf: ActionLeaf,
            evidence: Observation.Evidence,
            outcome: LeafOutcome,
            timing: HeistExpectationTiming
        ) -> HeistExecutionStepResult {
            let actionResult = actionResult(
                leaf: leaf,
                evidence: evidence,
                outcome: outcome
            )
            let expectation = expectationEvidence(
                leaf.expectation.authoredPredicate,
                observation: evidence,
                outcome: outcome,
                timing: timing
            )
            let evidence = HeistActionEvidence.completed(
                result: actionResult,
                expectation: expectation
            )
            let execution: HeistActionExecution
            if actionResult.outcome.isSuccess {
                execution = .passed(
                    command: leaf.step.command,
                    evidence: .init(admitted: evidence)
                )
            } else if leaf.phase.dispatch?.success == true {
                execution = .failed(
                    command: leaf.step.command,
                    evidence: .init(admitted: evidence),
                    failure: actionExpectationFailure(
                        step: leaf.step,
                        evidence: evidence
                    )
                )
            } else {
                execution = .failed(
                    command: leaf.step.command,
                    evidence: .init(admitted: evidence),
                    failure: .init(
                        category: actionResult.outcome.failureKind == .elementNotFound
                            ? .targetResolution
                            : .action,
                        contract: "action dispatch succeeds",
                        observed: actionResult.message ?? "action dispatch failed",
                        expected: leaf.step.command.reportTarget.map(String.init(describing:))
                    )
                )
            }
            return .action(
                path: leaf.path,
                execution: execution
            )
        }

        internal static func project(
            wait step: WaitStep,
            path: HeistExecutionPath,
            expectation: HeistExpectationEvidence,
            outcome: LeafOutcome
        ) -> HeistExecutionStepResult {
            let passedEvidence = HeistPassedWaitEvidence(expectation)
            let completion: HeistWaitCompletion
            if let passedEvidence,
               passedEvidence.matchesExpectation {
                completion = .passed(evidence: passedEvidence)
            } else {
                completion = .failed(
                    evidence: expectation,
                    failure: waitFailure(step: step, evidence: expectation, outcome: outcome)
                )
            }
            return .wait(
                path: path,
                predicate: step.predicate,
                timeout: step.timeout,
                completion: completion
            )
        }

    }
}

extension HeistExecution.ResultProjector {
    internal static func expectationEvidence(
        _ predicate: HeistExecution.Predicate?,
        observation: Observation.Evidence,
        outcome: HeistExecution.LeafOutcome,
        timing: HeistExpectationTiming
    ) -> HeistExpectationEvidence {
        do {
            let terminalCause: HeistExpectationEvidence.TerminalCause = switch outcome {
            case .completed: .observed
            case .timedOut, .heistTimedOut: .deadline
            case .cancelled: .cancelled
            case .unavailable: .unavailable
            case .viewportExitFailed: .viewportFailure
            }
            return try HeistExpectationEvidence(
                predicate: predicate?.authored,
                bindings: predicate?.bindings ?? .empty,
                observation: observation,
                terminalCause: terminalCause,
                timing: timing
            )
        } catch {
            preconditionFailure("Reducer retained invalid predicate bindings: \(error)")
        }
    }

    private static func unavailableExpectationEvidence(
        predicate: HeistExecution.Predicate? = nil
    ) -> HeistExpectationEvidence {
        do {
            return try HeistExpectationEvidence(
                predicate: predicate?.authored,
                bindings: predicate?.bindings ?? .empty,
                observation: .init(
                    baseline: nil,
                    events: [],
                    current: nil,
                    coverage: .incomplete(.captureUnavailable)
                ),
                terminalCause: .unavailable,
                timing: .init(budgetMs: 0, elapsedMs: 0, lastTreeChangeElapsedMs: nil)
            )
        } catch {
            preconditionFailure("Reducer retained invalid predicate bindings: \(error)")
        }
    }

    static func actionResult(
        leaf: HeistExecution.ActionLeaf,
        evidence: Observation.Evidence,
        outcome: HeistExecution.LeafOutcome
    ) -> ActionResult {
        switch outcome {
        case .timedOut, .heistTimedOut:
            return .failure(
                payload: .empty(for: leaf.command.type),
                failureKind: .timeout,
                message: leaf.phase.expectation?.result.outstandingDescription.map {
                    "timed out while waiting for \($0)"
                } ?? "timed out",
                observation: .observed(evidence)
            )
        case .completed, .cancelled, .unavailable, .viewportExitFailed:
            break
        }
        guard let dispatch = leaf.phase.dispatch else {
            return .failure(
                payload: .empty(for: leaf.command.type),
                failureKind: .actionFailed,
                message: "action dispatch did not complete",
                observation: .observed(evidence)
            )
        }

        let resultOutcome: ActionResultOutcome
        let message: String?
        switch outcome {
        case .completed:
            switch dispatch.outcome {
            case .failure(let failure):
                resultOutcome = .failure(failure)
                message = dispatch.message
            case .success:
                resultOutcome = .success
                message = dispatch.message
            }
        case .cancelled:
            resultOutcome = .failure(.actionFailed)
            message = "action observation cancelled"
        case .unavailable:
            resultOutcome = .failure(.accessibilityTreeUnavailable)
            message = TheBrains.accessibilityTreeUnavailableMessage
        case .viewportExitFailed:
            resultOutcome = .failure(.actionFailed)
            message = "Could not restore the accessibility viewport after observation"
        case .timedOut, .heistTimedOut:
            preconditionFailure("Timed-out actions return before dispatch admission")
        }

        return ActionResult(
            outcome: resultOutcome,
            payload: dispatch.payload,
            message: message,
            observation: .observed(evidence),
            subjectEvidence: dispatch.subjectEvidence,
            activationTrace: dispatch.activationTrace,
            screenActionHandler: dispatch.screenActionHandler,
            timing: ActionPerformanceTiming(
                targetResolutionMs: dispatch.timing?.targetResolutionMs,
                actionDispatchMs: dispatch.timing?.actionDispatchMs,
                interactionMs: dispatch.timing?.interactionMs,
                totalMs: dispatch.timing?.totalMs
            )
        )
    }

    static func actionExpectationFailure(
        step: ActionStep,
        evidence: HeistActionEvidence
    ) -> HeistFailureDetail {
        let result = evidence.result
        let expectationActual: String?
        do {
            expectationActual = try evidence.replayExpectation()?.actual
        } catch {
            expectationActual = nil
        }
        var observed = result?.message
            ?? expectationActual
            ?? "post-action expectation was not met"
        if let expectationActual,
           expectationActual != observed {
            observed += "; replay: \(expectationActual)"
        }
        let authoredExpectation = step.expectationPolicy.expectedExpectation
        return HeistFailureDetail(
            category: .expectation,
            contract: authoredExpectation == nil
                ? "action settles through terminal no-change"
                : "post-action expectation is met",
            observed: observed,
            expected: authoredExpectation?.predicate.description
        )
    }

    static func waitFailure(
        step: WaitStep,
        evidence: HeistExpectationEvidence,
        outcome: HeistExecution.LeafOutcome
    ) -> HeistFailureDetail {
        let replay: ExpectationResult?
        do {
            replay = try evidence.replay()
        } catch {
            replay = nil
        }
        let category: HeistFailureCategory
        let observed: String
        switch outcome {
        case .completed:
            category = .wait
            observed = replay?.actual ?? "wait predicate was not met"
        case .timedOut, .heistTimedOut:
            category = .timeout
            observed = replay?.actual ?? "wait deadline expired"
        case .cancelled:
            category = .wait
            observed = "wait observation was cancelled"
        case .unavailable:
            category = .runtimeUnavailable
            observed = TheBrains.accessibilityTreeUnavailableMessage
        case .viewportExitFailed:
            category = .action
            observed = "Could not restore the accessibility viewport after observation"
        }
        return HeistFailureDetail(
            category: category,
            contract: "wait predicate is met before timeout",
            observed: observed,
            expected: step.predicate.description
        )
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
