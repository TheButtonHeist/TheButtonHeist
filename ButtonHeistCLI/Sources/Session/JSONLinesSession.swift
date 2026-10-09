import Foundation
import Darwin
@_spi(ButtonHeistInternals) @_spi(ButtonHeistTooling) import ButtonHeist

@ButtonHeistActor
final class JSONLinesSession {

    // MARK: - Properties

    private let format: OutputFormat
    private let fence: TheFence
    private let sessionTimeout: SessionIdleTimeout
    private var idleMonitor: IdleMonitor?

    // MARK: - Init

    init(config: EnvironmentConfig, format: OutputFormat) {
        self.format = format
        self.sessionTimeout = config.sessionTimeout
        self.fence = TheFence(configuration: config.fenceConfiguration)
        self.fence.onStatus = { message in
            logStatus(message)
        }
    }

    // MARK: - JSON Lines Loop

    func run() async throws {
        try await fence.start()

        if let timeout = sessionTimeout.seconds {
            logStatus("Idle timeout: \(Int(timeout))s")
        }

        // SIGINT closes stdin to unstick the blocking readLine; the loop sees a
        // nil line and runs the same structured teardown as EOF/idle timeout.
        signal(SIGINT) { _ in close(STDIN_FILENO) }

        idleMonitor = sessionTimeout.seconds.map(makeTimeoutMonitor)

        while true {
            guard let line = await Self.readInputLine() else {
                break
            }

            idleMonitor?.resetTimer()

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            await executeRequestLine(trimmed)
        }

        idleMonitor?.stop()
        idleMonitor = nil
        fence.stop()
    }

    /// Blocking standard input runs on Swift's generic executor rather than
    /// inheriting the session actor.
    @concurrent
    private nonisolated static func readInputLine() async -> String? {
        Swift.readLine()
    }

    private func makeTimeoutMonitor(timeout: TimeInterval) -> IdleMonitor {
        let monitor = IdleMonitor(timeout: timeout) { [weak self] in
            self?.expireAfterIdleTimeout(timeout)
        }
        monitor.resetTimer()
        return monitor
    }

    private func expireAfterIdleTimeout(_ timeout: TimeInterval) {
        logStatus("JSON-lines session idle timeout (\(Int(timeout))s) — exiting.")
        close(STDIN_FILENO)
    }

    private func executeRequestLine(_ line: String) async {
        let parsedRequest: CLIParsedRequest
        do {
            parsedRequest = try CLIMachineRequestParser.parsedRequest(from: line)
        } catch let error as CLIMachineRequestError {
            output(.error(error.diagnosticFailure))
            return
        } catch {
            output(.failure(error))
            return
        }

        do {
            let operation = try fence.admit(parsedRequest.input)
            let response = try await fence.execute(operation)
            output(response)
        } catch {
            output(.failure(error))
        }
    }

    private func output(_ response: FenceResponse) {
        CLIRunner.output(.response(response), format: format)
    }

}
