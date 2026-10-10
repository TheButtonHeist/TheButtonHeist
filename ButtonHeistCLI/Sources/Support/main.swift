import ArgumentParser
@_spi(ButtonHeistTooling) import ButtonHeist
import Foundation
import TheScore

@main
struct ButtonHeistApp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "buttonheist",
        abstract: "Inspect and interact with iOS app UI elements.",
        discussion: """
            Common starter flow:
              buttonheist list_devices                      # Find devices
              buttonheist get_interface                     # Inspect UI hierarchy
              buttonheist perform 'Activate(.label("My Button"))'
              buttonheist perform 'TypeText("hello")'
              buttonheist get_screen                        # Capture screen

            Use `buttonheist json_lines` for canonical JSON commands on stdin, or read the generated command reference for the full command contract.
            """,
        version: buttonHeistVersion.description,
        subcommands: CLICommandCatalog.subcommands
    )
}

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case human
    case json
    case compact

    static var auto: OutputFormat {
        isatty(STDIN_FILENO) != 0 ? .human : .json
    }
}
