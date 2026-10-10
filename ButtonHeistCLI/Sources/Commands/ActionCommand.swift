import ArgumentParser
@_spi(ButtonHeistTooling) import ButtonHeist
import TheScore

struct ActionCommand: ConnectedOneShotCLICommand {
    static let fenceCommand = TheFence.Command.action
    static let configuration = CommandConfiguration(
        commandName: Self.cliCommandName,
        abstract: "Execute one canonical HeistActionCommand JSON object"
    )

    @Argument(help: "Canonical HeistActionCommand JSON with type and optional payload.")
    var action: String

    @Option(help: "Optional AccessibilityPredicate JSON evaluated after durable actions.")
    var expect: String?

    @Option(help: "Optional expectation timeout in seconds.")
    var timeout: Double?

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: OutputOptions

    func requestArguments() throws -> TheFence.CommandArgumentEnvelope {
        var fields = CommandArgumentFields(
            CommandArgumentFields.value("action", try decodeObject(action, context: "action")),
            CommandArgumentFields.optional("timeout", timeout)
        )
        if let expect {
            fields.insert(CommandArgumentFields.value("expect", try decodeObject(expect, context: "expect")))
        }
        return fields.envelope
    }

    private func decodeObject(_ source: String, context: String) throws -> HeistValue {
        do {
            return .object(try PublicJSONInputDecoder.decodeObject(
                from: source,
                context: context,
                rootMismatchMessage: "\(context) must be a JSON object"
            ))
        } catch let error as PublicJSONInputError {
            throw ValidationError(error.message)
        }
    }
}

struct PerformCommand: ConnectedOneShotCLICommand {
    static let fenceCommand = TheFence.Command.perform
    static let configuration = CommandConfiguration(
        commandName: Self.cliCommandName,
        abstract: "Execute one canonical Button Heist action or WaitFor statement"
    )

    @Argument(help: "One canonical Button Heist action or WaitFor statement.")
    var step: String

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: OutputOptions

    func requestArguments() throws -> TheFence.CommandArgumentEnvelope {
        Self.fenceArguments(CommandArgumentFields.value(FenceParameters.performStep, step))
    }
}
