import Foundation
import ButtonHeistTestSupport
import Testing
@testable import ThePlans

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

#if os(macOS) || os(Linux)
@Suite(.serialized)
struct HeistCompilerProcessTests {
    @Test
    func `nonzero exit and signal termination are distinct outcomes`() async throws {
        let runner = HeistCompilerProcess.Runner()

        let nonzero = try await runner.execute(
            shell("exit 23"),
            purpose: .execution,
            limits: limits()
        )
        let signaled = try await runner.execute(
            shell("kill -KILL $$"),
            purpose: .execution,
            limits: limits()
        )

        guard case .nonzeroExit(let code, _) = nonzero else {
            Issue.record("Expected a nonzero exit, got \(nonzero)")
            return
        }
        guard case .signaled(let signal, _) = signaled else {
            Issue.record("Expected signal termination, got \(signaled)")
            return
        }
        #expect(code == 23)
        #expect(signal == SIGKILL)
    }

    @Test
    func `timeout escalates ignored termination and removes the process group`() async throws {
        let temp = try ProcessTestTemporaryDirectory()
        let ready = try temp.makeReadinessFIFO()
        let script = """
        trap 'printf "stdout-overflow"; exit' TERM
        /bin/sh -c 'trap "" TERM; while :; do :; done' &
        printf ready > "$1"
        while :; do :; done
        """
        let (processes, processContinuation) = AsyncStream<pid_t>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task {
            try await HeistCompilerProcess.Runner().execute(
                shell(script, arguments: [ready.path]),
                purpose: .execution,
                limits: limits(
                    executionTimeout: .milliseconds(100),
                    terminationGrace: .milliseconds(250),
                    capturedByteLimitPerStream: 8
                ),
                processStarted: {
                    waitForProcessReadiness(at: ready)
                    processContinuation.yield($0)
                }
            )
        }

        let processGroup = try #require(await processes.first { _ in true })
        processContinuation.finish()
        let outcome = try await task.value

        guard case .timedOut(let output) = outcome else {
            Issue.record("Expected timeout, got \(outcome)")
            return
        }
        #expect(output.stdout == Data("stdout-o".utf8))
        #expect(processGroupExited(processGroup))
    }

    @Test
    func `task cancellation terminates and reaps the active process`() async throws {
        let temp = try ProcessTestTemporaryDirectory()
        let ready = try temp.makeReadinessFIFO()
        let command = shell(
            """
            printf ready > "$1"
            while :; do :; done
            """,
            arguments: [ready.path]
        )
        let (processes, processContinuation) = AsyncStream<pid_t>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task {
            try await HeistCompilerProcess.Runner().execute(
                command,
                purpose: .execution,
                limits: limits(
                    executionTimeout: .seconds(10),
                    terminationGrace: .milliseconds(250),
                    capturedByteLimitPerStream: 8
                ),
                processStarted: {
                    waitForProcessReadiness(at: ready)
                    processContinuation.yield($0)
                }
            )
        }

        let processPID = try #require(await processes.first { _ in true })
        processContinuation.finish()
        task.cancel()
        let outcome = try await task.value

        guard case .cancelled = outcome else {
            Issue.record("Expected cancellation, got \(outcome)")
            return
        }
        #expect(processExited(processPID))
    }

    @Test
    func `stdout overflow is terminal and retains its bounded prefix`() async throws {
        let byteLimit = 8
        let outcome = try await HeistCompilerProcess.Runner().execute(
            shell(
                """
                printf 'stdout-overflow'
                while :; do :; done
                """
            ),
            purpose: .execution,
            limits: limits(capturedByteLimitPerStream: byteLimit)
        )

        guard case .outputLimitExceeded(let stream, let output) = outcome else {
            Issue.record("Expected stdout overflow, got \(outcome)")
            return
        }
        #expect(stream == .stdout)
        #expect(output.stdout == Data("stdout-o".utf8))
        #expect(output.stderr.isEmpty)
    }

    @Test
    func `stderr overflow is terminal and retains its bounded prefix`() async throws {
        let byteLimit = 8
        let outcome = try await HeistCompilerProcess.Runner().execute(
            shell("printf 'stderr-overflow' >&2"),
            purpose: .execution,
            limits: limits(capturedByteLimitPerStream: byteLimit)
        )

        guard case .outputLimitExceeded(let stream, let output) = outcome else {
            Issue.record("Expected stderr overflow, got \(outcome)")
            return
        }
        #expect(stream == .stderr)
        #expect(output.stdout.isEmpty)
        #expect(output.stderr == Data("stderr-o".utf8))
    }

