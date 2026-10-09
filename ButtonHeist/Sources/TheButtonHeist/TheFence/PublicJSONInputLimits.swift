import Foundation
import TheScore

/// Limits for public machine inputs before they materialize recursive JSON.
@_spi(ButtonHeistTooling) public enum PublicJSONInputLimits {
    public static let maxRequestBytes = 1_000_000
    public static let maxNestingDepth = 32
    public static let maxTotalObjectKeys = 1_024
}

@_spi(ButtonHeistTooling) public struct PublicJSONInputError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

enum PublicJSONInputViolation: Sendable, Equatable {
    case bytes(max: Int, observed: Int)
    case nestingDepth(max: Int, observed: Int)
    case objectKeyCount(max: Int, observed: Int)
    case nonFiniteNumber(Double)

    func message(context: String) -> String {
        switch self {
        case .bytes(let max, let observed):
            return "\(context) exceeds \(max) bytes (observed \(observed) bytes)"
        case .nestingDepth(let max, let observed):
            return "\(context) nesting depth exceeds \(max) (observed \(observed))"
        case .objectKeyCount(let max, let observed):
            return "\(context) object key count exceeds \(max) (observed \(observed))"
        case .nonFiniteNumber:
            return "\(context) contains a non-finite number"
        }
    }
}

/// Applies public JSON limits, then decodes the canonical object boundary.
@_spi(ButtonHeistTooling) public enum PublicJSONInputDecoder {
    public static func decodeObject(
        from input: String,
        context: String = "Public JSON input",
        rootMismatchMessage: String? = nil
    ) throws -> [String: HeistValue] {
        try decodeObject(
            from: Data(input.utf8),
            context: context,
            rootMismatchMessage: rootMismatchMessage
        )
    }

    public static func validate(
        _ object: [String: HeistValue],
        context: String = "Public JSON input"
    ) throws {
        try validate(
            object,
            maxBytes: PublicJSONInputLimits.maxRequestBytes,
            maxNestingDepth: PublicJSONInputLimits.maxNestingDepth,
            maxTotalObjectKeys: PublicJSONInputLimits.maxTotalObjectKeys,
            mapViolation: { PublicJSONInputError($0.message(context: context)) }
        )
    }

    static func decodeObject(
        from data: Data,
        context: String,
        maxBytes: Int = PublicJSONInputLimits.maxRequestBytes,
        maxNestingDepth: Int = PublicJSONInputLimits.maxNestingDepth,
        maxTotalObjectKeys: Int = PublicJSONInputLimits.maxTotalObjectKeys,
        rootMismatchMessage: String? = nil
    ) throws -> [String: HeistValue] {
        try validate(
            data,
            context: context,
            maxBytes: maxBytes,
            maxNestingDepth: maxNestingDepth,
            maxTotalObjectKeys: maxTotalObjectKeys,
            rootMismatchMessage: rootMismatchMessage,
            mapViolation: { PublicJSONInputError($0.message(context: context)) }
        )
        return try JSONDecoder().decode([String: HeistValue].self, from: data)
    }

    static func validate(
        _ object: [String: HeistValue],
        maxBytes: Int,
        maxNestingDepth: Int,
        maxTotalObjectKeys: Int,
        mapViolation: @escaping @Sendable (PublicJSONInputViolation) -> Error
    ) throws {
        if let number = object.values.lazy.compactMap(firstNonFiniteNumber).first {
            throw mapViolation(.nonFiniteNumber(number))
        }
        let data = try JSONEncoder().encode(object)
        try validate(
            data,
            context: "Public JSON input",
            maxBytes: maxBytes,
            maxNestingDepth: maxNestingDepth,
            maxTotalObjectKeys: maxTotalObjectKeys,
            rootMismatchMessage: nil,
            mapViolation: mapViolation
        )
    }

    private static func validate(
        _ data: Data,
        context: String,
        maxBytes: Int,
        maxNestingDepth: Int,
        maxTotalObjectKeys: Int,
        rootMismatchMessage: String?,
        mapViolation: @escaping @Sendable (PublicJSONInputViolation) -> Error
    ) throws {
        guard data.count <= maxBytes else {
            throw mapViolation(.bytes(max: maxBytes, observed: data.count))
        }
        if data.first(where: { !Self.whitespace.contains($0) }) != UInt8(ascii: "{") {
            throw PublicJSONInputError(rootMismatchMessage ?? "\(context) is not valid JSON")
        }

        var traversal = FoundationJSONStructureTraversal(
            maxNestingDepth: maxNestingDepth,
            maxTotalObjectKeys: maxTotalObjectKeys,
            mapViolation: mapViolation
        )
        try traversal.validate(data, context: context)
    }

    private static func firstNonFiniteNumber(in value: HeistValue) -> Double? {
        switch value {
        case .double(let number) where !number.isFinite:
            return number
        case .array(let values):
            return values.lazy.compactMap(firstNonFiniteNumber).first
        case .object(let values):
            return values.values.lazy.compactMap(firstNonFiniteNumber).first
        case .string, .int, .double, .bool:
            return nil
        }
    }

    private static let whitespace: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09]
}

/// The only untyped Foundation JSON boundary. Values do not escape this traversal.
private struct FoundationJSONStructureTraversal {
    let maxNestingDepth: Int
    let maxTotalObjectKeys: Int
    let mapViolation: @Sendable (PublicJSONInputViolation) -> Error
    var totalObjectKeys = 0

    mutating func validate(_ data: Data, context: String) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw PublicJSONInputError("\(context) is not valid JSON")
        }
        try validate(value, depth: 1)
    }

    private mutating func validate(_ value: Any, depth: Int) throws {
        guard depth <= maxNestingDepth else {
            throw mapViolation(.nestingDepth(max: maxNestingDepth, observed: depth))
        }

        if let array = value as? [Any] {
            for nested in array {
                try validate(nested, depth: depth + 1)
            }
        } else if let object = value as? [String: Any] {
            totalObjectKeys += object.count
            guard totalObjectKeys <= maxTotalObjectKeys else {
                throw mapViolation(.objectKeyCount(
                    max: maxTotalObjectKeys,
                    observed: totalObjectKeys
                ))
            }
            for nested in object.values {
                try validate(nested, depth: depth + 1)
            }
        }
    }
}
