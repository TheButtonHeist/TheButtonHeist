import ArgumentParser
@_spi(ButtonHeistTooling) import ButtonHeist

struct ListDevicesCommand: LocalOneShotCLICommand {
    static let fenceCommand = TheFence.Command.listDevices
    static let configuration = CommandConfiguration(
        commandName: Self.cliCommandName,
        abstract: "List available iOS apps with Button Heist enabled"
    )

    @OptionGroup var output: OutputOptions

    var runnerStatusMessage: String? { "Discovering devices..." }
}
