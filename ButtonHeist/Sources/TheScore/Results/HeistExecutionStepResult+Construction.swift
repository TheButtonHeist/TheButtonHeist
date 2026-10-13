import Foundation
import ThePlans

package struct HeistActionExecution: Sendable, Equatable {
    package let command: HeistActionCommand
    package let completion: HeistActionCompletion

    private init(
        command: HeistActionCommand,
        completion: HeistActionCompletion,
        evidence: HeistActionEvidence?
    ) {
        precondition(evidence?.matches(command: command) != false)
        self.command = command
        self.completion = completion
    }

    package static func passed(
        command: HeistActionCommand,
        evidence: HeistPassedActionEvidence,
        children: HeistPassingChildren = .empty
    ) -> Self {
        .init(
            command: command,
            completion: .passed(evidence: evidence, children: children),
            evidence: evidence.value
        )
    }

    package static func failed(
        command: HeistActionCommand,
        evidence: HeistFailedActionEvidence,
        failure: HeistFailureDetail,
        children: HeistPassingChildren = .empty
    ) -> Self {
        .init(
            command: command,
            completion: .failed(evidence: evidence, failure: failure, children: children),
            evidence: evidence.value
        )
    }

    package static func skipped(
        command: HeistActionCommand,
        children: HeistSkippedChildren = .empty
    ) -> Self {
        .init(command: command, completion: .skipped(children: children), evidence: nil)
    }
}

extension HeistExecutionStepResult {
    private init(path: HeistExecutionPath, node: HeistExecutionStepNode) {
        self.path = path
        self.node = node
    }