    @Test
    func `stdout wins when both drains overflow`() async throws {
        let script = """
        printf 'stdout-overflow'
        printf 'stderr-overflow' >&2
        """
        let outcome = try await HeistCompilerProcess.Runner().execute(
            shell(script),
            purpose: .execution,
            limits: limits(capturedByteLimitPerStream: 8)
        )

        guard case .outputLimitExceeded(let stream, let output) = outcome else {
            Issue.record("Expected simultaneous overflow, got \(outcome)")
            return
        }
        #expect(stream == .stdout)
        #expect(output.stdout == Data("stdout-o".utf8))
        #expect(output.stderr == Data("stderr-o".utf8))
    }

    @Test
    func `large stdout and stderr are drained while the process runs`() async throws {
        let byteCount = 256 * 1_024
        let outcome = try await HeistCompilerProcess.Runner().execute(
            HeistCompilerProcess.Command(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: [
                    "python3",
                    "-c",
                    "import sys; sys.stdout.write('o' * \(byteCount)); sys.stderr.write('e' * \(byteCount))",
                ]
            ),
            purpose: .execution,
            limits: limits()
        )

        guard case .succeeded(let output) = outcome else {
            Issue.record("Expected large output to drain, got \(outcome)")
            return
        }
        #expect(output.stdout == Data(repeating: UInt8(ascii: "o"), count: byteCount))
        #expect(output.stderr == Data(repeating: UInt8(ascii: "e"), count: byteCount))
    }

    @Test
    func `overflow forces kill escalation and removes the process group`() async throws {
        let script = """
        trap '' TERM
        /bin/sh -c 'trap "" TERM; while :; do :; done' &
        printf 'stdout-overflow'
        while :; do :; done
        """
        let (processes, processContinuation) = AsyncStream<pid_t>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task {
            try await HeistCompilerProcess.Runner().execute(
                shell(script),
                purpose: .execution,
                limits: limits(
                    executionTimeout: .seconds(5),
                    capturedByteLimitPerStream: 8
                ),
                processStarted: { processContinuation.yield($0) }
            )
        }

        let processGroup = try #require(await processes.first { _ in true })
        processContinuation.finish()
        let outcome = try await task.value

        guard case .outputLimitExceeded(let stream, let output) = outcome else {
            Issue.record("Expected overflow after forced cleanup, got \(outcome)")
            return
        }
        #expect(stream == .stdout)
        #expect(output.stdout == Data("stdout-o".utf8))
        #expect(processGroupExited(processGroup))
    }

    @Test
    func `runner is reusable after terminal overflow`() async throws {
        let runner = HeistCompilerProcess.Runner()
        let processLimits = limits(capturedByteLimitPerStream: 8)

        let overflow = try await runner.execute(
            shell("printf 'stdout-overflow'"),
            purpose: .execution,
            limits: processLimits
        )
        let success = try await runner.execute(
            shell("printf 'second'"),
            purpose: .execution,
            limits: processLimits
        )

        guard case .outputLimitExceeded(let stream, _) = overflow else {
            Issue.record("Expected first run to overflow, got \(overflow)")
            return
        }
        guard case .succeeded(let output) = success else {
            Issue.record("Expected second run to succeed, got \(success)")
            return
        }
        #expect(stream == .stdout)
        #expect(output.stdout == Data("second".utf8))
        #expect(output.stderr.isEmpty)
    }

    @Test
    func `compiler reports compilation deadline separately from execution deadline`() async throws {
        let temp = try ProcessTestTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            """
            import ThePlans

            func heist() throws -> HeistPlan {
                try HeistPlan("NeverCompiled") { Warn("no") }
            }
            """
        )
        let configuration = HeistSwiftCompiler.Configuration(
            packageRoot: buttonHeistPackageRoot,
            processLimits: limits(compilationTimeout: .nanoseconds(1)),
            temporaryDirectory: temp.url
        )

        let diagnostic = try await compilerDiagnostic {
            try await HeistSwiftCompiler(configuration: configuration).compileFile(source)
        }

