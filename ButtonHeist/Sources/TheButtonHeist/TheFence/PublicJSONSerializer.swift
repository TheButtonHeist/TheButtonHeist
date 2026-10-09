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
