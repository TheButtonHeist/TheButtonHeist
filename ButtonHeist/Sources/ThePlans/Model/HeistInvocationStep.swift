import Foundation

public enum HeistPathValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyPath
    case emptyComponent(index: Int)
    case invalidComponent(index: Int, component: String)

    public var description: String {
        switch self {
        case .emptyPath:
            return "heist path must not be empty"
        case .emptyComponent(let index):
            return "heist path component at index \(index) must not be empty"
        case .invalidComponent(let index, let component):
            return "heist path component at index \(index) must be a Swift-style identifier: \(component)"
        }
    }
}

public struct HeistDefinitionPath: Sendable, Equatable, Hashable, CustomStringConvertible,
    ExpressibleByStringLiteral, Codable {
    fileprivate let value: HeistPathValue

    public var components: [HeistPlanName] { value.components }
    public var description: String { value.description }

    public init(validating value: String) throws { self.value = try HeistPathValue(validating: value) }
    public init(stringLiteral value: String) { self.value = HeistPathValue(stringLiteral: value) }
    public init(from decoder: Decoder) throws { value = try HeistPathValue(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }

    package init(first: HeistPlanName, remaining: [HeistPlanName] = []) {
        value = HeistPathValue(first: first, remaining: remaining)
    }
}

public struct HeistInvocationPath: Sendable, Equatable, Hashable, CustomStringConvertible,
    ExpressibleByStringLiteral, Codable {
    fileprivate let value: HeistPathValue

    public var components: [HeistPlanName] { value.components }
    public var description: String { value.description }

    public init(validating value: String) throws { self.value = try HeistPathValue(validating: value) }
    public init(stringLiteral value: String) { self.value = HeistPathValue(stringLiteral: value) }
    public init(from decoder: Decoder) throws { value = try HeistPathValue(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }

    package init(definitionPath: HeistDefinitionPath) { value = definitionPath.value }
    package init(first: HeistPlanName, remaining: [HeistPlanName] = []) {
        value = HeistPathValue(first: first, remaining: remaining)
    }
    package init(namePath: [HeistPlanName]) {
        guard let first = namePath.first else {
            preconditionFailure("heist invocation paths require at least one component")
        }
        value = HeistPathValue(first: first, remaining: Array(namePath.dropFirst()))
    }
}

/// A zero-argument Swift function selected as a heist compiler entry point.
public struct HeistEntrySymbol: Sendable, Equatable, Hashable, CustomStringConvertible,
    ExpressibleByStringLiteral {
    private let value: HeistPathValue

    public var description: String { value.description }

    public init(validating value: String) throws { self.value = try HeistPathValue(validating: value) }
    public init(stringLiteral value: String) { self.value = HeistPathValue(stringLiteral: value) }
}

package struct HeistPathValue: Sendable, Equatable, Hashable, CustomStringConvertible, Codable {
    let components: [HeistPlanName]

    init(validating value: String) throws {
        guard !value.isEmpty else { throw HeistPathValidationError.emptyPath }
        let rawComponents = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var components: [HeistPlanName] = []
        components.reserveCapacity(rawComponents.count)
        for (index, component) in rawComponents.enumerated() {
            guard !component.isEmpty else { throw HeistPathValidationError.emptyComponent(index: index) }
            do {
                components.append(try HeistPlanName(validating: component))
            } catch {
                throw HeistPathValidationError.invalidComponent(index: index, component: component)
            }
        }
        self.components = components
    }

    init(stringLiteral value: String) {
        do {
            try self.init(validating: value)
        } catch {
            preconditionFailure(String(describing: error))
        }
    }

    init(first: HeistPlanName, remaining: [HeistPlanName]) {
        components = [first] + remaining
    }

    package var description: String {
        components.map(\.description).joined(separator: ".")
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(validating: container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: String(describing: error))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct HeistInvocationStep: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case path, argument, expectation
    }

    public let path: HeistInvocationPath
    public let argument: HeistArgument
    public let expectation: ActionExpectation?

    public init(
        path: HeistInvocationPath,
        argument: HeistArgument = .none,
        expectation: ActionExpectation? = nil
    ) {
        self.path = path
        self.argument = argument
        self.expectation = expectation
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: CodingKeys.self, typeName: "heist invocation step")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try container.decode(HeistInvocationPath.self, forKey: .path),
            argument: try container.decodeIfPresent(HeistArgument.self, forKey: .argument) ?? .none,
            expectation: try container.decodeIfPresent(ActionExpectation.self, forKey: .expectation)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(argument, forKey: .argument)
        try container.encodeIfPresent(expectation, forKey: .expectation)
    }

    /// Report/display summary of this run as `RunHeist("Name", argument)`.
    /// The frame is the product — reports surface this rather than a bare
    /// `invoke`, so a reader can see which capability ran and with what.
    public var runHeistSummary: String {
        do {
            return try HeistCanonicalSwiftDSLRenderer().render(
                invoke: self,
                indent: 0,
                environment: .preservingReferences
            )
        } catch {
            preconditionFailure("admitted heist invocation must render: \(error)")
        }
    }
}
