import Foundation

// MARK: - Heist Execution Environment

public struct HeistReferenceName: Codable, Hashable, Sendable, Equatable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(stringLiteral value: String) {
        do {
            try self.init(validating: value)
        } catch {
            preconditionFailure(String(describing: error))
        }
    }

    public init(validating value: String) throws {
        rawValue = try HeistIdentifierGrammar.admit(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(validating: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

}

extension HeistReferenceName: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}

extension HeistReferenceName {
    static func decode<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        type: String? = nil
    ) throws -> HeistReferenceName {
        try decode(try container.decode(String.self, forKey: key), from: container, forKey: key, type: type)
    }

    static func decodeIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        type: String? = nil
    ) throws -> HeistReferenceName? {
        guard let value = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return try decode(value, from: container, forKey: key, type: type)
    }

    private static func decode<K: CodingKey>(
        _ value: String,
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        type: String?
    ) throws -> HeistReferenceName {
        do {
            return try HeistReferenceName(validating: value)
        } catch {
            let subject = type.map { "\($0) reference" } ?? key.stringValue
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(subject) \(error)"
            )
        }
    }
}

package struct HeistExecutionEnvironment: Codable, Sendable, Equatable {
    package static let empty = HeistExecutionEnvironment()

    package let targets: [HeistReferenceName: ResolvedAccessibilityTarget]
    package let strings: [HeistReferenceName: String]

    package init(
        targets: [HeistReferenceName: ResolvedAccessibilityTarget] = [:],
        strings: [HeistReferenceName: String] = [:]
    ) {
        self.targets = targets
        self.strings = strings
    }

    package func binding(
        target: ResolvedAccessibilityTarget,
        to parameter: HeistReferenceName
    ) -> HeistExecutionEnvironment {
        var targets = self.targets
        targets[parameter] = target
        return HeistExecutionEnvironment(targets: targets, strings: strings)
    }

    package func binding(string: String, to parameter: HeistReferenceName) -> HeistExecutionEnvironment {
        var strings = self.strings
        strings[parameter] = string
        return HeistExecutionEnvironment(targets: targets, strings: strings)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case targets
        case strings
    }

    package init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(
            allowed: CodingKeys.self,
            typeName: "heist execution environment"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targets = try Self.decodeBindings(
            try container.decodeIfPresent(
                [String: ResolvedAccessibilityTarget].self,
                forKey: .targets
            ) ?? [:],
            from: container,
            forKey: .targets
        )
        strings = try Self.decodeBindings(
            try container.decodeIfPresent([String: String].self, forKey: .strings) ?? [:],
            from: container,
            forKey: .strings
        )
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            Dictionary(uniqueKeysWithValues: targets.map { ($0.key.rawValue, $0.value) }),
            forKey: .targets
        )
        try container.encode(
            Dictionary(uniqueKeysWithValues: strings.map { ($0.key.rawValue, $0.value) }),
            forKey: .strings
        )
    }

    private static func decodeBindings<Value, Key: CodingKey>(
        _ bindings: [String: Value],
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> [HeistReferenceName: Value] {
        try Dictionary(uniqueKeysWithValues: bindings.map { rawName, value in
            do {
                return (try HeistReferenceName(validating: rawName), value)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "invalid binding name \(rawName): \(error)"
                )
            }
        })
    }
}

struct HeistReferenceScope: Sendable, Equatable {
    static let empty = HeistReferenceScope()

    var targetRefs: Set<HeistReferenceName> = []
    var stringRefs: Set<HeistReferenceName> = []
}

struct HeistReferenceBinding: Sendable, Equatable {
    enum Value: Sendable, Equatable {
        case string(String)
        case accessibilityTarget(ResolvedAccessibilityTarget)
    }

    static let runtimeSafetyStringPlaceholder = "__heist_parameter__"
    static let runtimeSafetyAccessibilityTargetPlaceholder = ResolvedAccessibilityTarget.predicate(
        .identifier("__heist_parameter__")
    )

    let reference: HeistReferenceName
    let value: Value

    static func runtimeSafetyPlaceholder(for parameter: HeistParameter) -> HeistReferenceBinding? {
        switch parameter {
        case .none:
            return nil
        case .string(let name):
            return HeistReferenceBinding(reference: name, value: .string(runtimeSafetyStringPlaceholder))
        case .accessibilityTarget(let name):
            return HeistReferenceBinding(
                reference: name,
                value: .accessibilityTarget(runtimeSafetyAccessibilityTargetPlaceholder)
            )
        }
    }
}

struct HeistReferenceBindingContext: Sendable, Equatable {
    static let empty = HeistReferenceBindingContext()

    let bindings: [HeistReferenceBinding]

    init(bindings: [HeistReferenceBinding] = []) {
        self.bindings = bindings
    }

    var scope: HeistReferenceScope {
        bindings.reduce(into: .empty) { scope, binding in
            switch binding.value {
            case .string:
                scope.stringRefs.insert(binding.reference)
            case .accessibilityTarget:
                scope.targetRefs.insert(binding.reference)
            }
        }
    }

