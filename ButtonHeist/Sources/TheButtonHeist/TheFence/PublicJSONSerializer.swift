import Foundation

enum PublicJSONSerializer {
    static let encodingFailureMessage =
        "Failed to encode JSON response: response contained non-JSON values"

    static func render<T: Encodable>(
        encoding response: T,
        outputFormatting: JSONEncoder.OutputFormatting,
        encodingFailure: DiagnosticFailure
    ) throws -> PublicJSONRendering {
        do {
            return .rendered(try encode(response, outputFormatting: outputFormatting))
        } catch {
            return .fallback(
                try encode(
                    PublicErrorResponse(failure: encodingFailure),
                    outputFormatting: outputFormatting
                ),
                encodingFailure
            )
        }
    }

    static func render<T: Encodable>(
        encoding response: T,
        requestId: PublicRequestId?,
        outputFormatting: JSONEncoder.OutputFormatting,
        encodingFailure: DiagnosticFailure
    ) throws -> PublicJSONRendering {
        guard let requestId else {
            return try render(
                encoding: response,
                outputFormatting: outputFormatting,
                encodingFailure: encodingFailure
            )
        }
        let envelope = PublicResponseEnvelope(requestId: requestId, response: response)
        let failureEnvelope = PublicResponseEnvelope(
            requestId: requestId,
            response: PublicErrorResponse(failure: encodingFailure)
        )
        do {
            return .rendered(try encode(envelope, outputFormatting: outputFormatting))
        } catch {
            return .fallback(
                try encode(failureEnvelope, outputFormatting: outputFormatting),
                encodingFailure
            )
        }
    }

    private static func encode<T: Encodable>(
        _ response: T,
        outputFormatting: JSONEncoder.OutputFormatting
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = outputFormatting
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(response)
    }
}

private struct PublicResponseEnvelope<Response: Encodable>: Encodable {
    let requestId: PublicRequestId
    let response: Response

    private enum CodingKeys: String, CodingKey {
        case requestId = "id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try response.encode(to: encoder)
    }
}

public enum PublicRequestId: Codable, Equatable, Sendable {
    case string(String)
    case signedInteger(Int64)
    case unsignedInteger(UInt64)
    case double(Double)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }

        if (try? container.decode(Bool.self)) != nil {
            throw Self.invalidDecodedValue(
                decoder: decoder,
                debugDescription: "Public JSON request id does not support bool"
            )
        }
        if let value = try? container.decode(Int64.self) {
            self = .signedInteger(value)
            return
        }
        if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw Self.invalidDecodedValue(
                    decoder: decoder,
                    debugDescription: "Public JSON request id must be finite"
                )
            }
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }

        throw Self.invalidDecodedValue(
            decoder: decoder,
            debugDescription: "Public JSON request id must be string, integer, unsigned integer, finite decimal, or null"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .signedInteger(let value):
            try container.encode(value)
        case .unsignedInteger(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    private static func invalidDecodedValue(
        decoder: Decoder,
        debugDescription: String
    ) -> DecodingError {
        DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: debugDescription
            )
        )
    }
}
