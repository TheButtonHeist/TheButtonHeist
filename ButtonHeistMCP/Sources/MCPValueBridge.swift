import Foundation
import MCP
@_spi(ButtonHeistInternals) @_spi(ButtonHeistTooling) import ButtonHeist
import TheScore

enum MCPValueBridge {
    enum StructuredContent {
        case rendered(Value)
        case fallback(Value, DiagnosticFailure)

        var value: Value {
            switch self {
            case .rendered(let value), .fallback(let value, _): value
            }
        }

        var failure: DiagnosticFailure? {
            guard case .fallback(_, let failure) = self else { return nil }
            return failure
        }
    }

    static func commandEnvelope(from arguments: [String: Value]?) throws -> TheFence.CommandArgumentEnvelope {
        let values = try (arguments ?? [:]).mapValues(heistValue)
        try PublicJSONInputDecoder.validate(values, context: "MCP arguments")
        return TheFence.CommandArgumentEnvelope(values: values)
    }

    static func value(from heistValue: HeistValue) -> Value {
        switch heistValue {
        case .string(let value):
            return .string(value)
        case .int(let value):
            return .int(value)
        case .double(let value):
            return .double(value)
        case .bool(let value):
            return .bool(value)
        case .array(let values):
            return .array(values.map { self.value(from: $0) })
        case .object(let values):
            return .object(values.mapValues { self.value(from: $0) })
        }
    }

    private static func heistValue(from value: Value) throws -> HeistValue {
        switch value {
        case .null:
            throw PublicJSONInputError("MCP arguments contains null")
        case .bool(let bool):
            return .bool(bool)
        case .int(let int):
            return .int(int)
        case .double(let double):
            guard double.isFinite else {
                throw PublicJSONInputError("MCP arguments contains a non-finite number")
            }
            return .double(double)
        case .string(let string):
            return .string(string)
        case .data:
            throw PublicJSONInputError("MCP arguments contains binary data")
        case .array(let values):
            return .array(try values.map(heistValue))
        case .object(let object):
            return .object(try object.mapValues(heistValue))
        }
    }

    static func structuredContent(
        for response: FenceResponse
    ) throws -> StructuredContent {
        let rendering = try response.jsonRendering(profile: .mcp, outputFormatting: [])
        let value = try JSONDecoder().decode(Value.self, from: rendering.data)
        return rendering.failure.map { .fallback(value, $0) } ?? .rendered(value)
    }

}