    var environment: HeistExecutionEnvironment {
        var targets: [HeistReferenceName: ResolvedAccessibilityTarget] = [:]
        var strings: [HeistReferenceName: String] = [:]
        for binding in bindings {
            switch binding.value {
            case .string(let value):
                strings[binding.reference] = value
            case .accessibilityTarget(let target):
                targets[binding.reference] = target
            }
        }
        return HeistExecutionEnvironment(targets: targets, strings: strings)
    }

    var invariantFailures: [String] {
        var failures: [String] = []
        let projectedScope = scope
        let projectedEnvironment = environment
        let environmentTargetRefs = Set(projectedEnvironment.targets.keys)
        if projectedScope.targetRefs != environmentTargetRefs {
            failures.append(
                "target refs scope=\(projectedScope.targetRefs.sortedDescriptions) environment=\(environmentTargetRefs.sortedDescriptions)"
            )
        }
        let environmentStringRefs = Set(projectedEnvironment.strings.keys)
        if projectedScope.stringRefs != environmentStringRefs {
            failures.append(
                "string refs scope=\(projectedScope.stringRefs.sortedDescriptions) environment=\(environmentStringRefs.sortedDescriptions)"
            )
        }
        return failures
    }

    func binding(
        target: ResolvedAccessibilityTarget,
        to parameter: HeistReferenceName
    ) -> HeistReferenceBindingContext {
        binding(HeistReferenceBinding(reference: parameter, value: .accessibilityTarget(target)))
    }

    func binding(string: String, to parameter: HeistReferenceName) -> HeistReferenceBindingContext {
        binding(HeistReferenceBinding(reference: parameter, value: .string(string)))
    }

    func binding(parameter: HeistParameter) -> HeistReferenceBindingContext {
        guard let binding = HeistReferenceBinding.runtimeSafetyPlaceholder(for: parameter) else { return self }
        return self.binding(binding)
    }

    func binding(argument: HeistArgument, to parameter: HeistParameter) throws -> HeistReferenceBindingContext {
        guard argument.kind == parameter.kind else {
            throw HeistExpressionError.parameterArgumentMismatch(parameter: parameter.kind, argument: argument.kind)
        }
        switch (parameter, argument.core) {
        case (.none, .none):
            return self
        case (.string(let name), .string(let value)):
            return binding(string: try value.resolve(in: environment), to: name)
        case (.accessibilityTarget(let name), .accessibilityTarget(let target)):
            return binding(target: try target.resolve(in: environment), to: name)
        default:
            throw HeistExpressionError.parameterArgumentMismatch(parameter: parameter.kind, argument: argument.kind)
        }
    }

    static func runtimeSafetyPlaceholder(for parameter: HeistParameter) -> HeistReferenceBindingContext {
        empty.binding(parameter: parameter)
    }

    private func binding(_ binding: HeistReferenceBinding) -> HeistReferenceBindingContext {
        HeistReferenceBindingContext(bindings: bindings + [binding])
    }
}

extension HeistPlan {
    var parameterReferenceBindings: HeistReferenceBindingContext {
        HeistReferenceBindingContext.runtimeSafetyPlaceholder(for: parameter)
    }
}

private extension Set where Element == HeistReferenceName {
    var sortedDescriptions: String {
        "[" + map(\.rawValue).sorted().joined(separator: ", ") + "]"
    }
}

public enum HeistExpressionError: Error, Sendable, Equatable, CustomStringConvertible {
    case unresolvedTargetReference(String)
    case unresolvedStringReference(String)
    case invalidStringMatch(mode: String)
    case unsupportedHeistActionCommand(String)
    case parameterArgumentMismatch(parameter: HeistParameterKind, argument: HeistParameterKind)

    public var description: String {
        switch self {
        case .unresolvedTargetReference(let reference):
            return "unresolved target reference \"\(reference)\""
        case .unresolvedStringReference(let reference):
            return "unresolved string reference \"\(reference)\""
        case .invalidStringMatch(let mode):
            return "\(mode) string match value must not be empty"
        case .unsupportedHeistActionCommand(let command):
            return "unsupported heist action command \"\(command)\""
        case .parameterArgumentMismatch(let parameter, let argument):
            return "heist argument type \(argument.rawValue) does not match parameter type \(parameter.rawValue)"
        }
    }
}

package extension HeistExecutionEnvironment {
    func binding(argument: HeistArgument, to parameter: HeistParameter) throws -> HeistExecutionEnvironment {
        guard argument.kind == parameter.kind else {
            throw HeistExpressionError.parameterArgumentMismatch(parameter: parameter.kind, argument: argument.kind)
        }
        switch (parameter, argument.core) {
        case (.none, .none):
            return self
        case (.string(let name), .string(let value)):
            return binding(string: try value.resolve(in: self), to: name)
        case (.accessibilityTarget(let name), .accessibilityTarget(let target)):
            return binding(target: try target.resolve(in: self), to: name)
        default:
            throw HeistExpressionError.parameterArgumentMismatch(parameter: parameter.kind, argument: argument.kind)
        }
    }
}
