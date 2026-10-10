import ArgumentParser
@_spi(ButtonHeistTooling) import ButtonHeist

struct GetNotificationsCommand: ConnectedOneShotCLICommand {
    static let fenceCommand = TheFence.Command.getNotifications
    static let configuration = CommandConfiguration(
        commandName: Self.cliCommandName,
        abstract: "Read retained accessibility notifications",
        discussion: """
            Read the ordered accessibility notifications retained in the
            current Vault history. Each notification contains normalized text,
            element semantics, or both.

            Examples:
              buttonheist get_notifications
            """
    )

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: OutputOptions

    var runnerStatusMessage: String? { "Reading notifications..." }
}
