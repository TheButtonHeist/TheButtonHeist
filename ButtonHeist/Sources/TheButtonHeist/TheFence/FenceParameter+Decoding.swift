import Foundation
import ThePlans
import TheScore

extension TheFence {
    internal enum DecodeLimits {
        internal static let maxRunHeistRequestBytes = PublicJSONInputLimits.maxRequestBytes
        internal static let maxRunHeistNestingDepth = PublicJSONInputLimits.maxNestingDepth
        internal static let maxRunHeistObjectKeys = PublicJSONInputLimits.maxTotalObjectKeys
        internal static let maxInlineScreenshotBase64Bytes = 1_000_000
    }
}

extension FenceParameter where Value == String {
    internal static func string(
        _ key: FenceParameterKey,
        required: Bool = false,
        defaultValue: String? = nil,
        minLength: Int? = nil
    ) -> Self {
        let spec = param(
            key,
            .string,
            required: required,
            defaultValue: defaultValue.map(HeistValue.string),
            minLength: minLength
        )
        return FenceParameter(
            key: key,
            spec: spec,
            defaultValue: defaultValue,
            convertValue: {
                guard case .string(let value) = $0 else { return nil }
                return value
            },
            encodeValue: { .string($0) }
        )
    }
}

extension FenceParameter where Value == Int {
    internal static func integer(
        _ key: FenceParameterKey,
        required: Bool = false,
        defaultValue: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> Self {
        let spec = param(
            key,
            .integer,
            required: required,
            defaultValue: defaultValue.map(HeistValue.int),
            minimum: minimum,
            maximum: maximum
        )
        return FenceParameter(
            key: key,
            spec: spec,
            defaultValue: defaultValue,
            convertValue: { $0.integerValue },
            encodeValue: { .int($0) }
        )
    }
}

extension FenceParameter where Value == Double {
    internal static func number(
        _ key: FenceParameterKey,
        required: Bool = false,
        defaultValue: Double? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        exclusiveMinimum: Double? = nil
    ) -> Self {
        let spec = param(
            key,
            .number,
            required: required,
            defaultValue: defaultValue.map(jsonSchemaNumber),
            minimum: minimum,
            maximum: maximum,
            exclusiveMinimum: exclusiveMinimum
        )
        return FenceParameter(
            key: key,
            spec: spec,
            defaultValue: defaultValue,
            convertValue: { $0.numberValue },
            encodeValue: { jsonSchemaNumber($0) }
        )
    }
}

extension FenceParameter where Value == GestureDuration {
    internal static func gestureDuration(_ key: FenceParameterKey) -> Self {
        let spec = param(
            key,
            .number,
            maximum: GestureDuration.maximumSeconds,
            exclusiveMinimum: 0
        )
        return FenceParameter(
            key: key,
            spec: spec,
            convertValue: { value in
                guard let seconds = value.numberValue else { return nil }
                return try GestureDuration(validatingSeconds: seconds)
            },
            encodeValue: { jsonSchemaNumber($0.seconds) }
        )
    }
}

extension FenceParameter where Value == HeistTimeout {
    internal static func heistTimeout(
        _ key: FenceParameterKey,
        defaultValue: HeistTimeout
    ) -> Self {
        let spec = param(
            key,
            .number,
            defaultValue: jsonSchemaNumber(defaultValue.seconds),
            exclusiveMinimum: 0
        )
        return FenceParameter(
            key: key,
            spec: spec,
            defaultValue: defaultValue,
            convertValue: { value in
                guard let seconds = value.numberValue else { return nil }
                return try HeistTimeout(validatingSeconds: seconds)
            },
            encodeValue: { jsonSchemaNumber($0.seconds) }
        )
    }
}

extension FenceParameter where Value == Bool {
    internal static func boolean(
        _ key: FenceParameterKey,
        required: Bool = false,
        defaultValue: Bool? = nil
    ) -> Self {
        let spec = param(
            key,
            .boolean,
            required: required,
            defaultValue: defaultValue.map(HeistValue.bool)
        )
        return FenceParameter(
            key: key,
            spec: spec,
            defaultValue: defaultValue,
            convertValue: {
                guard case .bool(let value) = $0 else { return nil }
                return value
            },
            encodeValue: { .bool($0) }
        )
    }
}

extension FenceParameter where Value: CaseIterable & RawRepresentable, Value.RawValue == String {
    internal static func enumValue(
        _ key: FenceParameterKey,
        required: Bool = false,
        defaultValue: Value? = nil
    ) -> Self {
        let rawValues = Value.allCases.map(\.rawValue)
        let spec = param(
            key,
            .string,
            required: required,
            enumValues: rawValues,
            defaultValue: defaultValue.map { .string($0.rawValue) }
        )
        return FenceParameter(
            key: key,
            spec: spec,
            defaultValue: defaultValue,
            convertValue: {
                guard case .string(let rawValue) = $0 else { return nil }
                return Value(rawValue: rawValue)
            },
            encodeValue: { .string($0.rawValue) }
        )
    }
}

internal func fenceEnumValues<E>(_ type: E.Type) -> [String]
where E: CaseIterable & RawRepresentable, E.RawValue == String {
    type.allCases.map(\.rawValue)
}

private func validateInteger(
    _ integer: Int,
    source: HeistValue,
    field: String,
    constraints: FenceParameterScalarConstraints
) throws {
    let minimum = constraints.minimum
    let maximum = constraints.maximum
    if let minimum, Double(integer) < minimum {
        throw SchemaValidationError(
            field: field,
            observed: source.schemaObservedDescription,
            expected: numericBoundsDescription(type: "integer", minimum: minimum, maximum: maximum)
        )
    }
    if let maximum, Double(integer) > maximum {
        throw SchemaValidationError(
            field: field,
            observed: source.schemaObservedDescription,
            expected: numericBoundsDescription(type: "integer", minimum: minimum, maximum: maximum)
        )
    }
}

private func validateNumber(
    _ number: Double,
    source: HeistValue,
    field: String,
    constraints: FenceParameterScalarConstraints
) throws {
    let minimum = constraints.minimum
    let maximum = constraints.maximum
    let exclusiveMinimum = constraints.exclusiveMinimum
    if let exclusiveMinimum, number <= exclusiveMinimum {
        throw SchemaValidationError(
            field: field,
            observed: source.schemaObservedDescription,
            expected: "number > \(formatConstraintNumber(exclusiveMinimum))"
        )
    }
    if let minimum, number < minimum {
        throw SchemaValidationError(
            field: field,
            observed: source.schemaObservedDescription,
            expected: numberBoundsDescription(minimum: minimum, maximum: maximum)
        )
    }
    if let maximum, number > maximum {
        let expected = if let exclusiveMinimum {
            "number in \(formatConstraintNumber(exclusiveMinimum))...\(formatNumberUpperBound(maximum))"
        } else if let minimum {
            numberBoundsDescription(minimum: minimum, maximum: maximum)
        } else {
            "number <= \(formatConstraintNumber(maximum))"
        }
        throw SchemaValidationError(field: field, observed: source.schemaObservedDescription, expected: expected)
    }
}

private func numberBoundsDescription(minimum: Double, maximum: Double?) -> String {
    guard let maximum else { return "number >= \(formatConstraintNumber(minimum))" }
    return "number in \(formatConstraintNumber(minimum))...\(formatConstraintNumber(maximum))"
}

internal extension FenceParameterSpec {
    func validatePayload(_ value: HeistValue, field: String) throws {
        guard !usesCustomPayloadValidation else { return }
        try validate(value, against: schema, field: field)
    }

