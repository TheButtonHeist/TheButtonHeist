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
    internal let schema: FenceParameterSchema
    public let required: Bool
    internal let validation: FenceParameterValidation
    internal let schemaProjection: FenceParameterSchemaProjection

    internal init(
        key: String,
        schema: FenceParameterSchema,
        required: Bool,
        validation: FenceParameterValidation = .schema,
        schemaProjection: FenceParameterSchemaProjection = .inline
    ) {
        self.key = key
        self.schema = schema
        self.required = required
        self.validation = validation
        self.schemaProjection = schemaProjection
    }

    public var type: ParamType {
        schema.type
    }

    public var enumValues: [String]? {
        guard case .scalar(let scalar) = schema else { return nil }
        return scalar.constraints.enumValues
    }

    public var defaultValue: HeistValue? {
        guard case .scalar(let scalar) = schema else { return nil }
        return scalar.constraints.defaultValue
    }

    internal var minimum: Double? {
        guard case .scalar(let scalar) = schema else { return nil }
        return scalar.constraints.minimum
    }

    internal var maximum: Double? {
        guard case .scalar(let scalar) = schema else { return nil }
        return scalar.constraints.maximum
    }

    internal var exclusiveMinimum: Double? {
        guard case .scalar(let scalar) = schema else { return nil }
        return scalar.constraints.exclusiveMinimum
    }

    internal var minLength: Int? {
        guard case .scalar(let scalar) = schema else { return nil }
        return scalar.constraints.minLength
    }

    internal var minItems: Int? {
        guard case .array(let array) = schema else { return nil }
        return array.constraints.minItems
    }

    internal var maxItems: Int? {
        guard case .array(let array) = schema else { return nil }
        return array.constraints.maxItems
    }

    public var objectProperties: [FenceParameterSpec] {
        guard case .object(let object) = schema,
              let properties = object.properties else {
            return []
        }
        return properties
    }

    public var arrayItemProperties: [FenceParameterSpec] {
        guard case .array(let array) = schema,
              case .object(let object)? = array.items,
              let properties = object.properties else {
            return []
        }
        return properties
    }

}

internal enum FenceParameterSchemaProjection: Sendable, Equatable {
    case inline
    case accessibilityTargetReference
}

internal enum FenceParameterValidation: Sendable, Equatable {
    case schema
    case customPayload
}

internal indirect enum FenceParameterSchema: Sendable, Equatable {
    case unconstrained
    case scalar(FenceParameterScalarSpec)
    case object(FenceParameterObjectSpec)
    case array(FenceParameterArraySpec)

    internal var type: FenceParameterSpec.ParamType {
        switch self {
        case .unconstrained:
            return .object
        case .scalar(let scalar):
            return scalar.kind.type
        case .object:
            return .object
        case .array(let array):
            return array.kind.type
        }
    }

    internal var heistValue: HeistValue {
        .object(heistValueProperties)
    }

    private var heistValueProperties: [String: HeistValue] {
        switch self {
        case .unconstrained:
            return [:]
        case .scalar(let scalar):
            return scalar.heistValueProperties
        case .object(let object):
            return object.heistValueProperties
        case .array(let array):
            return array.heistValueProperties
        }
    }

    internal static func scalar(
        _ kind: FenceParameterScalarKind,
        constraints: FenceParameterScalarConstraints = .empty
    ) -> Self {
        .scalar(FenceParameterScalarSpec(kind: kind, constraints: constraints))
    }

    internal static func object(
        properties: [FenceParameterSpec]? = nil,
        additionalProperties: Bool? = nil
    ) -> Self {
        .object(FenceParameterObjectSpec(
            properties: properties,
            additionalProperties: additionalProperties
        ))
    }

    internal static func array(
        kind: FenceParameterArrayKind = .array,
        items: FenceParameterSchema? = nil,
        constraints: FenceParameterArrayConstraints = .empty
    ) -> Self {
        .array(FenceParameterArraySpec(kind: kind, items: items, constraints: constraints))
    }
}

internal enum FenceParameterScalarKind: Sendable, Equatable {
    case string
    case integer
    case number
    case boolean
    case stringMatch(modeValues: [String], description: String)

