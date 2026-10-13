#if canImport(UIKit)
#if DEBUG
import Foundation
import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension HeistExecution {
    mutating func advanceTopContinuation() -> HeistExecution.Decision {
        guard let continuation = running.continuations.popLast() else {
            preconditionFailure("A running execution advances through an active continuation")
        }
        switch continuation {
        case .sequence(let sequence):
            return advance(sequence)
        case .inline, .conditional, .invocation, .waitElse:
            preconditionFailure("A wrapper continuation requires completed children")
        case .forEachElement(let loop):
            return advance(loop)
        case .forEachString(let loop):
            return advance(loop)
        case .repeatUntil(let loop):
            return advance(loop)
        }
    }

    mutating func advanceControlFlow(
        _ event: HeistExecution.Event
    ) -> HeistExecution.Decision {
        guard case .currentSnapshot(_, let snapshot, _) = event,
              let continuation = running.continuations.last,
              continuation.awaitingSnapshot else {
            return wait()
        }
        running.continuations.removeLast()
        switch continuation {
        case .conditional(let conditional):
            return advance(conditional, snapshot: snapshot)
        case .forEachElement(let loop):
            return advance(loop, snapshot: snapshot)
        case .sequence, .inline, .forEachString, .repeatUntil, .invocation, .waitElse:
            preconditionFailure("Only snapshot-awaiting continuations accept currentSnapshot")
        }
    }

    mutating func finishAfterHeistTimeout() -> HeistExecution.Decision {
        if let activeLeaf = running.activeLeaf {
            if let action = activeLeaf.action {
                return resume(afterCompletedLeaf: HeistExecution.ResultProjector.heistTimeout(action: action))
            }
            if let wait = activeLeaf.wait {
                let result: HeistExecutionStepResult
                switch wait.purpose {
                case .authored(let step, let context):
                    result = HeistExecution.ResultProjector.heistTimeout(
                        wait: step,
                        path: context.path
                    )
                case .repeatCheck(let loop, let bodyChildren):
                    return resumeTimedOutRepeat(
                        loop,
                        bodyChildren: bodyChildren,
                        snapshot: nil
                    )
                }
                return resume(afterCompletedLeaf: result)
            }
            preconditionFailure("An active leaf must retain its action or wait payload")
        }

        guard let continuation = running.continuations.popLast() else {
            return wait()
        }

        let result: HeistExecutionStepResult
        switch continuation {
        case .conditional(let conditional):
            result = .conditional(
                path: conditional.context.path,
                completion: .failed(
                    evidence: nil,
                    failure: heistTimeoutFailure(
                        contract: "conditional selection completes within the whole-heist deadline"
                    )
                )
            )
        case .forEachElement(let loop):
            result = .forEach(
                path: loop.context.path,
                declaration: .init(loop.step),
                completion: .failed(
                    evidence: nil,
                    failure: heistTimeoutFailure(
                        contract: "for_each_element selection completes within the whole-heist deadline"
                    ),
                    children: passingChildren(loop.iterations)
                )
            )
        case .sequence, .inline, .forEachString, .repeatUntil, .invocation, .waitElse:
            running.continuations.append(continuation)
            return wait()
        }
        return resume(afterCompletedLeaf: result)
    }

    private mutating func requestSnapshot(
        for step: ConditionalStep,
        context: HeistExecution.StepContext,
        scope: SemanticObservationScope
    ) -> HeistExecution.Decision {
        let id = nextID()
        running.continuations.append(.conditional(.init(
            step: step,
            context: context,
            progress: .awaitingSnapshot
        )))
        return perform(.currentSnapshot(
            id,
            scope: scope,
            deadline: running.executionDeadline
        ))
    }

    private mutating func requestInitialSnapshot(
        for step: ForEachElementStep,
        context: HeistExecution.StepContext,
        matching: ResolvedElementPredicate
    ) -> HeistExecution.Decision {
        let id = nextID()
        running.continuations.append(.forEachElement(.init(
            step: step,
            context: context,
            resolvedMatching: matching,
            matchedCount: 0,
            iterationIndex: 0,
            progress: .awaitingSnapshot(previousMatchHash: nil),
            iterations: .empty
        )))
        return perform(.currentSnapshot(
            id,
            scope: .discovery,
            deadline: running.executionDeadline
        ))
    }

    private mutating func requestSnapshot(
        for continuation: HeistExecution.ForEachElementContinuation
    ) -> HeistExecution.Decision {
        guard case .executing(_, let previousMatchHash) = continuation.progress else {
            preconditionFailure("A completed for-each iteration must retain its match hash")
        }
        let id = nextID()
        running.continuations.append(.forEachElement(.init(
            step: continuation.step,
            context: continuation.context,
            resolvedMatching: continuation.resolvedMatching,
            matchedCount: continuation.matchedCount,
            iterationIndex: continuation.iterationIndex,
            progress: .awaitingSnapshot(previousMatchHash: previousMatchHash),
            iterations: continuation.iterations
        )))
        return perform(.currentSnapshot(
            id,
            scope: .discovery,
            deadline: running.executionDeadline
        ))
    }
}

private extension HeistExecution.Continuation {
    var awaitingSnapshot: Bool {
        switch self {
        case .conditional(let conditional):
            if case .awaitingSnapshot = conditional.progress { return true }
            return false
        case .forEachElement(let loop):
            if case .awaitingSnapshot = loop.progress { return true }
            return false
        case .sequence, .inline, .forEachString, .repeatUntil, .invocation, .waitElse:
            return false
        }
    }
}

private func heistTimeoutFailure(contract: String) -> HeistFailureDetail {
    HeistFailureDetail(
        category: .timeout,
        contract: contract,
        observed: "whole-heist deadline expired",
        expected: "heist completes before its declared timeout"
    )
}

private extension HeistExecution.ForEachElementContinuation {
    var previousMatchHash: SemanticHash? {
        switch progress {
        case .awaitingSnapshot(let previousMatchHash):
            previousMatchHash
        case .executing(_, let matchHash):
            matchHash
        }
    }
}

