import ArgumentParser

struct ConnectionOptions: ParsableArguments {
    @Option(name: .long, help: "Target by name, ID prefix, host:port, or [IPv6]:port")
    var device: String?

    @Option(name: .long, help: "Auth token from a previous connection")
    var token: String?

    @Option(name: .long, help: "Connection timeout in seconds")
    var connectTimeout: Double?

    @Flag(name: .shortAndLong, help: "Suppress status messages")
    var quiet: Bool = false

    /// Defaults for commands that take no connection flags. A bare
    /// `ConnectionOptions()` is never parsed, so reading any field traps.
    static let unconfigured: ConnectionOptions = {
        do {
            return try parse([])
        } catch {
            preconditionFailure("Default connection options failed to parse: \(error)")
        }
    }()
}
