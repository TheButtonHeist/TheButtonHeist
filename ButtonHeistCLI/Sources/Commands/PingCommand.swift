import ArgumentParser
@_spi(ButtonHeistTooling) import ButtonHeist

struct PingCommand: ConnectedOneShotCLICommand {
    static let fenceCommand = TheFence.Command.ping
    static let configuration = CommandConfiguration(
        commandName: Self.cliCommandName,
        abstract: "Check Button Heist connection health",
        discussion: """
            Sends a lightweight health ping to the connected app and returns \
            cheap server/app identity metadata.

            Examples:
              buttonheist ping
              buttonheist ping --format json
            """
    )

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: OutputOptions

    var runnerStatusMessage: String? { "Checking health..." }
}