private extension HeistExecution {
    mutating func advance(
        _ sequence: HeistExecution.SequenceContinuation
    ) -> HeistExecution.Decision {
        var sequence = sequence
        if sequence.children.abortedAtPath != nil {
            while sequence.nextIndex < sequence.steps.count {
                let index = sequence.nextIndex
                sequence.children.append(.skipped(
                    path: sequence.context.path.step(at: index),
                    step: sequence.steps[index]
                ))
                sequence.nextIndex += 1
            }
        }
        guard sequence.nextIndex < sequence.steps.count else {
            return resume(afterCompletedSequence: sequence.children)
        }

        let index = sequence.nextIndex
        let step = sequence.steps[index]
        sequence.nextIndex += 1
        running.continuations.append(.sequence(sequence))
        return begin(
            step,
            context: .init(
                path: sequence.context.path.step(at: index),
                environment: sequence.context.environment,
                scope: sequence.context.scope
            )
        )
    }

    mutating func begin(
        _ step: HeistStep,
        context: HeistExecution.StepContext
    ) -> HeistExecution.Decision {
        switch step {
        case .action(let action):
            return begin(
                action: action,
                path: context.path,
                environment: context.environment
            )
        case .wait(let wait):
            return begin(wait: wait, context: context)
        case .conditional(let conditional):
            return begin(conditional: conditional, context: context)
        case .forEachElement(let loop):
            return begin(forEachElement: loop, context: context)
        case .forEachString(let loop):
            running.continuations.append(.forEachString(.init(
                step: loop,
                context: context,
                iterationIndex: 0,
                iterations: .empty
            )))
            return advanceExecution()
        case .repeatUntil(let loop):
            let resolved: ResolvedRepeatUntilStep
            let predicate: HeistExecution.Predicate
            do {
                resolved = try loop.resolve(in: context.environment)
                predicate = try .init(authored: loop.predicate, bindings: context.environment)
            } catch {
                return resume(afterCompletedLeaf: repeatUntilResolutionFailure(
                    loop,
                    context: context,
                    error: error
                ))
            }
            running.continuations.append(.repeatUntil(.init(
                step: loop,
                resolved: resolved,
                predicate: predicate,
                context: context,
                iterationIndex: 0,
                iterations: .empty
            )))
            return advanceExecution()
        case .warn(let warning):
            return resume(afterCompletedLeaf: .warning(
                path: context.path,
                message: warning.message,
                completion: .passed()
            ))
        case .fail(let failure):
            return resume(afterCompletedLeaf: .failure(
                path: context.path,
                message: failure.message,
                completion: .failed(failure: .init(
                    category: .explicitFailure,
                    contract: "explicit heist failure",
                    observed: failure.message.rawValue
                ))
            ))
        case .heist(let plan):
            running.continuations.append(.inline(.init(plan: plan, context: context)))
            running.continuations.append(.sequence(.init(
                steps: plan.body,
                context: .init(
                    path: context.path.heistBody(),
                    environment: context.environment,
                    scope: .init(
                        plan: plan,
                        rootPlan: plan,
                        definitionPath: context.scope.definitionPath,
                        invocationStack: context.scope.invocationStack
                    )
                ),
                nextIndex: 0,
                children: .empty
            )))
            return advanceExecution()
        case .invoke(let invocation):
            return begin(invocation: invocation, context: context)
        }
    }

    mutating func resume(
        afterCompletedSequence children: HeistExecutedChildren
    ) -> HeistExecution.Decision {
        guard let continuation = running.continuations.popLast() else {
            return finish(children: children)
        }
        switch continuation {
        case .inline(let inline):
            return resume(afterCompletedLeaf: inlineResult(
                inline,
                children: children
            ))
        case .conditional(let conditional):
            return resume(afterCompletedLeaf: conditionalResult(
                conditional,
                children: children
            ))
        case .forEachElement(let loop):
            return resume(loop, children: children)
        case .forEachString(let loop):
            return resume(loop, children: children)
        case .repeatUntil(let loop):
            return resume(loop, children: children)
        case .invocation(let invocation):
            return resume(invocation, children: children)
        case .waitElse(let waitElse):
            return resume(afterCompletedLeaf: waitElseResult(
                waitElse,
                children: children
            ))
        case .sequence:
            preconditionFailure("Nested sequences require a typed wrapper")
        }
    }

}

private extension HeistExecution {
    mutating func begin(
        conditional step: ConditionalStep,
        context: HeistExecution.StepContext
    ) -> HeistExecution.Decision {
        let resolved: [ResolvedPresenceCondition]
        do {
            resolved = try step.cases.map {
                try $0.predicate.resolve(in: context.environment)
            }
        } catch {
            return resume(afterCompletedLeaf: conditionalResolutionFailure(
                context: context,
                error: error
            ))
        }

        return requestSnapshot(
            for: step,
            context: context,
            scope: resolved.observationScope
        )
    }

    mutating func advance(
        _ continuation: HeistExecution.ConditionalContinuation,
        snapshot: Observation.Snapshot?
    ) -> HeistExecution.Decision {
        let selection: HeistCaseSelectionResult
        do {
            selection = try conditionalSelection(
                continuation.step,
                environment: continuation.context.environment,
                snapshot: snapshot
            )
        } catch {
            return resume(afterCompletedLeaf: conditionalResolutionFailure(
                context: continuation.context,
                error: error
            ))
        }

        let body: [HeistStep]
        let path: HeistExecutionPath
        let selected: HeistCaseSelectionResult
        switch selection.outcome {
        case .matchedCase(let ordinal):
            let selectedIndex = Int(ordinal)
            body = continuation.step.cases[selectedIndex].body
            path = continuation.context.path.conditionalCaseBody(at: selectedIndex)
            selected = selection
        case .elseBranch, .timedOut, .noMatch:
            guard let elseBody = continuation.step.elseBody else {
                return resume(afterCompletedLeaf: conditionalResult(
                    context: continuation.context,
                    selection: selection,
                    children: .empty
                ))
            }
            body = elseBody
            path = continuation.context.path.conditionalElseBody()
            selected = selection.selectingElseBranch()
        }

        running.continuations.append(.conditional(.init(
            step: continuation.step,
            context: continuation.context,
            progress: .selected(selected)
        )))
        running.continuations.append(.sequence(.init(
            steps: body,
            context: .init(
                path: path,
                environment: continuation.context.environment,
                scope: continuation.context.scope
            ),
            nextIndex: 0,
            children: .empty
        )))
        return advanceExecution()
    }

