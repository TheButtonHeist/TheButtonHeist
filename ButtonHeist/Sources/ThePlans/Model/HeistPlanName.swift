import Foundation

public enum HeistIdentifierValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case empty
    case invalid(String)

    public var description: String {
        switch self {
        case .empty: "identifier must not be empty"
        case .invalid(let value): "identifier must be a Swift-style identifier: \(value)"
        }
    }
}

enum HeistIdentifierGrammar {
    static func admit(_ value: String) throws -> String {
        guard let first = value.unicodeScalars.first else { throw HeistIdentifierValidationError.empty }
        let head = CharacterSet.letters.union(CharacterSet(charactersIn: "_"))
        let body = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard head.contains(first), value.unicodeScalars.allSatisfy(body.contains), !reserved.contains(value) else {
            throw HeistIdentifierValidationError.invalid(value)
        }
        return value
    }

    private static let reserved: Set<String> = [
        "Any", "Self", "as", "associatedtype", "break", "case", "catch", "class", "continue", "default",
        "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for",
        "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "open",
        "operator", "precedencegroup", "private", "protocol", "public", "repeat", "rethrows", "return", "self",
        "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var",
        "where", "while",
    ]
}

/// One local name in a heist definition tree.
///
/// A plan name is an identifier, never a dotted path. Use
/// `HeistDefinitionPath` or `HeistInvocationPath` when qualification matters.
public struct HeistPlanName: Sendable, Equatable, Hashable, ExpressibleByStringLiteral,
    CustomStringConvertible, Codable {
    private let value: String

    public init(validating value: String) throws {
        self.value = try HeistIdentifierGrammar.admit(value)
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
            throw DecodingError.dataCorruptedError(in: container, debugDescription: String(describing: error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