    internal var type: FenceParameterSpec.ParamType {
        switch self {
        case .string:
            return .string
        case .integer:
            return .integer
        case .number:
            return .number
        case .boolean:
            return .boolean
        case .stringMatch:
            return .stringMatch
        }
    }
}

internal struct FenceParameterScalarSpec: Sendable, Equatable {
    internal let kind: FenceParameterScalarKind
    internal let constraints: FenceParameterScalarConstraints

    internal var heistValueProperties: [String: HeistValue] {
        switch kind {
        case .string, .integer, .number, .boolean:
            var properties = ["type": HeistValue.string(kind.type.jsonSchemaType)]
            constraints.add(to: &properties)
            return properties
        case .stringMatch(let modeValues, let description):
            return [
                "type": .string(FenceParameterSpec.ParamType.object.jsonSchemaType),
                "properties": .object([
                    FenceParameterKey.mode.rawValue: FenceParameterSchema
                        .scalar(.string, constraints: FenceParameterScalarConstraints(enumValues: modeValues))
                        .heistValue,
                    FenceParameterKey.value.rawValue: FenceParameterSchema.scalar(.string).heistValue,
                ]),
                "required": .array([
                    .string(FenceParameterKey.mode.rawValue),
                ]),
                "additionalProperties": .bool(false),
                "description": .string(description),
            ]
        }
    }
}

internal struct FenceParameterObjectSpec: Sendable, Equatable {
    internal let properties: [FenceParameterSpec]?
    internal let additionalProperties: Bool?

    internal var heistValueProperties: [String: HeistValue] {
        var fields = ["type": HeistValue.string(FenceParameterSpec.ParamType.object.jsonSchemaType)]
        if let properties {
            fields["properties"] = .object(Self.heistValueProperties(from: properties))
            let required = properties.filter(\.required).map(\.key)
            if !required.isEmpty {
                fields["required"] = .array(required.map { .string($0) })
            }
        }
        if let additionalProperties {
            fields["additionalProperties"] = .bool(additionalProperties)
        }
        return fields
    }

    private static func heistValueProperties(from properties: [FenceParameterSpec]) -> [String: HeistValue] {
        var projectedProperties: [String: HeistValue] = [:]
        for property in properties where projectedProperties[property.key] == nil {
            projectedProperties[property.key] = property.projectedSchemaHeistValue
        }
        return projectedProperties
    }
}

internal struct FenceParameterArraySpec: Sendable, Equatable {
    internal let kind: FenceParameterArrayKind
    internal let items: FenceParameterSchema?
    internal let constraints: FenceParameterArrayConstraints

    internal var heistValueProperties: [String: HeistValue] {
        var fields = ["type": HeistValue.string(FenceParameterSpec.ParamType.array.jsonSchemaType)]
        constraints.add(to: &fields)
        if let items {
            fields["items"] = items.heistValue
        }
        return fields
    }
}

internal enum FenceParameterArrayKind: Sendable, Equatable {
    case array
    case stringArray

    internal var type: FenceParameterSpec.ParamType {
        switch self {
        case .array:
            return .array
        case .stringArray:
            return .stringArray
        }
    }
}

internal struct FenceParameterScalarConstraints: Sendable, Equatable {
    internal static let empty = Self()

    internal let enumValues: [String]?
    internal let defaultValue: HeistValue?
    internal let minimum: Double?
    internal let maximum: Double?
    internal let exclusiveMinimum: Double?
    internal let minLength: Int?

    internal init(
        enumValues: [String]? = nil,
        defaultValue: HeistValue? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        exclusiveMinimum: Double? = nil,
        minLength: Int? = nil
    ) {
        self.enumValues = enumValues
        self.defaultValue = defaultValue
        self.minimum = minimum
        self.maximum = maximum
        self.exclusiveMinimum = exclusiveMinimum
        self.minLength = minLength
    }

}

internal struct FenceParameterArrayConstraints: Sendable, Equatable {
    internal static let empty = Self()

    internal let minItems: Int?
    internal let maxItems: Int?

