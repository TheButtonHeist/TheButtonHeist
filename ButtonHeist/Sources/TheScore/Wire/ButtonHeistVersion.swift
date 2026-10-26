import Foundation

/// A validated Button Heist product version carried by the wire protocol.
public struct ButtonHeistVersion: Codable, Sendable, Equatable, Hashable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public enum ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
        case invalid(String)

        public var description: String {
            "Button Heist version must be a MAJOR.MINOR.PATCH semantic version, optionally followed by a 12-character lowercase contract hash"
        }
    }

    private let value: String

    public init(validating value: String) throws {
        guard Self.isValidSemanticVersion(value) else {
            throw ValidationError.invalid(value)
        }
        self.value = value
    }

    public init(stringLiteral value: String) {
        do {
            try self.init(validating: value)
        } catch {
            preconditionFailure(String(describing: error))
        }
    }

    public var description: String {
        value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(validating: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private static func isValidSemanticVersion(_ value: String) -> Bool {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 1 || components.count == 2 else { return false }
        if components.count == 2 {
            let hash = components[1].utf8
            guard hash.count == 12,
                  hash.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                return false
            }
        }
        let identifiers = components[0].split(separator: ".", omittingEmptySubsequences: false)
        return identifiers.count == 3 && identifiers.allSatisfy { identifier in
            isNumeric(identifier) && (identifier == "0" || identifier.first != "0")
        }
    }

    private static func isNumeric(_ value: Substring) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }
}
