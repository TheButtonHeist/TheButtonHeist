import Foundation

/// A canonical path to one node in a heist execution tree.
public struct HeistExecutionPath: Sendable, Equatable, Hashable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    private enum Component: Sendable, Equatable, Hashable {
        case field(Field)
        case index(Int)
    }

    private enum Field: String, Sendable, Equatable, Hashable, CaseIterable {
        case body
        case cases
        case conditional
        case elseBody = "else_body"
        case forEachElement = "for_each_element"
        case forEachString = "for_each_string"
        case heist
        case invoke
        case iterations
        case repeatUntil = "repeat_until"
        case wait
    }

    private enum ComponentPattern {
        case field(Field)
        case index(Int)
        case anyIndex
    }

    package enum ChildBranch: Sendable, Hashable {
        case waitElseBody
        case conditionalCase(Int)
        case conditionalElse
        case forEachElementIterations
        case forEachStringIterations
        case repeatUntilIterations
        case body
        case heistBody
        case invocationBody
    }

    package struct ChildEdge: Sendable, Hashable {
        package let branch: ChildBranch
        package let ordinal: Int

        package var caseIndex: Int? {
            guard case .conditionalCase(let index) = branch else { return nil }
            return index
        }

        package var isConditionalExecutionBranch: Bool {
            switch branch {
            case .conditionalCase, .conditionalElse:
                true
            case .waitElseBody,
                 .forEachElementIterations,
                 .forEachStringIterations,
                 .repeatUntilIterations,
                 .body,
                 .heistBody,
                 .invocationBody:
                false
            }
        }
    }

    private let components: [Component]

    private init(components: [Component]) {
        self.components = components
    }

    public init(validating description: String) throws {
        components = try Self.parse(description)
    }

    public init(stringLiteral value: String) {
        do {
            try self.init(validating: value)
        } catch {
            preconditionFailure(String(describing: error))
        }
    }

    public var description: String {
        components.reduce(into: "$") { result, component in
            switch component {
            case .field(let field):
                result += ".\(field.rawValue)"
            case .index(let index):
                result += "[\(index)]"
            }
        }
    }

    package static let body = Self(components: [.field(.body)])

    package func step(at index: Int) -> Self {
        appending(.index(index))
    }

    package func heistBody() -> Self {
        appending(.field(.heist), .field(.body))
    }

    package func invocationBody() -> Self {
        appending(.field(.invoke), .field(.body))
    }

    package func conditionalCaseBody(at index: Int) -> Self {
        appending(.field(.conditional), .field(.cases), .index(index), .field(.body))
    }

    package func conditionalElseBody() -> Self {
        appending(.field(.conditional), .field(.elseBody))
    }

    package func waitElseBody() -> Self {
        appending(.field(.wait), .field(.elseBody))
    }

    package func forEachElementIteration(at index: Int) -> Self {
        appending(.field(.forEachElement), .field(.iterations), .index(index))
    }

    package func forEachStringIteration(at index: Int) -> Self {
        appending(.field(.forEachString), .field(.iterations), .index(index))
    }

    package func repeatUntilIteration(at index: Int) -> Self {
        appending(.field(.repeatUntil), .field(.iterations), .index(index))
    }

    package func iterationBody() -> Self {
        appending(.field(.body))
    }

    package func isDescendant(of ancestor: Self) -> Bool {
        components.count > ancestor.components.count
            && components.starts(with: ancestor.components)
    }

    package func isRootStepPath() -> Bool {
        rootStepIndex != nil
    }

    package var rootStepIndex: Int? {
        guard components.count == 2,
              case .field(.body) = components[0],
              case .index(let index) = components[1]
        else { return nil }
        return index
    }

    package func isLegalChild(
        of parent: HeistExecutionStepResult,
        child: HeistExecutionStepResult,
        childOrdinal: Int
    ) -> Bool {
        guard let edge = childEdge(after: parent.path),
              edge.ordinal == childOrdinal else { return false }
        let regularChild = switch parent.kind {
        case .action, .warn, .fail:
            false
        case .wait:
            edge.branch == .waitElseBody
        case .conditional:
            edge.isConditionalExecutionBranch
        case .forEachElement:
            child.isForEachElementIteration && edge.branch == .forEachElementIterations
        case .forEachString:
            child.isForEachStringIteration && edge.branch == .forEachStringIterations
        case .forEachIteration, .repeatUntilIteration:
            edge.branch == .body
        case .repeatUntil:
            child.kind == .repeatUntilIteration && edge.branch == .repeatUntilIterations
        case .heist:
            edge.branch == .heistBody
        case .invoke:
            edge.branch == .invocationBody
        }

        return regularChild
    }

    package func childEdge(after parent: Self) -> ChildEdge? {
        guard isDescendant(of: parent) else { return nil }
        let suffix = Array(components.dropFirst(parent.components.count))
        if let ordinal = Self.ordinal(in: suffix, matching: [.field(.wait), .field(.elseBody), .anyIndex]) {
            return ChildEdge(branch: .waitElseBody, ordinal: ordinal)
        }
        if suffix.count == 5,
           case .field(.conditional) = suffix[0],
           case .field(.cases) = suffix[1],
           case .index(let caseIndex) = suffix[2],
           case .field(.body) = suffix[3],
           case .index(let ordinal) = suffix[4] {
            return ChildEdge(branch: .conditionalCase(caseIndex), ordinal: ordinal)
        }
        if let ordinal = Self.ordinal(in: suffix, matching: [.field(.conditional), .field(.elseBody), .anyIndex]) {
            return ChildEdge(branch: .conditionalElse, ordinal: ordinal)
        }
        if let ordinal = Self.ordinal(in: suffix, matching: [.field(.forEachElement), .field(.iterations), .anyIndex]) {
            return ChildEdge(branch: .forEachElementIterations, ordinal: ordinal)
        }
        if let ordinal = Self.ordinal(in: suffix, matching: [.field(.forEachString), .field(.iterations), .anyIndex]) {
            return ChildEdge(branch: .forEachStringIterations, ordinal: ordinal)
        }
        if let ordinal = Self.ordinal(in: suffix, matching: [.field(.repeatUntil), .field(.iterations), .anyIndex]) {
            return ChildEdge(branch: .repeatUntilIterations, ordinal: ordinal)
        }
        if let ordinal = Self.ordinal(in: suffix, matching: [.field(.body), .anyIndex]) {
            return ChildEdge(branch: .body, ordinal: ordinal)
        }
        if let ordinal = Self.ordinal(in: suffix, matching: [.field(.heist), .field(.body), .anyIndex]) {
            return ChildEdge(branch: .heistBody, ordinal: ordinal)
        }
        if let ordinal = Self.ordinal(in: suffix, matching: [.field(.invoke), .field(.body), .anyIndex]) {
            return ChildEdge(branch: .invocationBody, ordinal: ordinal)
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let description = try container.decode(String.self)
        do {
            try self.init(validating: description)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid heist execution path \(description): \(error)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private func appending(_ additions: Component...) -> Self {
        Self(components: components + additions)
    }

    private func matches(_ patterns: [ComponentPattern]) -> Bool {
        Self.components(components, match: patterns)
    }

    private static func components<Components>(
        _ components: Components,
        match patterns: [ComponentPattern]
    ) -> Bool where Components: Collection, Components.Element == Component {
        components.count == patterns.count && zip(components, patterns).allSatisfy { component, pattern in
            switch (component, pattern) {
            case (.field(let componentField), .field(let patternField)):
                componentField == patternField
            case (.index(let componentIndex), .index(let patternIndex)):
                componentIndex == patternIndex
            case (.index, .anyIndex):
                true
            default:
                false
            }
        }
    }

    private static func ordinal(
        in components: [Component],
        matching patterns: [ComponentPattern]
    ) -> Int? {
        guard Self.components(components, match: patterns),
              case .index(let ordinal) = components.last else { return nil }
        return ordinal
    }

    private static func parse(_ description: String) throws -> [Component] {
        guard description.first == "$" else {
            throw ValidationError.missingRoot
        }

        var components: [Component] = []
        var index = description.index(after: description.startIndex)
        while index < description.endIndex {
            switch description[index] {
            case ".":
                index = description.index(after: index)
                let start = index
                while index < description.endIndex, description[index] != ".", description[index] != "[" {
                    index = description.index(after: index)
                }
                let name = String(description[start..<index])
                guard let field = Field(rawValue: name) else {
                    throw ValidationError.unknownField(name)
                }
                components.append(.field(field))
            case "[":
                index = description.index(after: index)
                let start = index
                while index < description.endIndex, description[index].isNumber {
                    index = description.index(after: index)
                }
                guard start < index,
                      index < description.endIndex,
                      description[index] == "]",
                      let value = Int(description[start..<index])
                else {
                    throw ValidationError.invalidIndex
                }
                components.append(.index(value))
                index = description.index(after: index)
            default:
                throw ValidationError.invalidSeparator
            }
        }
        return components
    }
}

private extension HeistExecutionPath {
    enum ValidationError: Error, CustomStringConvertible {
        case missingRoot
        case unknownField(String)
        case invalidIndex
        case invalidSeparator

        var description: String {
            switch self {
            case .missingRoot:
                return "path must start with $"
            case .unknownField(let field):
                return "unknown field \(field)"
            case .invalidIndex:
                return "indexes must be non-negative integers"
            case .invalidSeparator:
                return "components must start with . or ["
            }
        }
    }
}
