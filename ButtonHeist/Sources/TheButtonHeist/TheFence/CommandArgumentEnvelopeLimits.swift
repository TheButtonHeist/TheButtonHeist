import Foundation

import TheScore

enum CommandArgumentEnvelopeLimits {

    static func validateHeistPlanSource(
        _ arguments: TheFence.CommandArgumentEnvelope,
        field: String
    ) throws {
        try validate(
            arguments,
            field: field,
            maxBytes: TheFence.DecodeLimits.maxRunHeistRequestBytes,
            maxDepth: TheFence.DecodeLimits.maxRunHeistNestingDepth,
            maxObjectKeys: TheFence.DecodeLimits.maxRunHeistObjectKeys
        )
    }

    static func validate(
        _ arguments: TheFence.CommandArgumentEnvelope,
        field: String,
        maxBytes: Int,
        maxDepth: Int,
        maxObjectKeys: Int
    ) throws {
        try PublicJSONInputDecoder.validate(
            arguments.values,
            maxBytes: maxBytes,
            maxNestingDepth: maxDepth,
            maxTotalObjectKeys: maxObjectKeys,
            mapViolation: { schemaValidationError(field: field, violation: $0) }
        )
    }

    private static func schemaValidationError(
        field: String,
        violation: PublicJSONInputViolation
    ) -> SchemaValidationError {
        switch violation {
        case .bytes(let max, let observed):
            return SchemaValidationError(
                field: field,
                observed: "\(observed) bytes",
                expected: "JSON request <= \(max) bytes"
            )
        case .nestingDepth(let max, let observed):
            return SchemaValidationError(
                field: field,
                observed: "nesting depth \(observed)",
                expected: "nesting depth <= \(max)"
            )
        case .objectKeyCount(let max, let observed):
            return SchemaValidationError(
                field: field,
                observed: "object key count \(observed)",
                expected: "object key count <= \(max)"
            )
        case .nonFiniteNumber(let observed):
            return SchemaValidationError(field: field, observed: observed, expected: "finite JSON number")
        }
    }
}
