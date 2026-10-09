import Foundation
import ThePlans

/// One warning emitted by a `Warn(...)` heist step.
public struct HeistExecutionWarning: Codable, Sendable, Equatable {
    public let path: HeistExecutionPath
    public let message: HeistWarningMessage

    public init(
        path: HeistExecutionPath,
        message: HeistWarningMessage
    ) {
        self.path = path
        self.message = message
    }
}

public struct HeistFailureDetail: Codable, Sendable, Equatable {
    public let category: HeistFailureCategory
    public let contract: String
    public let observed: String
    public let expected: String?

    public init(
        category: HeistFailureCategory,
        contract: String,
        observed: String,
        expected: String? = nil
    ) {
        self.category = category
        self.contract = contract
        self.observed = observed
        self.expected = expected
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case category
        case contract
        case observed
        case expected
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: CodingKeys.self, typeName: "heist failure detail")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        category = try container.decode(HeistFailureCategory.self, forKey: .category)
        contract = try container.decode(String.self, forKey: .contract)
        observed = try container.decode(String.self, forKey: .observed)
        expected = try container.decodeIfPresent(String.self, forKey: .expected)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(category, forKey: .category)
        try container.encode(contract, forKey: .contract)
        try container.encode(observed, forKey: .observed)
        try container.encodeIfPresent(expected, forKey: .expected)
    }
}

public enum HeistFailureCategory: String, Codable, Sendable, Equatable {
    case internalInvariant
    case validation
    case runtimeUnavailable
    case targetResolution
    case action
    case expectation
    case wait
    case timeout
    case invocation
    case loop
    case explicitFailure

    public var actionFailureKind: ActionFailure.Kind {
        switch self {
        case .timeout:
            .timeout
        case .runtimeUnavailable:
            .accessibilityTreeUnavailable
        case .targetResolution:
            .elementNotFound
        case .validation:
            .validationError
        case .internalInvariant,
             .action,
             .expectation,
             .wait,
             .invocation,
             .loop,
             .explicitFailure:
            .actionFailed
        }
    }
}
