import Foundation
import ThePlans

struct HeistStepFacts {
    let status: HeistExecutionStepStatus
    let failure: HeistFailureDetail?
    let children: [HeistExecutionStepResult]
    let abortedAtChildPath: HeistExecutionPath?
}

enum HeistExecutionStepNode: Codable, Sendable, Equatable {
    case action(command: HeistActionCommand, completion: HeistActionCompletion)
    case wait(predicate: AccessibilityPredicate, timeout: WaitTimeout, completion: HeistWaitCompletion)
    case conditional(completion: HeistCaseSelectionCompletion)
    case forEach(declaration: HeistForEachDeclaration, completion: HeistForEachCompletion)
    case forEachIteration(declaration: HeistForEachDeclaration, completion: HeistForEachCompletion)
    case repeatUntil(declaration: HeistRepeatUntilDeclaration, completion: HeistRepeatUntilCompletion)
    case repeatUntilIteration(
        declaration: HeistRepeatUntilDeclaration,
        completion: HeistRepeatUntilIterationCompletion
    )
    case warning(message: HeistWarningMessage, completion: HeistWarningCompletion)
    case failure(message: HeistFailureMessage, completion: HeistFailureCompletion)
    case heist(name: HeistPlanName?, completion: HeistGroupCompletion)
    case invocation(path: HeistInvocationPath, argument: HeistArgument, completion: HeistInvocationCompletion)

    var facts: HeistStepFacts {
        switch self {
        case .action(_, let completion): completion.facts
        case .wait(_, _, let completion): completion.facts
        case .conditional(let completion): completion.facts
        case .forEach(_, let completion),
             .forEachIteration(_, let completion): completion.facts
        case .repeatUntil(_, let completion): completion.facts
        case .repeatUntilIteration(_, let completion): completion.facts
        case .invocation(_, _, let completion): completion.facts
        case .warning(_, .passed(let children)):
            .init(status: .passed, failure: nil, children: children.values, abortedAtChildPath: nil)
        case .warning(_, .skipped(let children)), .failure(_, .skipped(let children)):
            .init(status: .skipped, failure: nil, children: children.values, abortedAtChildPath: nil)
        case .failure(_, .failed(let failure, let children)):
            .init(status: .failed, failure: failure, children: children.values, abortedAtChildPath: nil)
        case .failure(_, .childAborted(let failure, let children)):
            .init(
                status: .failed,
                failure: failure,
                children: children.values,
                abortedAtChildPath: children.abortedAtPath
            )
        case .heist(_, .passed(let children)):
            .init(status: .passed, failure: nil, children: children.values, abortedAtChildPath: nil)
        case .heist(_, .childAborted(let failure, let children)):
            .init(
                status: .failed,
                failure: failure,
                children: children.values,
                abortedAtChildPath: children.abortedAtPath
            )
        case .heist(_, .skipped(let children)):
            .init(status: .skipped, failure: nil, children: children.values, abortedAtChildPath: nil)
        }
    }

}