    func conditionalResult(
        _ continuation: HeistExecution.ConditionalContinuation,
        children: HeistExecutedChildren
    ) -> HeistExecutionStepResult {
        guard case .selected(let selection) = continuation.progress else {
            preconditionFailure("A completed conditional requires a selected branch")
        }
        return conditionalResult(
            context: continuation.context,
            selection: selection,
            children: children
        )
    }
}

private extension HeistExecution {
    func conditionalSelection(
        _ step: ConditionalStep,
        environment: HeistExecutionEnvironment,
        snapshot: Observation.Snapshot?
    ) throws -> HeistCaseSelectionResult {
        let resolved = try step.cases.map {
            try $0.predicate.resolve(in: environment)
        }
        let matches = zip(step.cases, resolved).map { predicateCase, condition in
            let result = evaluate(
                condition.rootPredicate,
                expression: predicateCase.predicate.rootPredicate,
                snapshot: snapshot
            )
            return HeistCaseMatchResult(
                predicate: predicateCase.predicate.rootPredicate,
                met: result.met,
                actual: result.actual
            )
        }
        return .selectingFirstMatch(
            cases: matches,
            ifNone: .noMatch,
            elapsedMs: 0,
            lastObservedSummary: snapshot?.summary
        )
    }

    func conditionalResult(
        context: HeistExecution.StepContext,
        selection: HeistCaseSelectionResult,
        children: HeistExecutedChildren
    ) -> HeistExecutionStepResult {
        let evidence = HeistCaseSelectionEvidence(selection: selection)
        return children.fold(
            passed: { children in
                .conditional(
                    path: context.path,
                    completion: .passed(evidence: evidence, children: children)
                )
            },
            aborted: { children in
                .conditional(
                    path: context.path,
                    completion: .childAborted(
                        evidence: evidence,
                        failure: childFailure(
                            category: .invocation,
                            path: children.abortedAtPath
                        ),
                        children: children
                    )
                )
            }
        )
    }

    func conditionalResolutionFailure(
        context: HeistExecution.StepContext,
        error: Error
    ) -> HeistExecutionStepResult {
        .conditional(
            path: context.path,
            completion: .failed(evidence: nil, failure: .init(
                category: .validation,
                contract: "case predicates resolve before evaluation",
                observed: "could not resolve heist case predicate: \(error)"
            ))
        )
    }
}

private extension Array where Element == ResolvedPresenceCondition {
    var observationScope: SemanticObservationScope {
        map(\.observationScope).max() ?? .visible
    }
}

private extension HeistExecution {
    mutating func begin(
        forEachElement step: ForEachElementStep,
        context: HeistExecution.StepContext
    ) -> HeistExecution.Decision {
        let resolved: ResolvedElementPredicate
        do {
            resolved = try step.matching.resolve(in: context.environment)
        } catch {
            return resume(afterCompletedLeaf: forEachElementResolutionFailure(
                step,
                context: context,
                error: error
            ))
        }
        return requestInitialSnapshot(
            for: step,
            context: context,
            matching: resolved
        )
    }

    mutating func advance(
        _ loop: HeistExecution.ForEachElementContinuation
    ) -> HeistExecution.Decision {
        requestSnapshot(for: loop)
    }

    mutating func advance(
        _ loop: HeistExecution.ForEachElementContinuation,
        snapshot: Observation.Snapshot?
    ) -> HeistExecution.Decision {
        guard case .awaitingSnapshot(let previousMatchHash) = loop.progress else {
            return wait()
        }
        guard let snapshot else {
            return resume(afterCompletedLeaf: forEachElementUnavailable(
                loop,
                failedIterationIndex: max(0, loop.iterationIndex - 1)
            ))
        }

        let identities = AccessibilityTargetMatchGraph(
            elements: snapshot.interface.projectedElements
        )
        .resolve(loop.resolvedMatching)
        .elements
        .map(AccessibilityPolicy.matcherIdentityFacts(for:))
        var hasher = Hasher()
        for identity in identities {
            for fact in identity {
                hasher.combine(accessibilityFact: fact)
            }
        }
        let matchHash = hasher.finalize()
        let initialSelection = previousMatchHash == nil
            && loop.iterationIndex == 0
            && loop.iterations.values.isEmpty
        let matchedCount = initialSelection ? identities.count : loop.matchedCount
        guard matchedCount <= loop.step.limit else {
            return resume(afterCompletedLeaf: forEachElementLimitFailure(
                loop.step,
                context: loop.context,
                matchedCount: matchedCount
            ))
        }
        guard matchedCount > 0 else {
            return resume(afterCompletedLeaf: forEachElementSummary(
                step: loop.step,
                context: loop.context,
                matchedCount: 0,
                iterations: .empty,
                failureReason: nil
            ))
        }

        let previousOrdinal = loop.iterations.values.last?
            .forEachEvidence?.targetOrdinal ?? -1
        let ordinal = initialSelection || matchHash != previousMatchHash
            ? 0
            : previousOrdinal + 1
        let target = ResolvedAccessibilityTarget.predicate(
            loop.resolvedMatching,
            ordinal: ordinal
        )
        let iterationPath = loop.context.path.forEachElementIteration(
            at: loop.iterationIndex
        )
        running.continuations.append(.forEachElement(.init(
            step: loop.step,
            context: loop.context,
            resolvedMatching: loop.resolvedMatching,
            matchedCount: matchedCount,
            iterationIndex: loop.iterationIndex,
            progress: .executing(
                targetOrdinal: ordinal,
                matchHash: matchHash
            ),
            iterations: loop.iterations
        )))
        running.continuations.append(.sequence(.init(
            steps: loop.step.body,
            context: .init(
                path: iterationPath.iterationBody(),
                environment: loop.context.environment.binding(
                    target: target,
                    to: loop.step.parameter
                ),
                scope: loop.context.scope
            ),
            nextIndex: 0,
            children: .empty
        )))
        return advanceExecution()
    }

