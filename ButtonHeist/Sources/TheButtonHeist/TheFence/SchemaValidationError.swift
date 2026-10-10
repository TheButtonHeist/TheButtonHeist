import Foundation

public struct SchemaValidationError: Error, LocalizedError, Equatable, Sendable {
    public let field: String
    public let observed: String
    public let expected: String

    public init(field: String, observed: String, expected: String) {
        self.field = field
        self.observed = observed
        self.expected = expected
    }

    public init(field: String, observed: Int, expected: String) {
        self.init(field: field, observed: "integer \(observed)", expected: expected)
    }

    public init(field: String, observed: Double, expected: String) {
        self.init(field: field, observed: "number \(Self.formatNumber(observed))", expected: expected)
    }

    public var message: String {
        "schema validation failed for \(field): observed \(observed); expected \(expected)"
    }

    public var errorDescription: String? { message }

    public static func expectedEnumValues(_ values: [String]) -> String {
        "enum one of \(values.joined(separator: ", "))"
    }

    static func formatNumber(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(format: "%.1f", value)
        }
        return String(value)
    }
}
