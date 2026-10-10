import ArgumentParser
@_spi(ButtonHeistTooling) import ButtonHeist

struct GetPasteboardCommand: ConnectedOneShotCLICommand {
    static let fenceCommand = TheFence.Command.getPasteboard
    static let configuration = CommandConfiguration(
        commandName: Self.cliCommandName,
        abstract: "Read text from the general pasteboard",
        discussion: """
            Read text from the device's general pasteboard.
            If the content was written by another app, iOS may show
            an "Allow Paste" system dialog.

            Examples:
              buttonheist get_pasteboard
            """
    )

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: OutputOptions

    var runnerStatusMessage: String? { "Reading pasteboard..." }
}