    mutating func resume(
        _ loop: HeistExecution.ForEachElementContinuation,
        children: HeistExecutedChildren
    ) -> HeistExecution.Decision {
        guard case .executing = loop.progress else {
            preconditionFailure("Only an executing for-each iteration can complete")
        }
        let iteration = forEachElementIteration(
            loop,
            children: children
        )
        var iterations = loop.iterations
        iterations.append(iteration)
        if let childPath = iterations.abortedAtPath {
            return resume(afterCompletedLeaf: forEachElementSummary(
                step: loop.step,
                context: loop.context,
                matchedCount: loop.matchedCount,
                iterations: iterations,
                failureReason: "iteration \(loop.iterationIndex) failed at \(childPath)"
            ))
        }

        let nextIndex = loop.iterationIndex + 1
        guard nextIndex < loop.matchedCount else {
            return resume(afterCompletedLeaf: forEachElementSummary(
                step: loop.step,
                context: loop.context,
                matchedCount: loop.matchedCount,
                iterations: iterations,
                failureReason: nil
            ))
        }
        return requestSnapshot(for: .init(
            step: loop.step,
            context: loop.context,
            resolvedMatching: loop.resolvedMatching,
            matchedCount: loop.matchedCount,
            iterationIndex: nextIndex,
            progress: loop.progress,
            iterations: iterations
        ))
    }

    mutating func advance(
        _ loop: HeistExecution.ForEachStringContinuation
    ) -> HeistExecution.Decision {
        guard loop.iterationIndex < loop.step.values.count else {
            return resume(afterCompletedLeaf: forEachStringSummary(
                loop,
                failureReason: nil
            ))
        }
        let value = loop.step.values[loop.iterationIndex]
        let path = loop.context.path.forEachStringIteration(
            at: loop.iterationIndex
        )
        running.continuations.append(.forEachString(loop))
        running.continuations.append(.sequence(.init(
            steps: loop.step.body,
            context: .init(
                path: path.iterationBody(),
                environment: loop.context.environment.binding(
                    string: value,
                    to: loop.step.parameter
                ),
                scope: loop.context.scope
            ),
            nextIndex: 0,
            children: .empty
        )))
        return advanceExecution()
    }

    mutating func resume(
        _ loop: HeistExecution.ForEachStringContinuation,
        children: HeistExecutedChildren
    ) -> HeistExecution.Decision {
        let iteration = forEachStringIteration(loop, children: children)
        var iterations = loop.iterations
        iterations.append(iteration)
        if let childPath = iterations.abortedAtPath {
            let value = loop.step.values[loop.iterationIndex]
            return resume(afterCompletedLeaf: forEachStringSummary(
                .init(
                    step: loop.step,
                    context: loop.context,
                    iterationIndex: loop.iterationIndex + 1,
                    iterations: iterations
                ),
                failureReason: "iteration \(loop.iterationIndex) failed for value \"\(value)\" at \(childPath)"
            ))
        }

        running.continuations.append(.forEachString(.init(
            step: loop.step,
            context: loop.context,
            iterationIndex: loop.iterationIndex + 1,
            iterations: iterations
        )))
        return advanceExecution()
    }
}

private extension HeistExecution {
    func forEachElementIteration(
        _ loop: HeistExecution.ForEachElementContinuation,
        children: HeistExecutedChildren
    ) -> HeistExecutionStepResult {
        guard case .executing(let targetOrdinal, _) = loop.progress else {
            preconditionFailure("For-each iteration evidence requires a selected target")
        }
        let failureReason = children.abortedAtPath.map { "child failed at \($0)" }
        let evidence = HeistForEachEvidence.executed(
            source: .elements(matchedCount: loop.matchedCount),
            iterationCount: loop.iterationIndex + 1,
            iteration: .element(
                ordinal: loop.iterationIndex,
                targetOrdinal: targetOrdinal,
                targetSummary: ResolvedAccessibilityTarget.predicate(
                    loop.resolvedMatching,
                    ordinal: targetOrdinal
                ).description
            ),
            failureReason: failureReason
        )
        let completion: HeistForEachCompletion = children.fold(
            passed: { .passed(evidence: .init(admitted: evidence), children: $0) },
            aborted: {
                .childAborted(
                    evidence: .init(admitted: evidence),
                    failure: childFailure(category: .loop, path: $0.abortedAtPath),
                    children: $0
                )
            }
        )
        return .forEachIteration(
            path: loop.context.path.forEachElementIteration(at: loop.iterationIndex),
            declaration: .init(loop.step),
            completion: completion
        )
    }

    func forEachElementSummary(
        step: ForEachElementStep,
        context: HeistExecution.StepContext,
        matchedCount: Int,
        iterations: HeistExecutedChildren,
        failureReason: String?
    ) -> HeistExecutionStepResult {
        let evidence = HeistForEachEvidence.executed(
            source: .elements(matchedCount: matchedCount),
            iterationCount: iterations.values.count,
            failureReason: failureReason
        )
        let completion: HeistForEachCompletion = iterations.fold(
            passed: { .passed(evidence: .init(admitted: evidence), children: $0) },
            aborted: {
                .childAborted(
                    evidence: .init(admitted: evidence),
                    failure: .init(
                        category: .loop,
                        contract: "for_each_element completes all matched iterations",
                        observed: failureReason ?? "child failed at \($0.abortedAtPath)",
                        expected: "\(matchedCount) iteration(s)"
                    ),
                    children: $0
                )
            }
        )
        return .forEach(
            path: context.path,
            declaration: .init(step),
            completion: completion
        )
    }

