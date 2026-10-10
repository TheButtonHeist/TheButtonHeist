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
        _ key: String,
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
        _ key: String,
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
        _ key: String,
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

extension FenceParameter where Value == HeistTimeout {
    internal static func heistTimeout(
        _ key: String,
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
        _ key: String,
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
        _ key: String,
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

private func validateInteger(
    _ integer: Int,
    source: HeistValue,
    field: String,
    minimum: Double?,
    maximum: Double?
) throws {
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
    minimum: Double?,
    maximum: Double?,
    exclusiveMinimum: Double?
) throws {
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
    func validateScalar(_ value: HeistValue, field: String) throws {
        guard case .scalar(
            let kind,
            let enumValues,
            _,
            let minimum,
            let maximum,
            let exclusiveMinimum,
            let minLength
        ) = schema else {
            preconditionFailure("FenceParameter requires a scalar schema")
        }

        switch kind {
        case .string:
            guard case .string(let string) = value else {
                throw SchemaValidationError(field: field, observed: value.schemaObservedDescription, expected: "string")
            }
            if let minLength, string.count < minLength {
                throw SchemaValidationError(
                    field: field,
                    observed: value.schemaObservedDescription,
                    expected: minLength == 1 ? "non-empty string" : "string with length >= \(minLength)"
                )
            }
            if let enumValues, !enumValues.contains(string) {
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
            try validateInteger(
                integer,
                source: value,
                field: field,
                minimum: minimum,
                maximum: maximum
            )
        case .number:
            guard let number = value.numberValue else {
                throw SchemaValidationError(field: field, observed: value.schemaObservedDescription, expected: "number")
            }
            try validateNumber(
                number,
                source: value,
                field: field,
                minimum: minimum,
                maximum: maximum,
                exclusiveMinimum: exclusiveMinimum
            )
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
