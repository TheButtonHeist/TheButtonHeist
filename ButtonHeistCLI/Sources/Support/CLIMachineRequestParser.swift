@_spi(ButtonHeistTooling) import ButtonHeist
import Foundation
import TheScore

enum CLIMachineRequestParser {
    static func parse(_ line: String) throws(DiagnosticFailure) -> FenceCommandInput {
        let arguments: TheFence.CommandArgumentEnvelope
        do {
            let values = try PublicJSONInputDecoder.decodeObject(
                from: line,
                context: "Public JSON request",
                rootMismatchMessage: "Expected JSON object input"
            )
            arguments = TheFence.CommandArgumentEnvelope(values: values, fieldPrefix: nil)
        } catch {
            throw diagnosticFailure(for: error)
        }
        switch TheFence.Command.routeCLICommandEnvelope(arguments, context: "JSON input") {
        case .success(let input):
            return input
        case .failure(let error):
            throw DiagnosticFailure(message: error.message, details: error.details)
        }
    }

    fileprivate static func diagnosticFailure(
        for error: Error,
        details: FailureDetails = FailureDetails(code: .requestInvalid)
    ) -> DiagnosticFailure {
        if let inputError = error as? PublicJSONInputError {
            return DiagnosticFailure(message: inputError.message, details: details)
        }
        let description = String(describing: error)
        let message = description.isEmpty ? error.localizedDescription : description
        return DiagnosticFailure(message: message, details: details)
    }
}
