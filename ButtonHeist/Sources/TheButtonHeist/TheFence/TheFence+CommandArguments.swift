import Foundation
import ThePlans

import TheScore

extension TheFence {

    /// Raw command arguments retained only until command admission.
    @_spi(ButtonHeistTooling) public struct CommandArgumentEnvelope: Sendable {
        let values: [String: HeistValue]
        let argumentFieldPrefix: String?

        @_spi(ButtonHeistTooling) public init(
            values: [String: HeistValue],
            fieldPrefix: String? = nil
        ) {
            self.values = values
            argumentFieldPrefix = fieldPrefix
        }

        @_spi(ButtonHeistTooling) public func value(for key: FenceParameterKey) -> HeistValue? {
            values[key.rawValue]
        }

        func dropping(_ key: FenceParameterKey) -> CommandArgumentEnvelope {
            var copy = values
            copy.removeValue(forKey: key.rawValue)
            return CommandArgumentEnvelope(
                values: copy,
                fieldPrefix: argumentFieldPrefix
            )
        }

        var objectValue: HeistValue {
            .object(values)
        }
    }
}

extension HeistValue {
    var schemaObservedDescription: String {
        switch self {
        case .string(let value):
            return "string \"\(value)\""
        case .int(let value):
            return "integer \(value)"
        case .double(let value):
            return "number \(SchemaValidationError.formatNumber(value))"
        case .bool(let value):
            return "boolean \(value)"
        case .array(let values):
            return "array count \(values.count)"
        case .object:
            return "object"
        }
    }

    var integerValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value) where value.isFinite:
            return Int(exactly: value)
        default:
            return nil
        }
    }

    var numberValue: Double? {
        switch self {
        case .int(let value):
            return Double(value)
        case .double(let value) where value.isFinite:
            return value
        default:
            return nil
        }
    }
}

enum HeistValuePayloadDataCorruptedHandling {
    case schemaValidation
    case invalidRequest
}

extension TheFence {
    /// Serialize typed CLI/MCP values into the raw public JSON boundary currency.
    @_spi(ButtonHeistTooling) public enum HeistValuePayloadEncoder {
        @_spi(ButtonHeistTooling) public static func encode<Value: Encodable>(_ value: Value) throws -> HeistValue {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(HeistValue.self, from: data)
        }
    }

    enum HeistValuePayloadDecoder {
        static func decode<T: Decodable>(
            _ value: HeistValue,
            field rootField: String,
            as type: T.Type,
            includesRootInField: Bool = true,
            dataCorruptedHandling: HeistValuePayloadDataCorruptedHandling = .schemaValidation
        ) throws -> T {
            do {
                let data = try JSONEncoder().encode(value)
                return try JSONDecoder().decode(type, from: data)
            } catch let error as DecodingError {
                throw payloadFailure(
                    error,
                    value: value,
                    rootField: rootField,
                    includesRootInField: includesRootInField,
                    dataCorruptedHandling: dataCorruptedHandling
                )
            } catch {
                throw FenceError.invalidRequest(String(describing: error))
            }
        }

        private static func payloadFailure(
            _ error: DecodingError,
            value: HeistValue,
            rootField: String,
            includesRootInField: Bool,
            dataCorruptedHandling: HeistValuePayloadDataCorruptedHandling
        ) -> Error {
            switch error {
            case .typeMismatch(let expectedType, let context):
                return SchemaValidationError(
                    field: field(rootField, codingPath: context.codingPath, includesRoot: includesRootInField),
                    observed: payloadValue(at: context.codingPath, in: value)?.schemaObservedDescription
                        ?? value.schemaObservedDescription,
                    expected: expectedDescription(for: expectedType, fallback: context.debugDescription)
                )
            case .valueNotFound(_, let context):
                return SchemaValidationError(
                    field: field(rootField, codingPath: context.codingPath, includesRoot: includesRootInField),
                    observed: "missing",
                    expected: context.debugDescription
                )
            case .keyNotFound(let key, let context):
                return SchemaValidationError(
                    field: field(
                        rootField,
                        codingPath: context.codingPath + [key],
                        includesRoot: includesRootInField
                    ),
                    observed: "missing",
                    expected: "present"
                )
            case .dataCorrupted(let context):
                switch dataCorruptedHandling {
                case .schemaValidation:
                    return SchemaValidationError(
                        field: field(rootField, codingPath: context.codingPath, includesRoot: includesRootInField),
                        observed: payloadValue(at: context.codingPath, in: value)?.schemaObservedDescription
                            ?? "invalid value",
                        expected: context.debugDescription
                    )
                case .invalidRequest:
                    return FenceError.invalidRequest(context.debugDescription)
                }
            @unknown default:
                return FenceError.invalidRequest(String(describing: error))
            }
        }