    static func admitDecodedNode(
        path: HeistExecutionPath,
        node: HeistExecutionStepNode,
        from decoder: Decoder
    ) throws -> Self {
        guard nodeRelationshipMatches(node) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "heist result node fields have an incompatible relationship"
            ))
        }
        return Self(path: path, node: node)
    }

    package static func action(path: HeistExecutionPath, execution: HeistActionExecution) -> Self {
        Self(path: path,
             node: .action(command: execution.command, completion: execution.completion))
    }

    package static func wait(path: HeistExecutionPath, predicate: AccessibilityPredicate, timeout: WaitTimeout,
                             completion: HeistWaitCompletion) -> Self {
        Self(path: path,
             node: .wait(predicate: predicate, timeout: timeout, completion: completion))
    }

    package static func conditional(path: HeistExecutionPath, completion: HeistCaseSelectionCompletion) -> Self {
        Self(path: path, node: .conditional(completion: completion))
    }

    package static func forEach(path: HeistExecutionPath, declaration: HeistForEachDeclaration,
                                completion: HeistForEachCompletion) -> Self {
        Self(path: path,
             node: .forEach(declaration: declaration, completion: completion))
    }

    package static func forEachIteration(path: HeistExecutionPath, declaration: HeistForEachDeclaration,
                                         completion: HeistForEachCompletion) -> Self {
        Self(path: path,
             node: .forEachIteration(declaration: declaration, completion: completion))
    }

    package static func repeatUntil(path: HeistExecutionPath, declaration: HeistRepeatUntilDeclaration,
                                    completion: HeistRepeatUntilCompletion) -> Self {
        Self(path: path,
             node: .repeatUntil(declaration: declaration, completion: completion))
    }

    package static func repeatUntilIteration(path: HeistExecutionPath,
                                             declaration: HeistRepeatUntilDeclaration,
                                             completion: HeistRepeatUntilIterationCompletion) -> Self {
        Self(path: path,
             node: .repeatUntilIteration(declaration: declaration, completion: completion))
    }

    package static func skipped(path: HeistExecutionPath, step: HeistStep) -> Self {
        var children = HeistSkippedChildren.empty
        if case .heist(let plan) = step {
            for (index, child) in plan.body.enumerated() {
                children.append(
                    path: path.heistBody().step(at: index),
                    step: child
                )
            }
        }
        let node: HeistExecutionStepNode
        switch step {
        case .action(let action):
            node = .action(command: action.command, completion: .skipped(children: children))
        case .wait(let wait):
            node = .wait(predicate: wait.predicate, timeout: wait.timeout, completion: .skipped(children: children))
        case .conditional:
            node = .conditional(completion: .skipped(children: children))
        case .forEachElement(let loop):
            node = .forEach(declaration: .init(loop), completion: .skipped(children: children))
        case .forEachString(let loop):
            node = .forEach(declaration: .init(loop), completion: .skipped(children: children))
        case .repeatUntil(let loop):
            node = .repeatUntil(declaration: .init(loop), completion: .skipped(children: children))
        case .warn(let warning):
            node = .warning(message: warning.message, completion: .skipped(children: children))
        case .fail(let failure):
            node = .failure(message: failure.message, completion: .skipped(children: children))
        case .heist(let plan):
            node = .heist(name: plan.name, completion: .skipped(children: children))
        case .invoke(let invocation):
            node = .invocation(
                path: invocation.path,
                argument: invocation.argument,
                completion: .skipped(children: children)
            )
        }
        return Self(path: path, node: node)
    }

    package static func warning(path: HeistExecutionPath, message: HeistWarningMessage,
                                completion: HeistWarningCompletion) -> Self {
        Self(path: path, node: .warning(message: message, completion: completion))
    }

    package static func failure(path: HeistExecutionPath, message: HeistFailureMessage,
                                completion: HeistFailureCompletion) -> Self {
        Self(path: path, node: .failure(message: message, completion: completion))
    }

    package static func heist(path: HeistExecutionPath, name: HeistPlanName?,
                              completion: HeistGroupCompletion) -> Self {
        Self(path: path, node: .heist(name: name, completion: completion))
    }

    package static func invocation(path: HeistExecutionPath, invocationPath: HeistInvocationPath,
                                   argument: HeistArgument,
                                   completion: HeistInvocationCompletion) -> Self {
        Self(path: path,
             node: .invocation(path: invocationPath, argument: argument, completion: completion))
    }

    private static func nodeRelationshipMatches(_ node: HeistExecutionStepNode) -> Bool {
        switch node {
        case .action(let command, let completion):
            let evidence: HeistActionEvidence?
            switch completion {
            case .passed(let value, _), .childAborted(let value, _, _): evidence = value.value
            case .failed(let value, _, _): evidence = value.value
            case .skipped: evidence = nil
            }
            return evidence?.matches(command: command) != false
        case .forEach(let declaration, let completion):
            return forEachRelationshipMatches(declaration, completion: completion, iteration: false)
        case .forEachIteration(let declaration, let completion):
            return forEachRelationshipMatches(declaration, completion: completion, iteration: true)
        case .repeatUntil(_, let completion):
            return repeatRelationshipMatches(
                completion: completion, iteration: false, passedEvidence: { $0.value }
            )
        case .repeatUntilIteration(_, let completion):
            return repeatRelationshipMatches(
                completion: completion, iteration: true, passedEvidence: { $0.value }
            )
        case .wait(let predicate, _, let completion):
            let evidence: HeistExpectationEvidence?
            switch completion {
            case .passed(let value, _):
                evidence = value.expectation
            case .childAborted(let value, _, _):
                evidence = value
            case .failed(let value, _, _):
                evidence = value
            case .skipped:
                evidence = nil
            }
            return evidence?.predicate == predicate || evidence == nil
        case .conditional, .warning, .failure, .heist, .invocation:
            return true
        }
    }

    private static func forEachRelationshipMatches(
        _ declaration: HeistForEachDeclaration,
        completion: HeistForEachCompletion,
        iteration: Bool
    ) -> Bool {
        let relationship: (evidence: HeistForEachEvidence?, passed: Bool, requiresBoundedCount: Bool)
        switch completion {
        case .passed(let value, _):
            relationship = (value.value, true, true)
        case .childAborted(let value, _, _):
            relationship = (value.value, false, true)
        case .failed(let value, _, _):
            relationship = (value?.value, false, false)
        case .skipped:
            relationship = (nil, false, false)
        }
        guard let evidence = relationship.evidence else { return true }
        let declarationMatches: Bool
        switch (declaration, evidence.source) {
        case (.strings(let strings), .strings):
            declarationMatches = evidence.iterationCount <= strings.count
                && (iteration || !relationship.passed || evidence.iterationCount == strings.count)
        case (.elements(let elements), .elements(let matchedCount)):
            declarationMatches = (!relationship.requiresBoundedCount || matchedCount <= elements.limit)
                && (iteration || !relationship.passed || evidence.iterationCount == matchedCount)
        case (.strings, .elements), (.elements, .strings):
            declarationMatches = false
        }
        guard declarationMatches else { return false }
        if iteration {
            return evidence.iterationOrdinal == evidence.iterationCount - 1
        }
        return evidence.iterationOrdinal == nil
    }

    private static func repeatRelationshipMatches<Passed>(
        completion: HeistExecutionCompletion<
            Passed, HeistFailedRepeatUntilEvidence?, HeistFailedRepeatUntilEvidence
        >,
        iteration: Bool,
        passedEvidence: (Passed) -> HeistRepeatUntilEvidence
    ) -> Bool {
        let evidence: HeistRepeatUntilEvidence?
        switch completion {
        case .passed(let value, _): evidence = passedEvidence(value)
        case .failed(let value, _, _): evidence = value?.value
        case .childAborted(let value, _, _): evidence = value.value
        case .skipped: evidence = nil
        }
        guard let evidence else { return true }
        return (evidence.iterationOrdinal != nil) == iteration
    }
}
