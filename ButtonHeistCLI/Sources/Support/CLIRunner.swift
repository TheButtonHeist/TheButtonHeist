import ArgumentParser
import Foundation
@_spi(ButtonHeistInternals) @_spi(ButtonHeistTooling) import ButtonHeist

/// Shared utility for standalone CLI commands that execute a single TheFence request.
enum CLIRunner {

    // MARK: - Nested Types

    typealias CommandOutputProjection = @ButtonHeistActor (TheFence, FenceResponse) throws -> CommandOutput

    enum ExecutionMode: Equatable {
        case connected
        case direct
    }

    struct CommandDescriptor {
        let fenceDescriptor: FenceCommandDescriptor
        let connection: ConnectionOptions
        let format: OutputFormat?
        let arguments: TheFence.CommandArgumentEnvelope
        private(set) var executionMode: ExecutionMode = .connected
        private(set) var statusMessage: String?
        private(set) var configuration: EnvironmentConfig?
        private(set) var cleanup: () -> Void = {}
        private(set) var output: CommandOutputProjection?
    }

    enum CommandOutput {
        case response(FenceResponse)
        case binary(Data)
        case junit(response: FenceResponse, xml: String?, path: String)
    }

    enum RenderedOutput: Equatable {
        case text(String)
        case binary(Data)
        case failedText(String)
        case failedStatus(String)

        var isFailure: Bool {
            switch self {
            case .text, .binary:
                return false
            case .failedText, .failedStatus:
                return true
            }
        }
    }

    typealias JSONResponseRenderer = (FenceResponse) throws -> PublicJSONRendering

    // MARK: - Command Execution

    /// Execute a single TheFence command, format the response, and signal a non-zero
    /// exit code via `ExitCode.failure` when the action fails.
    ///
    /// Use this for the common "send one command, print the response, return" path.
    /// `ExitCode.failure` propagates up through ArgumentParser so the process exits
    /// with status 1 — but unwinds normally so any caller `defer` blocks still fire.
    @ButtonHeistActor
    static func run(_ descriptor: CommandDescriptor) async throws {
        defer { descriptor.cleanup() }
        let fallbackFormat = descriptor.format ?? .auto
        let fence: TheFence
        let response: FenceResponse
        do {
            fence = try makeFence(descriptor: descriptor)
            do {
                if descriptor.executionMode == .connected {
                    try await fence.start()
                }
                if let statusMessage = descriptor.statusMessage, !isQuiet(descriptor) {
                    logStatus(statusMessage)
                }
                response = try await fence.execute(try fence.admit(FenceCommandInput(
                    command: descriptor.fenceDescriptor.command,
                    arguments: descriptor.arguments
                )))
            } catch {
                fence.stop()
                throw error
            }
        } catch {
            output(.response(.failure(error)), format: fallbackFormat)
            throw ExitCode.failure
        }
        defer { fence.stop() }

        let commandOutput: CommandOutput
        do {
            commandOutput = try descriptor.output?(fence, response) ?? .response(response)
        } catch {
            commandOutput = .response(.failure(error))
        }

        if output(commandOutput, format: fallbackFormat).isFailure {
            throw ExitCode.failure
        }
    }

    // MARK: - Output Formatting

    @discardableResult
    @ButtonHeistActor
    static func output(
        _ output: CommandOutput,
        format: OutputFormat
    ) -> RenderedOutput {
        let rendered = renderedOutput(for: output, format: format)
        switch rendered {
        case .text(let text), .failedText(let text):
            writeOutput(text)
        case .binary(let data):
            writeBinaryOutput(data)
        case .failedStatus(let message):
            logStatus(message)
        }
        return rendered
    }

    static func renderedOutput(
        for output: CommandOutput,
        format: OutputFormat,
        jsonRenderer: JSONResponseRenderer = defaultJSONResponse
    ) -> RenderedOutput {
        switch output {
        case .response(let response):
            return renderedResponse(
                response,
                format: format,
                jsonRenderer: jsonRenderer
            )
        case .binary(let data):
            return .binary(data)
        case .junit(let response, let xml, let path):
            if let xml {
                do {
                    try xml.write(
                        to: URL(fileURLWithPath: path),
                        atomically: true,
                        encoding: .utf8
                    )
                    logStatus("JUnit report written to \(path)")
                } catch {
                    return renderedResponse(
                        .failure(error),
                        format: format,
                        jsonRenderer: jsonRenderer
                    )
                }
            } else {
                logStatus("Warning: --junit requested but run_heist did not produce a report")
            }
            return renderedResponse(
                response,
                format: format,
                jsonRenderer: jsonRenderer
            )
        }
    }

    private static func renderedResponse(
        _ response: FenceResponse,
        format: OutputFormat,
        jsonRenderer: JSONResponseRenderer
    ) -> RenderedOutput {
        let responseFailed = response.isFailure
        switch format {
        case .human:
            let text = response.humanFormatted()
            return responseFailed ? .failedText(text) : .text(text)
        case .compact:
            let text = response.compactFormatted()
            return responseFailed ? .failedText(text) : .text(text)
        case .json:
            do {
                let rendering = try jsonRenderer(response)
                if let json = String(data: rendering.data, encoding: .utf8) {
                    let failed = responseFailed || rendering.failure != nil
                    return failed ? .failedText(json) : .text(json)
                }
                return .failedStatus("Failed to encode JSON data as UTF-8")
            } catch {
                return .failedStatus("Failed to serialize response as JSON: \(error.localizedDescription)")
            }
        }
    }

    private static func defaultJSONResponse(_ response: FenceResponse) throws -> PublicJSONRendering {
        try response.jsonRendering(profile: .summary)
    }

    // MARK: - Private Helpers

    @ButtonHeistActor
    private static func makeFence(descriptor: CommandDescriptor) throws -> TheFence {
        let config: EnvironmentConfig
        if let configuration = descriptor.configuration {
            config = configuration
        } else if descriptor.executionMode == .direct {
            config = try EnvironmentConfig.resolve(autoReconnect: false)
        } else {
            let connection = descriptor.connection
            config = try EnvironmentConfig.resolve(
                deviceFilter: connection.device,
                token: connection.token,
                connectionTimeout: connection.connectTimeout,
                autoReconnect: false
            )
        }
        let fence = TheFence(configuration: config.fenceConfiguration)
        let quiet = isQuiet(descriptor)
        fence.onStatus = { message in
            if !quiet { logStatus(message) }
        }
        return fence
    }

    private static func isQuiet(_ descriptor: CommandDescriptor) -> Bool {
        descriptor.executionMode == .direct || descriptor.connection.quiet
    }
}
