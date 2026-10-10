import ArgumentParser
import Foundation
@_spi(ButtonHeistTooling) import ButtonHeist
import TheScore

struct GetScreenCommand: OneShotCLICommand {
    static let fenceCommand = TheFence.Command.getScreen
    static let configuration = CommandConfiguration(
        commandName: Self.cliCommandName,
        abstract: "Capture a screenshot from the connected device"
    )

    @OptionGroup var destination: ScreenDestinationInput

    @OptionGroup var connection: ConnectionOptions

    var runnerConnection: ConnectionOptions { connection }
    var runnerFormat: OutputFormat? { .human }
    var runnerStatusMessage: String? { "Requesting screenshot..." }

    @ButtonHeistActor
    func runnerDescriptor() async throws -> CLIRunner.CommandDescriptor {
        let arguments: TheFence.CommandArgumentEnvelope = try requestArguments()
        let output: CLIRunner.CommandOutputProjection?
        if destination.inline {
            output = { _, response in
                try Self.inlineCommandOutput(for: response)
            }
        } else {
            output = nil
        }
        return CLIRunner.CommandDescriptor(
            fenceDescriptor: Self.fenceDescriptor,
            connection: connection,
            format: .human,
            arguments: arguments,
            statusMessage: runnerStatusMessage,
            output: output
        )
    }

    func requestArguments() throws -> TheFence.CommandArgumentEnvelope {
        CommandArgumentFields(try destination.argumentFields().map(Optional.some)).envelope
    }

    static func inlineCommandOutput(for response: FenceResponse) throws -> CLIRunner.CommandOutput {
        guard case .screenshotData(let payload, _) = response else {
            return .response(response)
        }
        guard let data = Data(base64Encoded: payload.pngData) else {
            throw ValidationError("Failed to decode screenshot data")
        }
        return .binary(data)
    }
}

struct ScreenDestinationInput: ParsableArguments {
    @Option(name: .shortAndLong, help: "Output file path (default: generated artifact path)")
    var output: String?

    @Flag(name: .long, help: "Write raw PNG bytes to stdout")
    var inline = false

    @Flag(name: .long, help: "Render accessibility markers and legend instead of the raw screenshot")
    var accessibility = false

    mutating func validate() throws {
        _ = try argumentFields()
    }

    func argumentFields() throws -> [CommandArgumentFields.Field] {
        switch (inline, output) {
        case (true, nil):
            return [
                CommandArgumentFields.value("inlineData", true),
                CommandArgumentFields.optional(
                    "mode",
                    accessibility ? ScreenCaptureMode.accessibility.rawValue : nil
                ),
            ].compactMap { $0 }
        case (false, let output):
            return [
                CommandArgumentFields.optional("output", output),
                CommandArgumentFields.optional(
                    "mode",
                    accessibility ? ScreenCaptureMode.accessibility.rawValue : nil
                ),
            ].compactMap { $0 }
        case (true, .some):
            throw ValidationError("--inline cannot be used with --output")
        }
    }
}
