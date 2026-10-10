import ArgumentParser
@_spi(ButtonHeistTooling) import ButtonHeist

struct GetSessionStateCommand: ConnectedOneShotCLICommand {
    static let fenceCommand = TheFence.Command.getSessionState
    static let configuration = CommandConfiguration(
        commandName: Self.cliCommandName,
        abstract: "Report the current connection + session state",
        discussion: """
            Returns connection status, connected device, configured timeouts,
            and the most recent action/latency. Useful
            in scripts that need to probe whether an agent is healthy before
            issuing commands.

            Examples:
              buttonheist get_session_state
              buttonheist get_session_state --format json
            """
    )

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: OutputOptions

}
