import Foundation
import TheScore

/// Resource limits for recursive public machine inputs.
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

/// Admits one canonical object while enforcing the public JSON limits.
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
        let mapViolation: @Sendable (PublicJSONInputViolation) -> Error = {
            PublicJSONInputError($0.message(context: context))
        }
        try validateByteCount(data.count, maxBytes: maxBytes, mapViolation: mapViolation)
        guard data.first(where: { !Self.whitespace.contains($0) }) == UInt8(ascii: "{") else {
            throw PublicJSONInputError(rootMismatchMessage ?? "\(context) is not valid JSON")
        }
        try PublicJSONNestingPreflight.validate(
            data,
            maxNestingDepth: maxNestingDepth,
            mapViolation: mapViolation
        )

        let object: [String: HeistValue]
        do {
            object = try JSONDecoder().decode([String: HeistValue].self, from: data)
        } catch {
            throw PublicJSONInputError("\(context) is not valid JSON")
        }
        try validateStructure(
            object,
            maxNestingDepth: maxNestingDepth,
            maxTotalObjectKeys: maxTotalObjectKeys,
            mapViolation: mapViolation
        )
        return object
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
        try validateByteCount(data.count, maxBytes: maxBytes, mapViolation: mapViolation)
        try validateStructure(
            object,
            maxNestingDepth: maxNestingDepth,
            maxTotalObjectKeys: maxTotalObjectKeys,
            mapViolation: mapViolation
        )
    }

    private static func validateStructure(
        _ object: [String: HeistValue],
        maxNestingDepth: Int,
        maxTotalObjectKeys: Int,
        mapViolation: @escaping @Sendable (PublicJSONInputViolation) -> Error
    ) throws {
        var traversal = PublicJSONStructureTraversal(
            maxNestingDepth: maxNestingDepth,
            maxTotalObjectKeys: maxTotalObjectKeys,
            mapViolation: mapViolation
        )
        try traversal.validate(object)
    }

    private static func validateByteCount(
        _ byteCount: Int,
        maxBytes: Int,
        mapViolation: @Sendable (PublicJSONInputViolation) -> Error
    ) throws {
        guard byteCount <= maxBytes else {
            throw mapViolation(.bytes(max: maxBytes, observed: byteCount))
        }
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

/// Bounds recursive decoder work without constructing a second JSON tree.
private enum PublicJSONNestingPreflight {
    static func validate(
        _ data: Data,
        maxNestingDepth: Int,
        mapViolation: @Sendable (PublicJSONInputViolation) -> Error
    ) throws {
        var depth = 0
        var isInString = false
        var isEscaped = false

        for byte in data {
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if byte == UInt8(ascii: "\\") {
                    isEscaped = true
                } else if byte == UInt8(ascii: "\"") {
                    isInString = false
                }
                continue
            }

            switch byte {
            case UInt8(ascii: "\""):
                isInString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                guard depth <= maxNestingDepth else {
                    throw mapViolation(.nestingDepth(max: maxNestingDepth, observed: depth))
                }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default:
                break
            }
        }
    }
}

private struct PublicJSONStructureTraversal {
    let maxNestingDepth: Int
    let maxTotalObjectKeys: Int
    let mapViolation: @Sendable (PublicJSONInputViolation) -> Error
    var totalObjectKeys = 0

    mutating func validate(_ object: [String: HeistValue]) throws {
        try validateObject(object, depth: 1)
    }

    private mutating func validate(_ value: HeistValue, depth: Int) throws {
        guard depth <= maxNestingDepth else {
            throw mapViolation(.nestingDepth(max: maxNestingDepth, observed: depth))
        }

        switch value {
        case .array(let values):
            for nested in values {
                try validate(nested, depth: depth + 1)
            }
        case .object(let object):
            try validateObject(object, depth: depth)
        case .string, .int, .double, .bool:
            break
        }
    }

    private mutating func validateObject(
        _ object: [String: HeistValue],
        depth: Int
    ) throws {
        guard depth <= maxNestingDepth else {
            throw mapViolation(.nestingDepth(max: maxNestingDepth, observed: depth))
        }
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
