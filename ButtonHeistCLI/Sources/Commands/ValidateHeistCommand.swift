import ArgumentParser
@_spi(ButtonHeistTooling) import ButtonHeist

struct ValidateHeistCommand: LocalOneShotCLICommand {
    static let fenceCommand = TheFence.Command.validateHeist
    static let configuration = CommandConfiguration(
        commandName: Self.cliCommandName,
        abstract: "Validate a Button Heist plan without connecting to an app",
        discussion: """
            Validates one inline canonical ButtonHeist source plan or generated
            .heist artifact. This checks runtime admission, the root argument,
            and optional authoring lint. It cannot verify live targets or UI
            outcomes.

            Examples:
              buttonheist validate_heist --plan 'HeistPlan { Warn("Check") }'
              buttonheist validate_heist --path Flow.heist --lint strict_test
              buttonheist validate_heist --path Search.heist --argument '{"type":"string","value":"milk"}'
            """
    )

    @Option(name: .long, help: "Path to a generated .heist package artifact.")
    var path: String?

    @Option(name: .long, help: "Inline canonical ButtonHeist DSL source.")
    var plan: String?

    @Option(name: .long, help: "Root heist argument as canonical HeistArgument JSON object.")
    var argument: String?

    @Option(name: .long, help: "Authoring lint mode: none, composition_quality, or strict_test.")
    var lint = ValidateHeistLintArgument.defaultValue

    @OptionGroup var output: OutputOptions

    func requestArguments() throws -> TheFence.CommandArgumentEnvelope {
        try RunHeistCommand.planArguments(
            inline: plan,
            path: path,
            entry: nil,
            argument: argument,
            commandName: Self.cliCommandName,
            additionalFields: [
                CommandArgumentFields.value(FenceParameters.heistValidationLint, lint.value),
            ]
        )
    }

}

enum ValidateHeistLintArgument: String, CaseIterable, ExpressibleByArgument {
    case none
    case compositionQuality = "composition_quality"
    case strictTest = "strict_test"

    static let defaultValue: Self = {
        let value = TheFence.Command.validateHeist.descriptor.requiredDefaultValue(
            for: FenceParameters.heistValidationLint
        )
        guard let result = Self(rawValue: value.rawValue) else {
            preconditionFailure("Fence validate_heist lint default is not a CLI lint mode")
        }
        return result
    }()

    var value: HeistValidationLintMode {
        guard let result = HeistValidationLintMode(rawValue: rawValue) else {
            preconditionFailure("CLI validate_heist lint mode is not a Fence lint mode")
        }
        return result
    }
}
