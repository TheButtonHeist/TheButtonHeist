import TheScore

@_spi(ButtonHeistTooling) public struct FenceParameterSpec: Sendable, Equatable {
    public enum ParamType: String, Sendable, Equatable {
        case string
        case integer
        case number
        case boolean
        case stringArray
        case stringMatch
        case object
        case array
    }

    public let key: String
    internal let schema: JSONSchema
    public let required: Bool

    internal init(key: String, schema: JSONSchema, required: Bool) {
        self.key = key
        self.schema = schema
        self.required = required
    }

    public var type: ParamType { schema.type }
    public var enumValues: [String]? { schema.enumValues }
    public var defaultValue: HeistValue? { schema.defaultValue }
    internal var minimum: Double? { schema.minimum }
    internal var maximum: Double? { schema.maximum }
    internal var exclusiveMinimum: Double? { schema.exclusiveMinimum }
    internal var minLength: Int? { schema.minLength }
    internal var minItems: Int? { schema.minItems }
    internal var maxItems: Int? { schema.maxItems }

    public var objectProperties: [FenceParameterSpec] {
        schema.objectProperties ?? []
    }

    public var arrayItemProperties: [FenceParameterSpec] {
        schema.arrayItemProperties ?? []
    }
}

/// The JSON Schema subset emitted by public Button Heist command contracts.
internal indirect enum JSONSchema: Sendable, Equatable {
    enum Scalar: Sendable, Equatable {
        case string
        case integer
        case number
        case boolean
        case stringMatch(modeValues: [String], description: String)
    }

    case unconstrained
    case scalar(
        Scalar,
        enumValues: [String]? = nil,
        defaultValue: HeistValue? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        exclusiveMinimum: Double? = nil,
        minLength: Int? = nil
    )
    case object(properties: [FenceParameterSpec]? = nil, additionalProperties: Bool? = nil)
    case array(
        items: JSONSchema? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        stringsOnly: Bool = false
    )
    case reference(String)

    var type: FenceParameterSpec.ParamType {
        switch self {
        case .unconstrained, .object, .reference:
            return .object
        case .scalar(let kind, _, _, _, _, _, _):
            switch kind {
            case .string: return .string
            case .integer: return .integer
            case .number: return .number
            case .boolean: return .boolean
            case .stringMatch: return .stringMatch
            }
        case .array(_, _, _, let stringsOnly):
            return stringsOnly ? .stringArray : .array
        }
    }

    var enumValues: [String]? {
        guard case .scalar(_, let values, _, _, _, _, _) = self else { return nil }
        return values
    }

    var defaultValue: HeistValue? {
        guard case .scalar(_, _, let value, _, _, _, _) = self else { return nil }
        return value
    }

    var minimum: Double? {
        guard case .scalar(_, _, _, let value, _, _, _) = self else { return nil }
        return value
    }

    var maximum: Double? {
        guard case .scalar(_, _, _, _, let value, _, _) = self else { return nil }
        return value
    }

    var exclusiveMinimum: Double? {
        guard case .scalar(_, _, _, _, _, let value, _) = self else { return nil }
        return value
    }

    var minLength: Int? {
        guard case .scalar(_, _, _, _, _, _, let value) = self else { return nil }
        return value
    }

    var minItems: Int? {
        guard case .array(_, let value, _, _) = self else { return nil }
        return value
    }

    var maxItems: Int? {
        guard case .array(_, _, let value, _) = self else { return nil }
        return value
    }

    var objectProperties: [FenceParameterSpec]? {
        guard case .object(let properties, _) = self else { return nil }
        return properties
    }

    var arrayItemProperties: [FenceParameterSpec]? {
        guard case .array(let items, _, _, _) = self,
              case .object(let properties, _)? = items else {
            return nil
        }
        return properties
    }

    var containsReference: Bool {
        switch self {
        case .reference:
            return true
        case .object(let properties, _):
            return properties?.contains(where: { $0.schema.containsReference }) == true
        case .array(let items, _, _, _):
            return items?.containsReference == true
        case .unconstrained, .scalar:
            return false
        }
    }

    var heistValue: HeistValue {
        switch self {
        case .unconstrained:
            return .object([:])
        case .reference(let reference):
            return .object(["$ref": .string(reference)])
        case .scalar(let kind, let enumValues, let defaultValue, let minimum, let maximum,
                     let exclusiveMinimum, let minLength):
            if case .stringMatch(let modeValues, let description) = kind {
                return .object([
                    "type": .string("object"),
                    "properties": .object([
                        "mode": JSONSchema.scalar(.string, enumValues: modeValues).heistValue,
                        "value": JSONSchema.scalar(.string).heistValue,
                    ]),
                    "required": .array([.string("mode")]),
                    "additionalProperties": .bool(false),
                    "description": .string(description),
                ])
            }
            var fields = ["type": HeistValue.string(kind.jsonSchemaType)]
            if let enumValues { fields["enum"] = .array(enumValues.map(HeistValue.string)) }
            if let defaultValue { fields["default"] = defaultValue }
            if let minimum { fields["minimum"] = jsonSchemaNumber(minimum) }
            if let maximum { fields["maximum"] = jsonSchemaNumber(maximum) }
            if let exclusiveMinimum { fields["exclusiveMinimum"] = jsonSchemaNumber(exclusiveMinimum) }
            if let minLength { fields["minLength"] = .int(minLength) }
            return .object(fields)
        case .object(let properties, let additionalProperties):
            var fields = ["type": HeistValue.string("object")]
            if let properties {
                fields["properties"] = .object(Dictionary(
                    uniqueKeysWithValues: properties.map { ($0.key, $0.schema.heistValue) }
                ))
                let required = properties.filter(\.required).map(\.key)
                if !required.isEmpty {
                    fields["required"] = .array(required.map(HeistValue.string))
                }
            }
            if let additionalProperties { fields["additionalProperties"] = .bool(additionalProperties) }
            return .object(fields)
        case .array(let items, let minItems, let maxItems, let stringsOnly):
            var fields = ["type": HeistValue.string("array")]
            if let items {
                fields["items"] = items.heistValue
            } else if stringsOnly {
                fields["items"] = JSONSchema.scalar(.string).heistValue
            }
            if let minItems { fields["minItems"] = .int(minItems) }
            if let maxItems { fields["maxItems"] = .int(maxItems) }
            return .object(fields)
        }
    }
}