        private static func field(
            _ rootField: String,
            codingPath: [CodingKey],
            includesRoot: Bool
        ) -> String {
            let suffix = codingPathString(codingPath)
            guard !suffix.isEmpty else { return rootField }
            guard includesRoot else { return suffix }
            if suffix.hasPrefix("[") {
                return "\(rootField)\(suffix)"
            }
            return "\(rootField).\(suffix)"
        }

        private static func codingPathString(_ codingPath: [CodingKey]) -> String {
            codingPath.reduce(into: "") { path, codingKey in
                if let index = codingKey.intValue {
                    path += "[\(index)]"
                } else if path.isEmpty {
                    path = codingKey.stringValue
                } else {
                    path += ".\(codingKey.stringValue)"
                }
            }
        }

        private static func payloadValue(at codingPath: [CodingKey], in value: HeistValue) -> HeistValue? {
            codingPath.reduce(Optional(value)) { current, key in
                guard let current else { return nil }
                if let index = key.intValue {
                    guard case .array(let values) = current, values.indices.contains(index) else { return nil }
                    return values[index]
                }
                guard case .object(let values) = current else { return nil }
                return values[key.stringValue]
            }
        }

        private static func expectedDescription(for type: Any.Type, fallback: String) -> String {
            switch type {
            case is String.Type:
                return "string"
            case is Bool.Type:
                return "boolean"
            case is Int.Type:
                return "integer"
            case is Double.Type, is Float.Type:
                return "number"
            default:
                return fallback
            }
        }
    }
}

/// Strict typed accessors for command arguments after command routing.
/// This keeps raw dictionaries at public decode edges while preserving the
/// field-qualified diagnostics expected by the current command contract.
extension TheFence.CommandArgumentEnvelope {
    var keys: Dictionary<String, HeistValue>.Keys {
        values.keys
    }

    func value<Value>(_ parameter: FenceParameter<Value>) throws -> Value? {
        guard let value = value(for: parameter.key) else { return nil }
        return try parameter.decode(value, field: field(parameter.key))
    }

    func requiredValue<Value>(_ parameter: FenceParameter<Value>) throws -> Value {
        guard let value = try value(parameter) else {
            throw SchemaValidationError(
                field: field(parameter.key),
                observed: "missing",
                expected: parameter.expectedTypeDescription
            )
        }
        return value
    }

    func value<Value>(
        _ parameter: FenceParameter<Value>,
        defaultFrom descriptor: FenceCommandDescriptor
    ) throws -> Value {
        try value(parameter) ?? descriptor.requiredDefaultValue(for: parameter)
    }

    func observedDescription(for key: FenceParameterKey) -> String? {
        values[key.rawValue]?.schemaObservedDescription
    }

    func observedDescription(forUnknownKey key: String) -> String? {
        values[key]?.schemaObservedDescription
    }

    var observedDescription: String {
        "object"
    }

    func field(_ key: FenceParameterKey) -> String {
        field(forRawKey: key.rawValue)
    }

    func field(forUnknownKey key: String) -> String {
        field(forRawKey: key)
    }

    private func field(forRawKey key: String) -> String {
        guard let argumentFieldPrefix else { return key }
        return "\(argumentFieldPrefix).\(key)"
    }

}
