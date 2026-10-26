import Foundation
import Testing

import TheScore

struct VersionCommandTests {
    private final class BundleMarker: NSObject {}

    @Test(.timeLimit(.minutes(1)))
    func `version prints the canonical version without starting the server`() async throws {
        let bundle = Bundle(for: BundleMarker.self)
        let binary = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("buttonheist-mcp")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "BUTTONHEIST_CONNECTION_TIMEOUT": "invalid",
        ]) { _, override in override }
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let termination = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in
            termination.continuation.yield(())
            termination.continuation.finish()
        }
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            termination.continuation.finish()
        }
        for await _ in termination.stream { break }
        guard !process.isRunning else {
            Issue.record("--version did not exit while stdin remained open")
            return
        }

        #expect(process.terminationStatus == 0)
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "\(buttonHeistVersion)\n")
        #expect(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
