import ArgumentParser
@_spi(ButtonHeistTooling) import ButtonHeist
import ThePlans

struct ListHeistsCommand: LocalOneShotCLICommand {
    static let fenceCommand = TheFence.Command.listHeists
    static let configuration = CommandConfiguration(
        commandName: Self.cliCommandName,
        abstract: "List reusable heists in a .heist artifact or inline ButtonHeist source",
        discussion: """
            Lists the root entry and all named reusable heists derived from one
            decoded, runtime-validated plan.

            Examples:
              buttonheist list_heists --path Flow.heist
              buttonheist list_heists --detail --path Flow.heist
              buttonheist list_heists --plan 'HeistPlan("flow") { Warn("Check") }'
            """
    )

    @Option(name: .long, help: "Path to a .heist package artifact.")
    var path: String?

    @OptionGroup var output: OutputOptions

    @Option(name: .long, help: "Inline canonical ButtonHeist DSL source.")
    var plan: String?

    @Flag(name: .long, help: "Include derived command names, nested heist calls, counts, and safe semantic surface summaries.")
    var detail = false

    func requestArguments() throws -> TheFence.CommandArgumentEnvelope {
        try RunHeistCommand.planArguments(
            inline: plan,
            path: path,
            entry: nil,
            commandName: Self.cliCommandName,
            additionalFields: detail ? [
                CommandArgumentFields.value(FenceParameters.heistCatalogDetail, .detailed),
            ] : []
        )
    }
}

struct DescribeHeistCommand: LocalOneShotCLICommand {
    static let fenceCommand = TheFence.Command.describeHeist
    static let configuration = CommandConfiguration(
        commandName: Self.cliCommandName,
        abstract: "Describe one reusable heist in a .heist artifact or inline ButtonHeist source",
        discussion: """
            Describes the selected root entry or named reusable heist from one
            decoded, runtime-validated plan.

            Examples:
              buttonheist describe_heist checkout --path Flow.heist
              buttonheist describe_heist Cart.checkout --plan 'HeistPlan("flow") { Warn("Check") }'
            """
    )

    @Argument(help: "Root entry or capability name to describe.")
    var name: String

    @Option(name: .long, help: "Path to a .heist package artifact.")
    var path: String?

    @OptionGroup var output: OutputOptions

    @Option(name: .long, help: "Inline canonical ButtonHeist DSL source.")
    var plan: String?

    func requestArguments() throws -> TheFence.CommandArgumentEnvelope {
        try RunHeistCommand.planArguments(
            inline: plan,
            path: path,
            entry: nil,
            commandName: Self.cliCommandName,
            additionalFields: [CommandArgumentFields.value("heist", name)]
        )
    }
}