private extension JSONSchema.Scalar {
    var jsonSchemaType: String {
        switch self {
        case .string: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .stringMatch: return "object"
        }
    }
}

internal func jsonSchemaNumber(_ value: Double) -> HeistValue {
    value.rounded(.towardZero) == value ? .int(Int(value)) : .double(value)
}

internal extension FenceParameterSpec {
    var expectedTypeDescription: String {
        if let enumValues {
            return SchemaValidationError.expectedEnumValues(enumValues)
        }
        return type.expectedDescription
    }
}

private extension FenceParameterSpec.ParamType {
    var expectedDescription: String {
        switch self {
        case .string: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .stringArray: return "array of strings"
        case .stringMatch: return "StringMatch object with mode and optional value"
        case .object: return "object"
        case .array: return "array"
        }
    }
}

@_spi(ButtonHeistTooling) public extension FenceParameterSpec.ParamType {
    var jsonSchemaType: String {
        switch self {
        case .stringArray: return "array"
        case .stringMatch: return "object"
        default: return rawValue
        }
    }
}

@_spi(ButtonHeistTooling) public extension FenceCommandDescriptor {
    var inputJSONSchema: HeistValue {
        FenceParameterSpec.jsonInputSchema(parameters: parameters)
    }
}

@_spi(ButtonHeistTooling) public extension FenceParameterSpec {
    func parameters(named key: String) -> [FenceParameterSpec] {
        let childMatches = objectProperties.flatMap { $0.parameters(named: key) }
            + arrayItemProperties.flatMap { $0.parameters(named: key) }
        return self.key == key ? [self] + childMatches : childMatches
    }

    var objectPropertyKeys: Set<String> {
        Set(objectProperties.map(\.key))
    }

    static func jsonInputSchema(parameters: [FenceParameterSpec]) -> HeistValue {
        let schema = JSONSchema.object(properties: parameters, additionalProperties: false)
        guard schema.containsReference,
              case .object(var fields) = schema.heistValue else {
            return schema.heistValue
        }
        fields["$defs"] = .object([
            AccessibilityTargetSchemaDefinition.name: AccessibilityTargetSchemaDefinition.schema,
        ])
        return .object(fields)
    }
}

internal enum AccessibilityTargetSchemaDefinition {
    static let name = "AccessibilityTarget"
    static let reference = "#/$defs/\(name)"
    static let schema = JSONSchema.object(
        properties: accessibilityTargetProperties(),
        additionalProperties: false
    ).heistValue
}