    private func validate(
        _ value: HeistValue,
        against schema: FenceParameterSchema,
        field: String
    ) throws {
        switch schema {
        case .unconstrained:
            return
        case .scalar:
            try validateScalar(value, field: field)
        case .object(let object):
            guard case .object(let values) = value else {
                throw SchemaValidationError(
                    field: field,
                    observed: value.schemaObservedDescription,
                    expected: "object"
                )
            }
            guard let properties = object.properties else { return }
            if object.additionalProperties == false,
               let unknown = values.keys.sorted().first(where: { key in
                   !properties.contains(where: { $0.key == key })
               }) {
                throw SchemaValidationError(
                    field: "\(field).\(unknown)",
                    observed: values[unknown]?.schemaObservedDescription ?? "missing",
                    expected: "valid \(field) field"
                )
            }
            for property in properties {
                let childField = "\(field).\(property.key)"
                guard let child = values[property.key] else {
                    guard property.required else { continue }
                    throw SchemaValidationError(
                        field: childField,
                        observed: "missing",
                        expected: property.expectedTypeDescription
                    )
                }
                try property.validatePayload(child, field: childField)
            }
        case .array(let array):
            guard case .array(let values) = value else {
                throw SchemaValidationError(
                    field: field,
                    observed: value.schemaObservedDescription,
                    expected: array.kind == .stringArray ? "array of strings" : "array"
                )
            }
            if let minimum = array.constraints.minItems, values.count < minimum {
                throw SchemaValidationError(
                    field: field,
                    observed: value.schemaObservedDescription,
                    expected: "array with count >= \(minimum)"
                )
            }
            if let maximum = array.constraints.maxItems, values.count > maximum {
                throw SchemaValidationError(
                    field: field,
                    observed: value.schemaObservedDescription,
                    expected: "array with count <= \(maximum)"
                )
            }
            if let itemSchema = array.items {
                for (index, item) in values.enumerated() {
                    try validate(item, against: itemSchema, field: "\(field)[\(index)]")
                }
            }
        }
    }

