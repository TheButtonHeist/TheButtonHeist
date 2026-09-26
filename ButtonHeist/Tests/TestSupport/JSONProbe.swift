import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: JSONCodingKey.self) {
            var values: [String: JSONValue] = [:]
            for key in object.allKeys {
                values[key.stringValue] = try object.decode(JSONValue.self, forKey: key)
            }
            self = .object(values)
            return
        }

        if var array = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !array.isAtEnd {
                values.append(try array.decode(JSONValue.self))
            }
            self = .array(values)
            return
        }

        let scalar = try decoder.singleValueContainer()
        if scalar.decodeNil() {
            self = .null
        } else if let value = try? scalar.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? scalar.decode(Int.self) {
            self = .int(value)
        } else if let value = try? scalar.decode(Double.self) {
            self = .double(value)
        } else if let value = try? scalar.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: scalar,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let object):
            var container = encoder.container(keyedBy: JSONCodingKey.self)
            for (key, value) in object {
                try container.encode(value, forKey: JSONCodingKey(stringValue: key))
            }
        case .array(let array):
            var container = encoder.unkeyedContainer()
            for value in array {
                try container.encode(value)
            }
        case .string(let string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .int(let int):
            var container = encoder.singleValueContainer()
            try container.encode(int)
        case .double(let double):
            var container = encoder.singleValueContainer()
            try container.encode(double)
        case .bool(let bool):
            var container = encoder.singleValueContainer()
            try container.encode(bool)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    var typeDescription: String {
        switch self {
        case .object: return "object"
        case .array: return "array"
        case .string: return "string"
        case .int: return "int"
        case .double: return "double"
        case .bool: return "bool"
        case .null: return "null"
        }
    }
}

public struct JSONProbe: Sendable {
    private let value: JSONValue
    private let path: String

    public init(_ value: JSONValue, path: String = "$") {
        self.value = value
        self.path = path
    }

    public init(data: Data, decoder: JSONDecoder = JSONDecoder()) throws {
        do {
            self.init(try decoder.decode(JSONValue.self, from: data))
        } catch {
            throw JSONProbeFailure(path: "$", reason: "Failed to decode JSON: \(error)")
        }
    }

    public func object(_ key: String? = nil) throws -> JSONProbe {
        let probe = try key.map(child) ?? self
        guard case .object = probe.value else {
            throw probe.typeMismatch(expected: "object")
        }
        return probe
    }

    public func array(_ key: String? = nil) throws -> [JSONProbe] {
        let probe = try key.map(child) ?? self
        guard case .array(let values) = probe.value else {
            throw probe.typeMismatch(expected: "array")
        }
        return values.enumerated().map { index, value in
            JSONProbe(value, path: "\(probe.path)[\(index)]")
        }
    }

    public func string(_ key: String? = nil) throws -> String {
        let probe = try key.map(child) ?? self
        guard case .string(let value) = probe.value else {
            throw probe.typeMismatch(expected: "string")
        }
        return value
    }

    public func strings(_ key: String? = nil) throws -> [String] {
        try array(key).map { try $0.string() }
    }

    public func bool(_ key: String? = nil) throws -> Bool {
        let probe = try key.map(child) ?? self
        guard case .bool(let value) = probe.value else {
            throw probe.typeMismatch(expected: "bool")
        }
        return value
    }

    public func int(_ key: String? = nil) throws -> Int {
        let probe = try key.map(child) ?? self
        guard case .int(let value) = probe.value else {
            throw probe.typeMismatch(expected: "int")
        }
        return value
    }

    public func double(_ key: String? = nil) throws -> Double {
        let probe = try key.map(child) ?? self
        switch probe.value {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        default:
            throw probe.typeMismatch(expected: "double")
        }
    }

    public func assertPresent(_ key: String) throws {
        guard case .object(let object) = value else {
            throw typeMismatch(expected: "object")
        }
        guard object[key] != nil else {
            throw JSONProbeFailure(path: childPath(for: key), reason: "Expected value to be present")
        }
    }

    public func assertMissing(_ key: String) throws {
        guard case .object(let object) = value else {
            throw typeMismatch(expected: "object")
        }
        guard object[key] == nil else {
            throw JSONProbeFailure(path: childPath(for: key), reason: "Expected value to be absent")
        }
    }

    public func assertRecursivelyMissingKeys(_ keys: [String]) throws {
        let disallowed = Set(keys)
        guard let hit = Self.firstPath(containingKeyIn: disallowed, value: value, path: path) else { return }
        throw JSONProbeFailure(path: hit.path, reason: "Expected key '\(hit.key)' to be absent recursively")
    }

    public func decode<T: Decodable>(
        _ type: T.Type = T.self,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        do {
            let data = try JSONEncoder().encode(value)
            return try decoder.decode(type, from: data)
        } catch {
            throw JSONProbeFailure(path: path, reason: "Failed to decode \(type): \(error)")
        }
    }

    private func child(_ key: String) throws -> JSONProbe {
        guard case .object(let object) = value else {
            throw typeMismatch(expected: "object")
        }
        guard let value = object[key] else {
            throw JSONProbeFailure(path: childPath(for: key), reason: "Missing JSON value")
        }
        return JSONProbe(value, path: childPath(for: key))
    }

    private func childPath(for key: String) -> String {
        path + Self.pathComponent(forKey: key)
    }

    private func typeMismatch(expected: String) -> JSONProbeFailure {
        JSONProbeFailure(
            path: path,
            reason: "Expected \(expected), got \(value.typeDescription)"
        )
    }

    private static func pathComponent(forKey key: String) -> String {
        guard isIdentifier(key) else {
            let escaped = key
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "[\"\(escaped)\"]"
        }
        return ".\(key)"
    }

    private static func isIdentifier(_ key: String) -> Bool {
        guard let first = key.first, first == "_" || first.isLetter else {
            return false
        }
        return key.dropFirst().allSatisfy { character in
            character == "_" || character.isLetter || character.isNumber
        }
    }

    private static func firstPath(
        containingKeyIn disallowed: Set<String>,
        value: JSONValue,
        path: String
    ) -> (key: String, path: String)? {
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                let childPath = path + pathComponent(forKey: key)
                if disallowed.contains(key) {
                    return (key, childPath)
                }
                if let child = object[key],
                   let hit = firstPath(containingKeyIn: disallowed, value: child, path: childPath) {
                    return hit
                }
            }
            return nil

        case .array(let array):
            for (index, value) in array.enumerated() {
                if let hit = firstPath(containingKeyIn: disallowed, value: value, path: "\(path)[\(index)]") {
                    return hit
                }
            }
            return nil

        case .string, .int, .double, .bool, .null:
            return nil
        }
    }
}

public struct JSONProbeFailure: Error, CustomStringConvertible, LocalizedError, Equatable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    public var description: String {
        "\(reason) at \(path)"
    }

    public var errorDescription: String? {
        description
    }
}

private struct JSONCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

package func testJSONObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
    let encoded = try JSONEncoder().encode(value)
    guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        throw JSONProbeFailure(path: "$", reason: "Expected encoded object")
    }
    return object
}

package func mutatedTestJSONData<Value: Encodable>(
    _ value: Value,
    mutation: (inout [String: Any]) throws -> Void
) throws -> Data {
    var object = try testJSONObject(value)
    try mutation(&object)
    return try JSONSerialization.data(withJSONObject: object)
}
