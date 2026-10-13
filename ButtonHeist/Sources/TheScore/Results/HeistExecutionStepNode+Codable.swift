import Foundation
import ThePlans

extension HeistExecutionStepNode {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case outcome
        case command
        case predicate
        case timeout
        case parameter
        case count
        case matching
        case limit
        case path
        case argument
        case name
        case message
        case evidence
        case failure
        case children
    }

    private enum NodeType: String, Codable {
        case action
        case wait
        case conditional
        case forEachElement = "for_each_element"
        case forEachString = "for_each_string"
        case forEachElementIteration = "for_each_element_iteration"
        case forEachStringIteration = "for_each_string_iteration"
        case repeatUntil = "repeat_until"
        case repeatUntilIteration = "repeat_until_iteration"
        case warning
        case failure
        case heist
        case invocation
    }

    private enum Outcome: String, Codable {
        case passed
        case failed
        case childAborted = "child_aborted"
        case skipped
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: CodingKeys.self, typeName: "heist execution step node")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)
        switch type {
        case .action:
            self = try Self.decodeAction(from: container)
        case .wait:
            self = .wait(
                predicate: try container.decode(AccessibilityPredicate.self, forKey: .predicate),
                timeout: try container.decode(WaitTimeout.self, forKey: .timeout),
                completion: try Self.decodeCompletion(
                    from: container,
                    semanticKeys: [.type, .predicate, .timeout],
                    typeName: type.rawValue
                )
            )
        case .conditional:
            self = .conditional(completion: try Self.decodeCompletion(
                from: container,
                semanticKeys: [.type],
                typeName: type.rawValue
            ))
        case .forEachElement,
             .forEachElementIteration,
             .forEachString,
             .forEachStringIteration:
            self = try Self.decodeForEach(type, from: container)
        case .repeatUntil:
            self = try Self.decodeRepeatUntil(from: container)
        case .repeatUntilIteration:
            self = try Self.decodeRepeatUntilIteration(from: container)
        case .warning:
            self = .warning(
                message: try container.decode(HeistWarningMessage.self, forKey: .message),
                completion: try Self.decodeWarning(from: container)
            )
        case .failure:
            self = .failure(
                message: try container.decode(HeistFailureMessage.self, forKey: .message),
                completion: try Self.decodeFailure(from: container)
            )
        case .heist:
            self = .heist(
                name: try container.decodeIfPresent(HeistPlanName.self, forKey: .name),
                completion: try Self.decodeGroup(from: container)
            )
        case .invocation:
            self = .invocation(
                path: try container.decode(HeistInvocationPath.self, forKey: .path),
                argument: try container.decode(HeistArgument.self, forKey: .argument),
                completion: try Self.decodeCompletion(
                    from: container,
                    semanticKeys: [.type, .path, .argument],
                    typeName: type.rawValue
                )
            )
        }
    }

    private static func decodeAction(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Self {
        let command = try container.decode(HeistActionCommand.self, forKey: .command)
        let completion: HeistActionCompletion = try decodeCompletion(
            from: container,
            semanticKeys: [.type, .command],
            typeName: NodeType.action.rawValue
        )
        return .action(command: command, completion: completion)
    }

    private static func decodeForEach(
        _ type: NodeType,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Self {
        let declaration: HeistForEachDeclaration
        let semanticKeys: Set<CodingKeys>
        let isIteration: Bool
        switch type {
        case .forEachElement, .forEachElementIteration:
            guard let element = HeistForEachElementDeclaration(
                parameter: try container.decode(HeistReferenceName.self, forKey: .parameter),
                matching: try container.decode(ElementPredicate.self, forKey: .matching),
                limit: try container.decode(Int.self, forKey: .limit)
            ) else {
                throw invalidNode(forKey: .limit, in: container, "for_each_element limit must be positive")
            }
            declaration = .elements(element)
            semanticKeys = [.type, .parameter, .matching, .limit]
            isIteration = type == .forEachElementIteration
        case .forEachString, .forEachStringIteration:
            guard let strings = HeistForEachStringDeclaration(
                parameter: try container.decode(HeistReferenceName.self, forKey: .parameter),
                count: try container.decode(Int.self, forKey: .count)
            ) else {
                throw invalidNode(forKey: .count, in: container, "for_each_string count must be nonnegative")
            }
            declaration = .strings(strings)
            semanticKeys = [.type, .parameter, .count]
            isIteration = type == .forEachStringIteration
        case .action,
             .wait,
             .conditional,
             .repeatUntil,
             .repeatUntilIteration,
             .warning,
             .failure,
             .heist,
             .invocation:
            preconditionFailure("Only for_each node types reach for_each decoding")
        }
        let completion: HeistForEachCompletion = try decodeCompletion(
            from: container,
            semanticKeys: semanticKeys,
            typeName: type.rawValue
        )
        return isIteration
            ? .forEachIteration(declaration: declaration, completion: completion)
            : .forEach(declaration: declaration, completion: completion)
    }

    private static func decodeRepeatUntil(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Self {
        let declaration = HeistRepeatUntilDeclaration(
            predicate: try container.decode(AccessibilityPredicate.self, forKey: .predicate),
            timeout: try container.decode(WaitTimeout.self, forKey: .timeout)
        )
        let completion: HeistRepeatUntilCompletion = try decodeCompletion(
            from: container,
            semanticKeys: [.type, .predicate, .timeout],
            typeName: NodeType.repeatUntil.rawValue
        )
        return .repeatUntil(declaration: declaration, completion: completion)
    }

    private static func decodeRepeatUntilIteration(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Self {
        let declaration = HeistRepeatUntilDeclaration(
            predicate: try container.decode(AccessibilityPredicate.self, forKey: .predicate),
            timeout: try container.decode(WaitTimeout.self, forKey: .timeout)
        )
        let completion: HeistRepeatUntilIterationCompletion = try decodeCompletion(
            from: container,
            semanticKeys: [.type, .predicate, .timeout],
            typeName: NodeType.repeatUntilIteration.rawValue
        )
        return .repeatUntilIteration(declaration: declaration, completion: completion)
    }

    private static func invalidNode(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        _ description: String
    ) -> DecodingError {
        .dataCorruptedError(forKey: key, in: container, debugDescription: description)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .action(let command, let completion):
            try container.encode(NodeType.action, forKey: .type)
            try container.encode(command, forKey: .command)
            try Self.encode(completion, to: &container)
        case .wait(let predicate, let timeout, let completion):
            try container.encode(NodeType.wait, forKey: .type)
            try container.encode(predicate, forKey: .predicate)
            try container.encode(timeout, forKey: .timeout)
            try Self.encode(completion, to: &container)
        case .conditional(let completion):
            try container.encode(NodeType.conditional, forKey: .type)
            try Self.encode(completion, to: &container)
        case .forEach(let declaration, let completion):
            try Self.encodeLoop(declaration, completion, iteration: false, to: &container)
        case .forEachIteration(let declaration, let completion):
            try Self.encodeLoop(declaration, completion, iteration: true, to: &container)
        case .repeatUntil(let declaration, let completion):
            try container.encode(NodeType.repeatUntil, forKey: .type)
            try container.encode(declaration.predicate, forKey: .predicate)
            try container.encode(declaration.timeout, forKey: .timeout)
            try Self.encode(completion, to: &container)
        case .repeatUntilIteration(let declaration, let completion):
            try container.encode(NodeType.repeatUntilIteration, forKey: .type)
            try container.encode(declaration.predicate, forKey: .predicate)
            try container.encode(declaration.timeout, forKey: .timeout)
            try Self.encode(completion, to: &container)
        case .warning(let message, let completion):
            try container.encode(NodeType.warning, forKey: .type)
            try container.encode(message, forKey: .message)
            try Self.encode(completion, to: &container)
        case .failure(let message, let completion):
            try container.encode(NodeType.failure, forKey: .type)
            try container.encode(message, forKey: .message)
            try Self.encode(completion, to: &container)
        case .heist(let name, let completion):
            try container.encode(NodeType.heist, forKey: .type)
            try container.encodeIfPresent(name, forKey: .name)
            try Self.encode(completion, to: &container)
        case .invocation(let path, let argument, let completion):
            try container.encode(NodeType.invocation, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(argument, forKey: .argument)
            try Self.encode(completion, to: &container)
        }
    }

    private static func decodeCompletion<Passed, Failed, Aborted>(
        from container: KeyedDecodingContainer<CodingKeys>,
        semanticKeys: Set<CodingKeys>,
        typeName: String
    ) throws -> HeistExecutionCompletion<Passed, Failed, Aborted>
    where Passed: Codable & Sendable & Equatable,
          Failed: Codable & Sendable & Equatable,
          Aborted: Codable & Sendable & Equatable {
        switch try container.decode(Outcome.self, forKey: .outcome) {
        case .passed:
            try container.rejectIncompatibleFields(
                allowing: semanticKeys.union([.outcome, .evidence, .children]),
                typeName: "passed \(typeName) result node"
            )
            return .passed(
                evidence: try container.decode(Passed.self, forKey: .evidence),
                children: try container.decode(HeistPassingChildren.self, forKey: .children)
            )
        case .failed:
            try container.rejectIncompatibleFields(
                allowing: semanticKeys.union([.outcome, .evidence, .failure, .children]),
                typeName: "failed \(typeName) result node"
            )
            return .failed(
                evidence: try container.decode(Failed.self, forKey: .evidence),
                failure: try container.decode(HeistFailureDetail.self, forKey: .failure),
                children: try container.decode(HeistPassingChildren.self, forKey: .children)
            )
        case .childAborted:
            try container.rejectIncompatibleFields(
                allowing: semanticKeys.union([.outcome, .evidence, .failure, .children]),
                typeName: "child-aborted \(typeName) result node"
            )
            return .childAborted(
                evidence: try container.decode(Aborted.self, forKey: .evidence),
                failure: try container.decode(HeistFailureDetail.self, forKey: .failure),
                children: try container.decode(HeistAbortedChildren.self, forKey: .children)
            )
        case .skipped:
            try container.rejectIncompatibleFields(
                allowing: semanticKeys.union([.outcome, .children]),
                typeName: "skipped \(typeName) result node"
            )
            return .skipped(children: try container.decode(HeistSkippedChildren.self, forKey: .children))
        }
    }

    private static func encode<Passed, Failed, Aborted>(
        _ completion: HeistExecutionCompletion<Passed, Failed, Aborted>,
        to container: inout KeyedEncodingContainer<CodingKeys>
    ) throws where Passed: Codable, Failed: Codable, Aborted: Codable {
        switch completion {
        case .passed(let evidence, let children):
            try container.encode(Outcome.passed, forKey: .outcome)
            try container.encode(evidence, forKey: .evidence)
            try container.encode(children, forKey: .children)
        case .failed(let evidence, let failure, let children):
            try container.encode(Outcome.failed, forKey: .outcome)
            try container.encode(evidence, forKey: .evidence)
            try container.encode(failure, forKey: .failure)
            try container.encode(children, forKey: .children)
        case .childAborted(let evidence, let failure, let children):
            try container.encode(Outcome.childAborted, forKey: .outcome)
            try container.encode(evidence, forKey: .evidence)
            try container.encode(failure, forKey: .failure)
            try container.encode(children, forKey: .children)
        case .skipped(let children):
            try container.encode(Outcome.skipped, forKey: .outcome)
            try container.encode(children, forKey: .children)
        }
    }

    private static func decodeWarning(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> HeistWarningCompletion {
        switch try container.decode(Outcome.self, forKey: .outcome) {
        case .passed:
            try container.rejectIncompatibleFields(
                allowing: [.type, .message, .outcome, .children],
                typeName: "passed warning result node"
            )
            return .passed(children: try container.decode(HeistPassingChildren.self, forKey: .children))
        case .skipped:
            try container.rejectIncompatibleFields(
                allowing: [.type, .message, .outcome, .children],
                typeName: "skipped warning result node"
            )
            return .skipped(children: try container.decode(HeistSkippedChildren.self, forKey: .children))
        case .failed, .childAborted:
            throw incompatibleOutcome("warning", in: container)
        }
    }

    private static func decodeFailure(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> HeistFailureCompletion {
        switch try container.decode(Outcome.self, forKey: .outcome) {
        case .failed:
            try container.rejectIncompatibleFields(
                allowing: [.type, .message, .outcome, .failure, .children],
                typeName: "failed explicit-failure result node"
            )
            return .failed(
                failure: try container.decode(HeistFailureDetail.self, forKey: .failure),
                children: try container.decode(HeistPassingChildren.self, forKey: .children)
            )
        case .childAborted:
            try container.rejectIncompatibleFields(
                allowing: [.type, .message, .outcome, .failure, .children],
                typeName: "child-aborted explicit-failure result node"
            )
            return .childAborted(
                failure: try container.decode(HeistFailureDetail.self, forKey: .failure),
                children: try container.decode(HeistAbortedChildren.self, forKey: .children)
            )
        case .skipped:
            try container.rejectIncompatibleFields(
                allowing: [.type, .message, .outcome, .children],
                typeName: "skipped explicit-failure result node"
            )
            return .skipped(children: try container.decode(HeistSkippedChildren.self, forKey: .children))
        case .passed:
            throw incompatibleOutcome("explicit-failure", in: container)
        }
    }

    private static func decodeGroup(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> HeistGroupCompletion {
        let semanticKeys: Set<CodingKeys> = [.type, .name, .outcome, .children]
        switch try container.decode(Outcome.self, forKey: .outcome) {
        case .passed:
            try container.rejectIncompatibleFields(allowing: semanticKeys, typeName: "passed heist result node")
            return .passed(children: try container.decode(HeistPassingChildren.self, forKey: .children))
        case .childAborted:
            try container.rejectIncompatibleFields(
                allowing: semanticKeys.union([.failure]),
                typeName: "child-aborted heist result node"
            )
            return .childAborted(
                failure: try container.decode(HeistFailureDetail.self, forKey: .failure),
                children: try container.decode(HeistAbortedChildren.self, forKey: .children)
            )
        case .skipped:
            try container.rejectIncompatibleFields(allowing: semanticKeys, typeName: "skipped heist result node")
            return .skipped(children: try container.decode(HeistSkippedChildren.self, forKey: .children))
        case .failed:
            throw incompatibleOutcome("heist", in: container)
        }
    }

    private static func incompatibleOutcome(
        _ type: String,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> DecodingError {
        .dataCorruptedError(
            forKey: .outcome,
            in: container,
            debugDescription: "outcome is not legal for a \(type) result node"
        )
    }

    private static func encode(
        _ completion: HeistWarningCompletion,
        to container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch completion {
        case .passed(let children):
            try container.encode(Outcome.passed, forKey: .outcome)
            try container.encode(children, forKey: .children)
        case .skipped(let children):
            try container.encode(Outcome.skipped, forKey: .outcome)
            try container.encode(children, forKey: .children)
        }
    }

    private static func encode(
        _ completion: HeistFailureCompletion,
        to container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch completion {
        case .failed(let failure, let children):
            try container.encode(Outcome.failed, forKey: .outcome)
            try container.encode(failure, forKey: .failure)
            try container.encode(children, forKey: .children)
        case .childAborted(let failure, let children):
            try container.encode(Outcome.childAborted, forKey: .outcome)
            try container.encode(failure, forKey: .failure)
            try container.encode(children, forKey: .children)
        case .skipped(let children):
            try container.encode(Outcome.skipped, forKey: .outcome)
            try container.encode(children, forKey: .children)
        }
    }

    private static func encode(
        _ completion: HeistGroupCompletion,
        to container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch completion {
        case .passed(let children):
            try container.encode(Outcome.passed, forKey: .outcome)
            try container.encode(children, forKey: .children)
        case .childAborted(let failure, let children):
            try container.encode(Outcome.childAborted, forKey: .outcome)
            try container.encode(failure, forKey: .failure)
            try container.encode(children, forKey: .children)
        case .skipped(let children):
            try container.encode(Outcome.skipped, forKey: .outcome)
            try container.encode(children, forKey: .children)
        }
    }

    private static func encodeLoop(
        _ declaration: HeistForEachDeclaration,
        _ completion: HeistForEachCompletion,
        iteration: Bool,
        to container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch declaration {
        case .strings(let strings):
            try container.encode(
                iteration ? NodeType.forEachStringIteration : .forEachString,
                forKey: .type
            )
            try container.encode(strings.parameter, forKey: .parameter)
            try container.encode(strings.count, forKey: .count)
        case .elements(let elements):
            try container.encode(
                iteration ? NodeType.forEachElementIteration : .forEachElement,
                forKey: .type
            )
            try container.encode(elements.parameter, forKey: .parameter)
            try container.encode(elements.matching, forKey: .matching)
            try container.encode(elements.limit, forKey: .limit)
        }
        try encode(completion, to: &container)
    }

}
