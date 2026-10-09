import Foundation

import TheScore

@_spi(ButtonHeistInternals) public enum PublicJSONRendering: Sendable {
    case rendered(Data)
    case fallback(Data, DiagnosticFailure)

    public var data: Data {
        switch self {
        case .rendered(let data), .fallback(let data, _): data
        }
    }

    public var failure: DiagnosticFailure? {
        guard case .fallback(_, let failure) = self else { return nil }
        return failure
    }
}

extension FenceResponse {

    // MARK: - JSON Encoding

    @_spi(ButtonHeistTooling) public func jsonData(
        outputFormatting: JSONEncoder.OutputFormatting = [.sortedKeys]
    ) throws -> Data {
        try jsonData(profile: .summary, outputFormatting: outputFormatting)
    }

    @_spi(ButtonHeistTooling) public func jsonData(
        profile: ProjectionProfile,
        outputFormatting: JSONEncoder.OutputFormatting = [.sortedKeys]
    ) throws -> Data {
        try jsonRendering(profile: profile, outputFormatting: outputFormatting).data
    }

    @_spi(ButtonHeistInternals) public func jsonRendering(
        profile: ProjectionProfile,
        outputFormatting: JSONEncoder.OutputFormatting = [.sortedKeys]
    ) throws -> PublicJSONRendering {
        try PublicJSONSerializer.render(
            encoding: PublicResponseModel(response: self, profile: profile),
            outputFormatting: outputFormatting,
            encodingFailure: Self.jsonEncodingFailure()
        )
    }

    static func jsonEncodingFailure() -> DiagnosticFailure {
        DiagnosticFailure(
            message: PublicJSONSerializer.encodingFailureMessage,
            details: FailureDetails(code: .formattingJSONEncodingFailed)
        )
    }
}