    func forEachStringIteration(
        _ loop: HeistExecution.ForEachStringContinuation,
        children: HeistExecutedChildren
    ) -> HeistExecutionStepResult {
        let value = loop.step.values[loop.iterationIndex]
        let failureReason = children.abortedAtPath.map { "child failed at \($0)" }
        let evidence = HeistForEachEvidence.executed(
            source: .strings,
            iterationCount: loop.iterationIndex + 1,
            iteration: .string(ordinal: loop.iterationIndex, value: value),
            failureReason: failureReason
        )
        let completion: HeistForEachCompletion = children.fold(
            passed: { .passed(evidence: .init(admitted: evidence), children: $0) },
            aborted: {
                .childAborted(
                    evidence: .init(admitted: evidence),
                    failure: childFailure(category: .loop, path: $0.abortedAtPath),
                    children: $0
                )
            }
        )
        return .forEachIteration(
            path: loop.context.path.forEachStringIteration(at: loop.iterationIndex),
            declaration: .init(loop.step),
            completion: completion
        )
    }

    func forEachStringSummary(
        _ loop: HeistExecution.ForEachStringContinuation,
        failureReason: String?
    ) -> HeistExecutionStepResult {
        let evidence = HeistForEachEvidence.executed(
            source: .strings,
            iterationCount: loop.iterations.values.count,
            failureReason: failureReason
        )
        let completion: HeistForEachCompletion = loop.iterations.fold(
            passed: { .passed(evidence: .init(admitted: evidence), children: $0) },
            aborted: {
                .childAborted(
                    evidence: .init(admitted: evidence),
                    failure: .init(
                        category: .loop,
                        contract: "for_each_string completes all values",
                        observed: failureReason ?? "child failed at \($0.abortedAtPath)",
                        expected: "\(loop.step.values.count) value(s)"
                    ),
                    children: $0
                )
            }
        )
        return .forEach(
            path: loop.context.path,
            declaration: .init(loop.step),
            completion: completion
        )
    }

    func forEachElementUnavailable(
        _ loop: HeistExecution.ForEachElementContinuation,
        failedIterationIndex: Int
    ) -> HeistExecutionStepResult {
        let observed = loop.previousMatchHash == nil
            ? "could not observe the current semantic snapshot before evaluating for_each_element"
            : "iteration \(failedIterationIndex) post-observation unavailable"
        let evidence = HeistFailedForEachEvidence(admitted: .executed(
            source: .elements(matchedCount: loop.matchedCount),
            iterationCount: loop.iterations.values.count,
            failureReason: observed
        ))
        return .forEach(
            path: loop.context.path,
            declaration: .init(loop.step),
            completion: .failed(
                evidence: evidence,
                failure: .init(
                    category: .runtimeUnavailable,
                    contract: "an admitted semantic snapshot is observable before for_each_element matching",
                    observed: observed
                ),
                children: passingChildren(loop.iterations)
            )
        )
    }

    func forEachElementResolutionFailure(
        _ step: ForEachElementStep,
        context: HeistExecution.StepContext,
        error: Error
    ) -> HeistExecutionStepResult {
        let observed = "could not resolve for_each_element matcher: \(error)"
        let evidence = HeistFailedForEachEvidence(admitted: .executed(
            source: .elements(matchedCount: 0),
            iterationCount: 0,
            failureReason: observed
        ))
        return .forEach(
            path: context.path,
            declaration: .init(step),
            completion: .failed(evidence: evidence, failure: .init(
                category: .targetResolution,
                contract: "for_each_element matcher resolves before evaluation",
                observed: observed,
                expected: step.matching.description
            ))
        )
    }

    func forEachElementLimitFailure(
        _ step: ForEachElementStep,
        context: HeistExecution.StepContext,
        matchedCount: Int
    ) -> HeistExecutionStepResult {
        let observed = "matched \(matchedCount) element(s), exceeding for_each_element limit \(step.limit)"
        let evidence = HeistFailedForEachEvidence(admitted: .executed(
            source: .elements(matchedCount: matchedCount),
            iterationCount: 0,
            failureReason: observed
        ))
        return .forEach(
            path: context.path,
            declaration: .init(step),
            completion: .failed(evidence: evidence, failure: .init(
                category: .loop,
                contract: "for_each_element matched count does not exceed limit",
                observed: observed,
                expected: "at most \(step.limit) element(s)"
            ))
        )
    }
}

private extension Hasher {
    mutating func combine(accessibilityFact fact: AccessibilityMatcherFact) {
        switch fact {
        case .identifier(let value):
            combine(0)
            combine(value)
        case .label(let value):
            combine(1)
            combine(value)
        case .value(let value):
            combine(2)
            combine(value)
        case .trait(let value):
            combine(3)
            combine(value)
        case .excludedTrait(let value):
            combine(4)
            combine(value)
        }
    }
}