    func validateScalar(_ value: HeistValue, field: String) throws {
        guard case .scalar(let scalar) = schema else {
            preconditionFailure("FenceParameter requires a scalar schema")
        }

        switch scalar.kind {
        case .string:
            guard case .string(let string) = value else {
                throw SchemaValidationError(field: field, observed: value.schemaObservedDescription, expected: "string")
            }
            if let minLength = scalar.constraints.minLength, string.count < minLength {
                throw SchemaValidationError(
                    field: field,
                    observed: value.schemaObservedDescription,
                    expected: minLength == 1 ? "non-empty string" : "string with length >= \(minLength)"
                )
            }
            if let enumValues = scalar.constraints.enumValues, !enumValues.contains(string) {
                throw SchemaValidationError(
                    field: field,
                    observed: value.schemaObservedDescription,
                    expected: SchemaValidationError.expectedEnumValues(enumValues)
                )
            }
        case .integer:
            guard let integer = value.integerValue else {
                throw SchemaValidationError(field: field, observed: value.schemaObservedDescription, expected: "integer")
            }
            try validateInteger(integer, source: value, field: field, constraints: scalar.constraints)
        case .number:
            guard let number = value.numberValue else {
                throw SchemaValidationError(field: field, observed: value.schemaObservedDescription, expected: "number")
            }
            try validateNumber(number, source: value, field: field, constraints: scalar.constraints)
        case .boolean:
            guard case .bool = value else {
                throw SchemaValidationError(field: field, observed: value.schemaObservedDescription, expected: "boolean")
            }
        case .stringMatch:
            preconditionFailure("StringMatch schemas are decoded as payloads, not FenceParameter scalars")
        }
    }
}

private func numericBoundsDescription(type: String, minimum: Double?, maximum: Double?) -> String {
    switch (minimum, maximum) {
    case (.some(let minimum), .some(let maximum)):
        return "\(type) between \(formatConstraintNumber(minimum)) and \(formatConstraintNumber(maximum))"
    case (.some(let minimum), nil):
        return "\(type) >= \(formatConstraintNumber(minimum))"
    case (nil, .some(let maximum)):
        return "\(type) <= \(formatConstraintNumber(maximum))"
    case (nil, nil):
        return type
    }
}

private func formatNumberUpperBound(_ value: Double) -> String {
    value != 0 && value.rounded(.towardZero) == value ? String(format: "%.1f", value) : formatConstraintNumber(value)
}

private func formatConstraintNumber(_ value: Double) -> String {
    value.rounded(.towardZero) == value ? String(format: "%.0f", value) : String(value)
}