    internal init(
        minItems: Int? = nil,
        maxItems: Int? = nil
    ) {
        self.minItems = minItems
        self.maxItems = maxItems
    }
}

private extension FenceParameterScalarConstraints {
    func add(to properties: inout [String: HeistValue]) {
        if let enumValues { properties["enum"] = .array(enumValues.map { .string($0) }) }
        if let defaultValue { properties["default"] = defaultValue }
        if let minimum { properties["minimum"] = jsonSchemaNumber(minimum) }
        if let maximum { properties["maximum"] = jsonSchemaNumber(maximum) }
        if let exclusiveMinimum { properties["exclusiveMinimum"] = jsonSchemaNumber(exclusiveMinimum) }
        if let minLength { properties["minLength"] = .int(minLength) }
    }
}

private extension FenceParameterArrayConstraints {
    func add(to properties: inout [String: HeistValue]) {
        if let minItems { properties["minItems"] = .int(minItems) }
        if let maxItems { properties["maxItems"] = .int(maxItems) }
    }
}

internal func jsonSchemaNumber(_ value: Double) -> HeistValue {
    value.rounded(.towardZero) == value ? .int(Int(value)) : .double(value)
}

internal extension FenceParameterSpec {
    var usesCustomPayloadValidation: Bool {
        validation == .customPayload
    }

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
        case .string:
            return "string"
        case .integer:
            return "integer"
        case .number:
            return "number"
        case .boolean:
            return "boolean"
        case .stringArray:
            return "array of strings"
        case .stringMatch:
            return "StringMatch object with mode and optional value"
        case .object:
            return "object"
        case .array:
            return "array"
        }
    }
}

@_spi(ButtonHeistTooling) public extension FenceParameterSpec.ParamType {
    var jsonSchemaType: String {
        switch self {
        case .stringArray:
            return "array"
        case .stringMatch:
            return "object"
        default:
            return rawValue
        }
    }
}

@_spi(ButtonHeistTooling) public extension FenceCommandDescriptor {
    var inputJSONSchema: HeistValue {
        FenceParameterSpec.jsonInputSchema(
            parameters: parameters.elements
        )
    }
}

@_spi(ButtonHeistTooling) public extension FenceParameterSpec {
    func parameters(named key: FenceParameterKey) -> [FenceParameterSpec] {
        let childMatches = objectProperties.flatMap { $0.parameters(named: key) }
            + arrayItemProperties.flatMap { $0.parameters(named: key) }
        guard self.key == key.rawValue else { return childMatches }
        return [self] + childMatches
    }

    var objectPropertyKeys: Set<String> {
        Set(objectProperties.map(\.key))
    }

    static func jsonInputSchema(
        parameters: [FenceParameterSpec]
    ) -> HeistValue {
        var root = FenceParameterSchema.object(
            properties: parameters,
            additionalProperties: false
        ).heistValue
        guard parameters.contains(where: \.containsAccessibilityTargetReference),
              case .object(var fields) = root else {
            return root
        }
        fields["$defs"] = .object([
            AccessibilityTargetSchemaDefinition.name: AccessibilityTargetSchemaDefinition.schema,
        ])
        root = .object(fields)
        return root
    }
}

private extension FenceParameterSpec {
    var projectedSchemaHeistValue: HeistValue {
        switch schemaProjection {
        case .inline:
            return schema.heistValue
        case .accessibilityTargetReference:
            return .object(["$ref": .string(AccessibilityTargetSchemaDefinition.reference)])
        }
    }

    var containsAccessibilityTargetReference: Bool {
        if schemaProjection == .accessibilityTargetReference { return true }
        return objectProperties.contains(where: \.containsAccessibilityTargetReference)
            || arrayItemProperties.contains(where: \.containsAccessibilityTargetReference)
    }
}

private enum AccessibilityTargetSchemaDefinition {
    static let name = "AccessibilityTarget"
    static let reference = "#/$defs/\(name)"
    static let schema = FenceParameterSchema.object(
        properties: accessibilityTargetProperties(),
        additionalProperties: false
    ).heistValue
}