private extension HeistExecution {
    mutating func begin(
        invocation step: HeistInvocationStep,
        context: HeistExecution.StepContext
    ) -> HeistExecution.Decision {
        let resolution = resolveInvocation(step, scope: context.scope)
        guard !context.scope.invocationStack.contains(resolution.resolvedPath) else {
            return resume(afterCompletedLeaf: recursiveInvocation(
                step,
                context: context,
                resolvedPath: resolution.resolvedPath
            ))
        }
        guard let definition = resolution.definition else {
            return resume(afterCompletedLeaf: unknownInvocation(
                step,
                context: context
            ))
        }

        let expectation = step.expectation?.waitStep(
            using: actionExpectationTimeoutPolicy
        )
        let environment: HeistExecutionEnvironment
        do {
            environment = try context.environment.binding(
                argument: step.argument,
                to: definition.parameter
            )
            if let expectation {
                _ = try expectation.resolve(in: context.environment)
            }
        } catch {
            return resume(afterCompletedLeaf: invocationPreparationFailure(
                step,
                context: context,
                error: error
            ))
        }

        let steps = definition.body + (expectation.map {
            [HeistStep.wait($0)]
        } ?? [])
        running.continuations.append(.invocation(.init(
            step: step,
            context: context,
            resolvedPath: resolution.resolvedPath
        )))
        running.continuations.append(.sequence(.init(
            steps: steps,
            context: .init(
                path: context.path.invocationBody(),
                environment: environment,
                scope: .init(
                    plan: definition,
                    rootPlan: context.scope.rootPlan,
                    definitionPath: resolution.resolvedPath.components,
                    invocationStack: context.scope.invocationStack.union([
                        resolution.resolvedPath,
                    ])
                )
            ),
            nextIndex: 0,
            children: .empty
        )))
        return advanceExecution()
    }

    mutating func resume(
        _ invocation: HeistExecution.InvocationContinuation,
        children executed: HeistExecutedChildren
    ) -> HeistExecution.Decision {
        let result = invocationResult(
            invocation,
            children: executed
        )
        return resume(afterCompletedLeaf: result)
    }
}

private extension HeistExecution {
    struct InvocationResolution {
        let requestedPath: HeistInvocationPath
        let resolvedPath: HeistInvocationPath
        let definition: HeistPlan?
    }

    func resolveInvocation(
        _ step: HeistInvocationStep,
        scope: HeistExecution.Scope
    ) -> InvocationResolution {
        guard let first = step.path.components.first else {
            preconditionFailure("validated heist invocation path must not be empty")
        }
        let definitionPath = HeistDefinitionPath(
            first: first,
            remaining: Array(step.path.components.dropFirst())
        )
        let local = scope.plan.heistDefinition(at: definitionPath)
        let root = step.path.components.count > 1
            ? scope.rootPlan.heistDefinition(at: definitionPath)
            : nil
        let components = local == nil && root != nil
            ? step.path.components
            : scope.definitionPath + step.path.components
        guard let resolvedFirst = components.first else {
            preconditionFailure("validated heist invocation path must not be empty")
        }
        return InvocationResolution(
            requestedPath: step.path,
            resolvedPath: .init(
                first: resolvedFirst,
                remaining: Array(components.dropFirst())
            ),
            definition: local ?? root
        )
    }

    func invocationResult(
        _ invocation: HeistExecution.InvocationContinuation,
        children: HeistExecutedChildren
    ) -> HeistExecutionStepResult {
        children.fold(
            passed: { children in
                .invocation(
                    path: invocation.context.path,
                    invocationPath: invocation.step.path,
                    argument: invocation.step.argument,
                    completion: .passed(
                        evidence: .init(admitted: .completed),
                        children: children
                    )
                )
            },
            aborted: { children in
                let evidence = HeistInvocationEvidence.childFailed(
                    path: children.abortedAtPath
                )
                return .invocation(
                    path: invocation.context.path,
                    invocationPath: invocation.step.path,
                    argument: invocation.step.argument,
                    completion: .childAborted(
                        evidence: .init(admitted: evidence),
                        failure: childFailure(
                            category: .invocation,
                            path: children.abortedAtPath
                        ),
                        children: children
                    )
                )
            }
        )
    }

    func recursiveInvocation(
        _ step: HeistInvocationStep,
        context: HeistExecution.StepContext,
        resolvedPath: HeistInvocationPath
    ) -> HeistExecutionStepResult {
        .invocation(
            path: context.path,
            invocationPath: step.path,
            argument: step.argument,
            completion: .failed(evidence: nil, failure: .init(
                category: .invocation,
                contract: "heist invocation must not recurse",
                observed: "recursive heist run \(resolvedPath)"
            ))
        )
    }

    func unknownInvocation(
        _ step: HeistInvocationStep,
        context: HeistExecution.StepContext
    ) -> HeistExecutionStepResult {
        .invocation(
            path: context.path,
            invocationPath: step.path,
            argument: step.argument,
            completion: .failed(evidence: nil, failure: .init(
                category: .invocation,
                contract: "heist invocation path resolves to a definition",
                observed: "unknown heist run \(step.path)",
                expected: step.path.description
            ))
        )
    }

    func invocationPreparationFailure(
        _ step: HeistInvocationStep,
        context: HeistExecution.StepContext,
        error: Error
    ) -> HeistExecutionStepResult {
        let observed = "could not prepare heist run: \(error)"
        let expected = step.expectation?.predicate.description
        return .invocation(
            path: context.path,
            invocationPath: step.path,
            argument: step.argument,
            completion: .failed(evidence: nil, failure: .init(
                category: expected == nil ? .validation : .expectation,
                contract: expected == nil
                    ? "heist invocation argument binds to the target parameter"
                    : "heist invocation expectation predicate resolves before evaluation",
                observed: observed,
                expected: expected
            ))
        )
    }
}

private extension HeistExecution {
    mutating func advance(
        _ loop: HeistExecution.RepeatUntilContinuation
    ) -> HeistExecution.Decision {
        let path = loop.context.path.repeatUntilIteration(
            at: loop.iterationIndex
        )
        running.continuations.append(.repeatUntil(loop))
        running.continuations.append(.sequence(.init(
            steps: loop.step.body,
            context: .init(
                path: path.iterationBody(),
                environment: loop.context.environment,
                scope: loop.context.scope
            ),
            nextIndex: 0,
            children: .empty
        )))
        return advanceExecution()
    }

