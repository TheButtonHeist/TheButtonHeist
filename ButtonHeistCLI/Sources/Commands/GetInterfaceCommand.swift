import ArgumentParser
import Foundation
@_spi(ButtonHeistTooling) import ButtonHeist

struct GetInterfaceCommand: ConnectedOneShotCLICommand {
    static let fenceCommand = TheFence.Command.getInterface
    static let configuration = CommandConfiguration(
        commandName: Self.cliCommandName,
        abstract: "Read the app accessibility hierarchy from the connected device"
    )

    @OptionGroup var connection: ConnectionOptions

    @OptionGroup var output: OutputOptions

    @OptionGroup var subtree: AccessibilityTargetOptions

    @OptionGroup var discoveryLimits: InterfaceDiscoveryLimitOptions

    @Option(name: .long, help: "Interface read mode: current or discovery (default).")
    var mode: String?

    var runnerStatusMessage: String? { "Reading interface..." }

    func requestArguments() throws -> TheFence.CommandArgumentEnvelope {
        return Self.fenceArguments(
            CommandArgumentFields.optional("mode", mode),
            CommandArgumentFields.optionalEncoded("subtree", try subtree.parsedTarget()),
            CommandArgumentFields.optional(
                "maxScrollsPerContainer",
                discoveryLimits.maxScrollsPerContainer
            ),
            CommandArgumentFields.optional(
                "maxScrollsPerDiscovery",
                discoveryLimits.maxScrollsPerDiscovery
            )
        )
    }
}

struct InterfaceDiscoveryLimitOptions: ParsableArguments {
    @Option(name: .long, help: "Maximum page-scroll attempts per scroll container during interface discovery.")
    var maxScrollsPerContainer: Int?

    @Option(name: .long, help: "Maximum total page-scroll attempts during interface discovery.")
    var maxScrollsPerDiscovery: Int?
}