        #expect(diagnostic.code.knownCode == .swiftCompilationCompileTimedOut)
        #expect(diagnostic.code.knownCode != .swiftCompilationExecutionTimedOut)
        #expect(try temp.generatedCompilerWorkspaces().isEmpty)
    }

    @Test
    func `compiler execution deadline removes its generated workspace`() async throws {
        let temp = try ProcessTestTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            """
            import ThePlans

            func heist() throws -> HeistPlan {
                while true {}
            }
            """
        )
        let configuration = HeistSwiftCompiler.Configuration(
            packageRoot: buttonHeistPackageRoot,
            processLimits: limits(
                compilationTimeout: .seconds(30),
                executionTimeout: .milliseconds(100)
            ),
            temporaryDirectory: temp.url
        )

        let diagnostic = try await compilerDiagnostic {
            try await HeistSwiftCompiler(configuration: configuration).compileFile(source)
        }

        #expect(diagnostic.code.knownCode == .swiftCompilationExecutionTimedOut)
        #expect(try temp.generatedCompilerWorkspaces().isEmpty)
    }

    @Test
    func `invalid source literal terminates only the compiler subprocess`() async throws {
        let temp = try ProcessTestTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            """
            import ThePlans

            func heist() throws -> HeistPlan {
                let _: WaitTimeout = 0
                return try HeistPlan("LiteralTrap") { Warn("never reached") }
            }
            """
        )
        let configuration = HeistSwiftCompiler.Configuration(
            packageRoot: buttonHeistPackageRoot,
            processLimits: limits(
                compilationTimeout: .seconds(30),
                executionTimeout: .seconds(10)
            ),
            temporaryDirectory: temp.url
        )

        let diagnostic = try await compilerDiagnostic {
            try await HeistSwiftCompiler(configuration: configuration).compileFile(source)
        }

        #expect(diagnostic.code.knownCode == .swiftCompilationExecutionTerminated)
        #expect(try temp.generatedCompilerWorkspaces().isEmpty)
    }

    private func shell(
        _ script: String,
        arguments: [String] = []
    ) -> HeistCompilerProcess.Command {
        HeistCompilerProcess.Command(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "compiler-process-test"] + arguments
        )
    }

    private func limits(
        compilationTimeout: Duration = .seconds(5),
        executionTimeout: Duration = .seconds(2),
        terminationGrace: Duration = .milliseconds(50),
        capturedByteLimitPerStream: Int = 1_048_576
    ) -> HeistCompilerProcess.Limits {
        HeistCompilerProcess.Limits(
            compilationTimeout: compilationTimeout,
            executionTimeout: executionTimeout,
            terminationGrace: terminationGrace,
            killGrace: .seconds(1),
            pollInterval: .milliseconds(5),
            capturedByteLimitPerStream: capturedByteLimitPerStream
        )
    }

    private func processExited(_ processIdentifier: pid_t) -> Bool {
        kill(processIdentifier, 0) == -1 && errno == ESRCH
    }

    private func processGroupExited(_ processGroup: pid_t) -> Bool {
        kill(-processGroup, 0) == -1 && errno == ESRCH
    }

    private var buttonHeistPackageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private func compilerDiagnostic<Value>(
    _ operation: () async throws -> Value
) async throws -> HeistBuildDiagnostic {
    do {
        _ = try await operation()
        throw CompilerProcessTestFailure.expectedCompilationFailure
    } catch let error as HeistPlanBuildError {
        return try #require(error.diagnostics.first)
    }
}

private enum CompilerProcessTestFailure: Error {
    case expectedCompilationFailure
}

private final class ProcessTestTemporaryDirectory {
    private let fixture: TemporaryDirectoryFixture
    var url: URL { fixture.url }

    init() throws {
        fixture = try TemporaryDirectoryFixture(prefix: "compiler-process-tests")
    }

    func writeSwiftSource(_ source: String) throws -> URL {
        let sourceURL = url.appendingPathComponent("Plan.swift")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        return sourceURL
    }

    func generatedCompilerWorkspaces() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("heist-source-") }
    }

    func makeReadinessFIFO() throws -> URL {
        let fifo = url.appendingPathComponent("ready-\(UUID().uuidString)")
        guard mkfifo(fifo.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return fifo
    }
}

private func waitForProcessReadiness(at fifo: URL) {
    let descriptor = open(fifo.path, O_RDONLY)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    var byte: UInt8 = 0
    _ = read(descriptor, &byte, 1)
}

#endif