    mutating func resume(
        _ loop: HeistExecution.RepeatUntilContinuation,
        children: HeistExecutedChildren
    ) -> HeistExecution.Decision {
        let snapshot = latestSnapshot(in: children.values)
        if case .passed(let passing) = children, snapshot == nil {
            return begin(
                wait: loop.predicate,
                purpose: .repeatCheck(loop: loop, bodyChildren: passing),
                timeout: loop.step.timeout
            )
        }
        let evaluation = evaluate(
            loop.resolved.predicate,
            expression: loop.resolved.predicateExpression,
            snapshot: snapshot
        )
        if case .aborted(let aborted) = children {
            return resumeAbortedRepeat(
                loop,
                children: aborted,
                evaluation: evaluation,
                snapshot: snapshot
            )
        }
        guard case .passed(let passing) = children else {
            preconditionFailure("Exhaustive repeat_until child result")
        }
        return resumePassingRepeat(
            loop,
            children: passing,
            evaluation: evaluation,
            snapshot: snapshot
        )
    }
}

extension HeistExecution {
    mutating func resumeRepeatCheck(
        _ loop: HeistExecution.RepeatUntilContinuation,
        bodyChildren: HeistPassingChildren,
        expectation: HeistExpectationEvidence
    ) -> HeistExecution.Decision {
        let replay: ExpectationResult
        do {
            replay = try expectation.replay()
        } catch {
            preconditionFailure("runtime repeat_until evidence must be complete: \(error)")
        }
        let snapshot = expectation.observation.current
        switch replay {
        case .met:
            return resumePassingRepeat(
                loop,
                children: bodyChildren,
                evaluation: replay,
                snapshot: snapshot
            )
        case .unmet:
            return resumeTimedOutRepeat(
                loop,
                bodyChildren: bodyChildren,
                snapshot: snapshot
            )
        }
    }

    mutating func resumeTimedOutRepeat(
        _ loop: HeistExecution.RepeatUntilContinuation,
        bodyChildren: HeistPassingChildren,
        snapshot: Observation.Snapshot?
    ) -> HeistExecution.Decision {
        let count = loop.iterationIndex + 1
        let iterationEvidence = HeistRepeatUntilEvidence.executedContinued(
            iterationCount: count,
            iterationOrdinal: loop.iterationIndex,
            lastObservedSummary: snapshot?.summary
        )
        let iteration = repeatUntilIteration(
            loop,
            children: bodyChildren,
            evidence: iterationEvidence
        )
        var executed = loop.iterations
        executed.append(iteration)
        let iterations = passingChildren(executed)
        let reason = "repeat_until deadline elapsed"
        let evidence = HeistRepeatUntilEvidence.executedFailed(
            iterationCount: count,
            lastObservedSummary: snapshot?.summary,
            failureReason: reason
        )
        return resume(afterCompletedLeaf: .repeatUntil(
            path: loop.context.path,
            declaration: .init(loop.step),
            completion: .failed(
                evidence: .init(admitted: evidence),
                failure: .init(
                    category: .loop,
                    contract: "repeat_until predicate is met before timeout",
                    observed: reason,
                    expected: loop.resolved.predicate.description
                ),
                children: iterations
            )
        ))
    }

    mutating func resumePassingRepeat(
        _ loop: HeistExecution.RepeatUntilContinuation,
        children: HeistPassingChildren,
        evaluation: ExpectationResult,
        snapshot: Observation.Snapshot?
    ) -> HeistExecution.Decision {
        let count = loop.iterationIndex + 1
        let evidence: HeistRepeatUntilEvidence = switch evaluation {
        case .met:
            .executedMatched(
                iterationCount: count,
                iterationOrdinal: loop.iterationIndex,
                lastObservedSummary: snapshot?.summary
            )
        case .unmet:
            .executedContinued(
                iterationCount: count,
                iterationOrdinal: loop.iterationIndex,
                lastObservedSummary: snapshot?.summary
            )
        }
        let iteration = repeatUntilIteration(loop, children: children, evidence: evidence)
        var iterations = loop.iterations
        iterations.append(iteration)
        if case .met = evaluation {
            return resume(afterCompletedLeaf: repeatUntilMatched(
                loop,
                iterations: passingChildren(iterations),
                snapshot: snapshot
            ))
        }
        running.continuations.append(.repeatUntil(.init(
            step: loop.step,
            resolved: loop.resolved,
            predicate: loop.predicate,
            context: loop.context,
            iterationIndex: loop.iterationIndex + 1,
            iterations: iterations
        )))
        return advanceExecution()
    }

    mutating func resumeAbortedRepeat(
        _ loop: HeistExecution.RepeatUntilContinuation,
        children: HeistAbortedChildren,
        evaluation: ExpectationResult,
        snapshot: Observation.Snapshot?
    ) -> HeistExecution.Decision {
        if case .met = evaluation,
           let retained = recoverableRepeatChildren(children) {
            return resumePassingRepeat(
                loop,
                children: retained,
                evaluation: evaluation,
                snapshot: snapshot
            )
        }

        let childPath = children.abortedAtPath
        let count = loop.iterationIndex + 1
        let reason = "child failed at \(childPath)"
        let evidence = HeistRepeatUntilEvidence.executedFailed(
            iterationCount: count,
            iterationOrdinal: loop.iterationIndex,
            lastObservedSummary: snapshot?.summary,
            failureReason: reason
        )
        let iteration = HeistExecutionStepResult.repeatUntilIteration(
            path: loop.context.path.repeatUntilIteration(at: loop.iterationIndex),
            declaration: .init(loop.step),
            completion: .childAborted(
                evidence: .init(admitted: evidence),
                failure: childFailure(category: .loop, path: childPath),
                children: children
            )
        )
        var iterations = loop.iterations
        iterations.append(iteration)
        guard case .aborted(let abortedIterations) = iterations else {
            preconditionFailure("A failed repeat_until iteration must abort")
        }
        return resume(afterCompletedLeaf: repeatUntilFailed(
            loop,
            iterations: abortedIterations,
            snapshot: snapshot
        ))
    }

