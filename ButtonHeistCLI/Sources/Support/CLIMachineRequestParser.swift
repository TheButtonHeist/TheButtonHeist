@_spi(ButtonHeistTooling) import ButtonHeist
import Foundation
import TheScore

struct CLIParsedRequest {
    let input: FenceCommandInput

    var command: TheFence.Command {
        input.command
    }
}

struct CLIMachineRequestError: Error, CustomStringConvertible {
    let diagnosticFailure: DiagnosticFailure

    init(diagnosticFailure: DiagnosticFailure) {
        self.diagnosticFailure = diagnosticFailure
    }

    var message: String { diagnosticFailure.message }
    var description: String { diagnosticFailure.message }
}

enum CLIMachineRequestParser {
    static func parsedRequest(from line: String) throws -> CLIParsedRequest {
        let arguments: TheFence.CommandArgumentEnvelope
        do {
            let values = try PublicJSONInputDecoder.decodeObject(
                from: line,
                context: "Public JSON request",
                rootMismatchMessage: "Expected JSON object input"
            )
            arguments = TheFence.CommandArgumentEnvelope(values: values, fieldPrefix: nil)
        } catch let error as CLIMachineRequestError {
            throw error
        } catch {
            throw CLIMachineRequestError(
                diagnosticFailure: diagnosticFailure(for: error)
            )
        }
        switch TheFence.Command.routeCLICommandEnvelope(arguments, context: "JSON input") {
        case .success(let input):
            return CLIParsedRequest(input: input)
        case .failure(let error):
            throw CLIMachineRequestError(
                diagnosticFailure: DiagnosticFailure(message: error.message, details: error.details)
            )
        }
    }

    fileprivate static func diagnosticFailure(
        for error: Error,
        details: FailureDetails = FailureDetails(code: .requestInvalid)
    ) -> DiagnosticFailure {
        if let requestError = error as? CLIMachineRequestError {
            return requestError.diagnosticFailure
        }
        if let inputError = error as? PublicJSONInputError {
            return DiagnosticFailure(message: inputError.message, details: details)
        }
        let description = String(describing: error)
        let message = description.isEmpty ? error.localizedDescription : description
        return DiagnosticFailure(message: message, details: details)
    }
}
