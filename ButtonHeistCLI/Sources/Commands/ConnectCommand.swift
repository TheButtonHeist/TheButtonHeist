import ArgumentParser
@_spi(ButtonHeistTooling) import ButtonHeist

/// Connect (or reconnect) to an iOS app with Button Heist enabled.
struct ConnectCommand: ConnectedOneShotCLICommand {
    static let configuration = CommandConfiguration(
        commandName: Self.cliCommandName,
        abstract: "Connect to an iOS app with Button Heist enabled",
        discussion: """
            With no arguments, establishes the currently configured session. \
            Resolution order: --device flag, BUTTONHEIST_DEVICE env var, then \
            the default target in .buttonheist.json (or ~/.config/buttonheist/config.json).

            This command returns session state; use get_interface to observe UI hierarchy.

            Examples:
              buttonheist connect                       # Reconnect using configured target
              buttonheist connect --device 127.0.0.1:1455
              buttonheist connect --device sim --token my-task-slug
            """
    )

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: OutputOptions

    @ButtonHeistActor
    func runnerDescriptor() async throws -> CLIRunner.CommandDescriptor {
        // Peek at the resolved environment before invoking TheFence so we can
        // produce a clear error naming what was checked. EnvironmentConfig
        // drops to nil when nothing is configured, and TheFence's own error
        // message is generic.
        let resolved = try EnvironmentConfig.resolve(
            deviceFilter: connection.device,
            token: connection.token,
            connectionTimeout: connection.connectTimeout,
            autoReconnect: false
        )
        guard resolved.hasConnectionTarget else {
            throw ValidationError("""
                No connection target configured. Checked:
                  - --device flag
                  - BUTTONHEIST_DEVICE env var
                  - .buttonheist.json (current directory)
                  - ~/.config/buttonheist/config.json

                Pass --device (e.g. `buttonheist connect --device 127.0.0.1:1455`), set \
                BUTTONHEIST_DEVICE, or add a default target to .buttonheist.json.
                """)
        }
        return CLIRunner.CommandDescriptor(
            fenceDescriptor: Self.fenceDescriptor,
            connection: connection,
            format: output.format,
            arguments: Self.fenceArguments(),
            executionMode: .direct,
            configuration: resolved
        )
    }
}