    func repeatUntilIteration(
        _ loop: HeistExecution.RepeatUntilContinuation,
        children: HeistPassingChildren,
        evidence: HeistRepeatUntilEvidence
    ) -> HeistExecutionStepResult {
        .repeatUntilIteration(
            path: loop.context.path.repeatUntilIteration(at: loop.iterationIndex),
            declaration: .init(loop.step),
            completion: .passed(
                evidence: .init(admitted: evidence),
                children: children
            )
        )
    }

    func repeatUntilMatched(
        _ loop: HeistExecution.RepeatUntilContinuation,
        iterations: HeistPassingChildren,
        snapshot: Observation.Snapshot?
    ) -> HeistExecutionStepResult {
        let evidence = HeistRepeatUntilEvidence.executedMatched(
            iterationCount: loop.iterationIndex + 1,
            lastObservedSummary: snapshot?.summary
        )
        return .repeatUntil(
            path: loop.context.path,
            declaration: .init(loop.step),
            completion: .passed(
                evidence: .init(admitted: evidence),
                children: iterations
            )
        )
    }

    func repeatUntilFailed(
        _ loop: HeistExecution.RepeatUntilContinuation,
        iterations: HeistAbortedChildren,
        snapshot: Observation.Snapshot?
    ) -> HeistExecutionStepResult {
        let reason = "iteration \(loop.iterationIndex) failed at \(iterations.abortedAtPath)"
        let evidence = HeistRepeatUntilEvidence.executedFailed(
            iterationCount: loop.iterationIndex + 1,
            lastObservedSummary: snapshot?.summary,
            failureReason: reason
        )
        return .repeatUntil(
            path: loop.context.path,
            declaration: .init(loop.step),
            completion: .childAborted(
                evidence: .init(admitted: evidence),
                failure: .init(
                    category: .loop,
                    contract: "repeat_until predicate is met before timeout",
                    observed: reason,
                    expected: loop.resolved.predicate.description
                ),
                children: iterations
            )
        )
    }

    func repeatUntilResolutionFailure(
        _ step: RepeatUntilStep,
        context: HeistExecution.StepContext,
        error: Error
    ) -> HeistExecutionStepResult {
        .repeatUntil(
            path: context.path,
            declaration: .init(step),
            completion: .failed(evidence: nil, failure: .init(
                category: .validation,
                contract: "repeat_until predicate resolves before evaluation",
                observed: "could not resolve heist repeat_until predicate: \(error)",
                expected: step.predicate.description
            ))
        )
    }

    func recoverableRepeatChildren(
        _ children: HeistAbortedChildren
    ) -> HeistPassingChildren? {
        guard let failed = children.values.first(where: {
            $0.path == children.abortedAtPath
        }),
        failed.kind == .action,
        failed.failure?.category == .action,
        failed.actionEvidence?.result?.outcome.isSuccess == false
        else { return nil }

        switch failed.actionEvidence?.result?.outcome.failureKind {
        case nil, .some(.actionFailed):
            return HeistPassingChildren(
                children.values.filter { $0.path != children.abortedAtPath }
            )
        case .some(.accessibilityTreeUnavailable),
             .some(.elementNotFound),
             .some(.timeout),
             .some(.validationError):
            return nil
        }
    }
}

private extension HeistExecution {
    func inlineResult(
        _ inline: HeistExecution.InlineContinuation,
        children: HeistExecutedChildren
    ) -> HeistExecutionStepResult {
        children.fold(
            passed: {
                .heist(
                    path: inline.context.path,
                    name: inline.plan.name,
                    completion: .passed(children: $0)
                )
            },
            aborted: {
                .heist(
                    path: inline.context.path,
                    name: inline.plan.name,
                    completion: .childAborted(
                        failure: childFailure(
                            category: .invocation,
                            path: $0.abortedAtPath
                        ),
                        children: $0
                    )
                )
            }
        )
    }

    func waitElseResult(
        _ waitElse: HeistExecution.WaitElseContinuation,
        children: HeistExecutedChildren
    ) -> HeistExecutionStepResult {
        let completion: HeistWaitCompletion = children.fold(
            passed: { .passed(evidence: waitElse.evidence, children: $0) },
            aborted: {
                .childAborted(
                    evidence: waitElse.evidence.expectation,
                    failure: childFailure(
                        category: .wait,
                        path: $0.abortedAtPath
                    ),
                    children: $0
                )
            }
        )
        return .wait(
            path: waitElse.context.path,
            predicate: waitElse.step.predicate,
            timeout: waitElse.step.timeout,
            completion: completion
        )
    }

    func childFailure(
        category: HeistFailureCategory,
        path: HeistExecutionPath
    ) -> HeistFailureDetail {
        .init(
            category: category,
            contract: "child execution completes without failure",
            observed: "child failed at \(path)",
            expected: "all executed child steps pass"
        )
    }

    func evaluate(
        _ predicate: ObservationPredicate,
        expression: AccessibilityPredicate,
        snapshot: Observation.Snapshot?
    ) -> ExpectationResult {
        guard let snapshot else {
            return ExpectationResult(
                met: false,
                predicate: expression,
                actual: "current accessibility snapshot unavailable"
            )
        }
        let expectation = Expectation([predicate], baseline: snapshot)
        return ExpectationResult(
            met: expectation.result == .satisfied,
            predicate: expression,
            actual: expectation.result.outstandingDescription ?? snapshot.summary
        )
    }

    func latestSnapshot(
        in results: [HeistExecutionStepResult]
    ) -> Observation.Snapshot? {
        for result in results.reversed() {
            if let current = result.actionEvidence?.result?
                .observationEvidence?.current {
                return current
            }
            if let current = result.waitObservation?.current {
                return current
            }
            if let current = latestSnapshot(in: result.children) {
                return current
            }
        }
        return nil
    }

    func passingChildren(
        _ children: HeistExecutedChildren
    ) -> HeistPassingChildren {
        guard case .passed(let children) = children else {
            preconditionFailure("Passing children required")
        }
        return children
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
