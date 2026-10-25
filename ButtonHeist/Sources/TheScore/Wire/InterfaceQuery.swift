import ThePlans
import Foundation

private enum InterfaceQueryCodingKeys: String, CodingKey, CaseIterable {
    case subtree
    case mode
    case maxScrollsPerContainer
    case maxScrollsPerDiscovery
}

public struct InterfaceDiscoveryLimit: Codable, Sendable, Equatable, CustomStringConvertible {
    public static let allowedRange = 1...2_000

    public let value: Int

    public init(validating value: Int) throws {
        guard Self.allowedRange.contains(value) else {
            throw InvalidInterfaceDiscoveryLimitError()
        }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        self = try decodeSingleValue(from: decoder, admitting: Self.init(validating:))
    }

    public func encode(to encoder: Encoder) throws {
        try encodeSingleValue(value, to: encoder)
    }

    public var description: String { value.description }
}

private struct InvalidInterfaceDiscoveryLimitError: Error, CustomStringConvertible {
    var description: String {
        "interface discovery limit must be between "
            + "\(InterfaceDiscoveryLimit.allowedRange.lowerBound) and "
            + "\(InterfaceDiscoveryLimit.allowedRange.upperBound)"
    }
}

extension InterfaceDiscoveryLimit: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = requireValidLiteralPayload { try Self(validating: value) }
    }
}

/// An interface read with either current-view capture or bounded discovery.
public struct InterfaceQuery: Sendable, Equatable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case current
        case discovery
    }

    public enum Capture: Sendable, Equatable {
        case current
        case discovery(
            maxScrollsPerContainer: InterfaceDiscoveryLimit? = nil,
            maxScrollsPerDiscovery: InterfaceDiscoveryLimit? = nil
        )
    }

    public let subtree: AccessibilityTarget?
    public let capture: Capture

    public var mode: Mode {
        switch capture {
        case .current: .current
        case .discovery: .discovery
        }
    }

    public var maxScrollsPerContainer: InterfaceDiscoveryLimit? {
        guard case .discovery(let limit, _) = capture else { return nil }
        return limit
    }

    public var maxScrollsPerDiscovery: InterfaceDiscoveryLimit? {
        guard case .discovery(_, let limit) = capture else { return nil }
        return limit
    }

    public init(
        subtree: AccessibilityTarget? = nil,
        maxScrollsPerContainer: InterfaceDiscoveryLimit? = nil,
        maxScrollsPerDiscovery: InterfaceDiscoveryLimit? = nil
    ) {
        self.init(capture: .discovery(
            maxScrollsPerContainer: maxScrollsPerContainer,
            maxScrollsPerDiscovery: maxScrollsPerDiscovery
        ), subtree: subtree)
    }

    public init(capture: Capture, subtree: AccessibilityTarget? = nil) {
        self.subtree = subtree
        self.capture = capture
    }
}

extension InterfaceQuery: Codable {
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: InterfaceQueryCodingKeys.self, typeName: "interface query")
        let container = try decoder.container(keyedBy: InterfaceQueryCodingKeys.self)
        let subtree = try container.decodeIfPresent(AccessibilityTarget.self, forKey: .subtree)
        let mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .discovery
        let perContainer = try container.decodeIfPresent(InterfaceDiscoveryLimit.self, forKey: .maxScrollsPerContainer)
        let perDiscovery = try container.decodeIfPresent(InterfaceDiscoveryLimit.self, forKey: .maxScrollsPerDiscovery)
        switch mode {
        case .current:
            guard perContainer == nil, perDiscovery == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mode, in: container,
                    debugDescription: "current interface capture does not accept discovery limits"
                )
            }
            self.init(capture: .current, subtree: subtree)
        case .discovery:
            self.init(subtree: subtree, maxScrollsPerContainer: perContainer, maxScrollsPerDiscovery: perDiscovery)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: InterfaceQueryCodingKeys.self)
        try container.encodeIfPresent(subtree, forKey: .subtree)
        if mode == .current { try container.encode(mode, forKey: .mode) }
        try container.encodeIfPresent(maxScrollsPerContainer, forKey: .maxScrollsPerContainer)
        try container.encodeIfPresent(maxScrollsPerDiscovery, forKey: .maxScrollsPerDiscovery)
    }
}

extension InterfaceQuery: CustomStringConvertible {
    public var description: String {
        CanonicalValueDescription.call("interfaceQuery", [
            subtree?.description,
            mode == .current ? "mode=current" : nil,
            maxScrollsPerContainer.map { "maxScrollsPerContainer=\($0)" },
            maxScrollsPerDiscovery.map { "maxScrollsPerDiscovery=\($0)" },
        ].compactMap { $0 })
    }
}
