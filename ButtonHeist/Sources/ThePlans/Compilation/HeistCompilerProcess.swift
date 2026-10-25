import Foundation

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

package enum HeistCompilerProcess {
    package enum Purpose: Sendable {
        case compilation
        case execution
    }

    package struct Limits: Sendable, Equatable {
        package static let `default` = Self(
            compilationTimeout: .seconds(120),
            executionTimeout: .seconds(10),
            terminationGrace: .milliseconds(250),
            killGrace: .seconds(2),
            pollInterval: .milliseconds(10),
            capturedByteLimitPerStream: 1_048_576
        )

        package let compilationTimeout: Duration
        package let executionTimeout: Duration
        package let terminationGrace: Duration
        package let killGrace: Duration
        package let pollInterval: Duration
        package let capturedByteLimitPerStream: Int

        package init(
            compilationTimeout: Duration,
            executionTimeout: Duration,
            terminationGrace: Duration,
            killGrace: Duration,
            pollInterval: Duration,
            capturedByteLimitPerStream: Int
        ) {
            precondition(compilationTimeout > .zero)
            precondition(executionTimeout > .zero)
            precondition(terminationGrace > .zero)
            precondition(killGrace > .zero)
            precondition(pollInterval > .zero)
            precondition(capturedByteLimitPerStream > 0)
            self.compilationTimeout = compilationTimeout
            self.executionTimeout = executionTimeout
            self.terminationGrace = terminationGrace
            self.killGrace = killGrace
            self.pollInterval = pollInterval
            self.capturedByteLimitPerStream = capturedByteLimitPerStream
        }

        package func timeout(for purpose: Purpose) -> Duration {
            switch purpose {
            case .compilation:
                compilationTimeout
            case .execution:
                executionTimeout
            }
        }
    }

#if os(macOS) || os(Linux)
    package struct Command: Sendable, Equatable {
        package let executable: URL
        package let arguments: [String]

        package init(executable: URL, arguments: [String]) {
            precondition(executable.isFileURL)
            self.executable = executable.standardizedFileURL
            self.arguments = arguments
        }
    }

    package struct Output: Sendable, Equatable {
        package let stdout: Data
        package let stderr: Data

        package var diagnostics: String {
            let stderrText = String(data: stderr, encoding: .utf8) ?? ""
            let stdoutText = String(data: stdout, encoding: .utf8) ?? ""
            return [stderrText, stdoutText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    package enum OutputStream: String, Sendable, Equatable, CaseIterable {
        case stdout
        case stderr
    }

    package enum Outcome: Sendable, Equatable {
        case succeeded(Output)
        case nonzeroExit(code: Int32, output: Output)
        case signaled(signal: Int32, output: Output)
        case timedOut(Output)
        case cancelled
        case outputLimitExceeded(stream: OutputStream, output: Output)
    }

    enum Operation: String, Sendable, Equatable {
        case wait
        case fileActionsInitialization = "file-actions initialization"
        case spawnAttributesInitialization = "spawn-attributes initialization"
        case processGroupConfiguration = "process-group configuration"
        case signalMaskInitialization = "signal-mask initialization"
        case signalMaskConfiguration = "signal-mask configuration"
        case signalDefaultsInitialization = "signal-defaults initialization"
        case signalDefaultsConfiguration = "signal-defaults configuration"
        case spawnFlagsConfiguration = "spawn-flags configuration"
        case launch
        case stdoutRedirect = "stdout redirect"
        case stderrRedirect = "stderr redirect"
        case stdoutReadClose = "stdout read close"
        case stderrReadClose = "stderr read close"
        case stdoutWriteClose = "stdout write close"
        case stderrWriteClose = "stderr write close"
        case pipeCreation = "pipe creation"
        case nonblockingPipeConfiguration = "nonblocking pipe configuration"
    }

    struct LaunchError: Error, Sendable, Equatable, CustomStringConvertible {
        let operation: Operation
        let code: Int32

        var description: String {
            "process \(operation.rawValue) failed with POSIX error \(code): \(String(cString: strerror(code)))"
        }
    }

    struct CleanupError: Error, Sendable, Equatable, CustomStringConvertible {
        let processGroup: pid_t

        var description: String {
            "process group \(processGroup) survived SIGKILL cleanup"
        }
    }

    package struct Runner: Sendable {
        package static let shared = Runner()

        package init() {}

        @concurrent
        package func execute(
            _ command: Command,
            purpose: Purpose,
            limits: Limits = .default,
            processStarted: (@Sendable (pid_t) -> Void)? = nil
        ) async throws -> Outcome {
            guard !Task.isCancelled else {
                return .cancelled
            }

            let process = try spawn(command)
            processStarted?(process.pid)

            let stdoutDrain = OutputDrain(
                fileDescriptor: process.stdoutFileDescriptor,
                capturedByteLimit: limits.capturedByteLimitPerStream,
                pollInterval: limits.pollInterval
            )
            let stderrDrain = OutputDrain(
                fileDescriptor: process.stderrFileDescriptor,
                capturedByteLimit: limits.capturedByteLimitPerStream,
                pollInterval: limits.pollInterval
            )
            let stdoutTask = await stdoutDrain.start()
            let stderrTask = await stderrDrain.start()

            let terminalCandidate: SelectedTerminal
            do {
                terminalCandidate = try await wait(
                    for: process.pid,
                    timeout: limits.timeout(for: purpose),
                    pollInterval: limits.pollInterval,
                    stdoutDrain: stdoutDrain,
                    stderrDrain: stderrDrain
                )
            } catch {
                let cleanupResult = await cleanupResult {
                    _ = try await shutDown(process, knownTermination: nil, limits: limits)
                }
                await stdoutDrain.stop()
                await stderrDrain.stop()
                _ = await stdoutTask.value
                _ = await stderrTask.value
                try cleanupResult.get()
                throw error
            }

            let shutdownResult = await cleanupResult {
                _ = try await shutDown(
                    process,
                    knownTermination: terminalCandidate.reapedTermination,
                    limits: limits
                )
            }

            await stdoutDrain.stop()
            await stderrDrain.stop()
            let stdout = await stdoutTask.value
            let stderr = await stderrTask.value
            let output = Output(
                stdout: stdout.data,
                stderr: stderr.data
            )
            try shutdownResult.get()
            let selectedTerminal = terminalCandidate.selectedAfterOutputDrain(
                stdoutExceededLimit: stdout.exceededLimit,
                stderrExceededLimit: stderr.exceededLimit
            )
            return selectedTerminal.outcome(output: output)
        }

        private func cleanupResult(
            _ cleanup: () async throws -> Void
        ) async -> Result<Void, Error> {
            do {
                try await cleanup()
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        private func wait(
            for pid: pid_t,
            timeout: Duration,
            pollInterval: Duration,
            stdoutDrain: OutputDrain,
            stderrDrain: OutputDrain
        ) async throws -> SelectedTerminal {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while true {
                if let reapedTermination = try reap(pid) {
                    return .reapedTermination(reapedTermination)
                }
                if await stdoutDrain.exceededLimit {
                    return .outputLimitExceeded(.stdout)
                }
                if await stderrDrain.exceededLimit {
                    return .outputLimitExceeded(.stderr)
                }
                if Task.isCancelled {
                    return .cancelled
                }
                if ContinuousClock.now >= deadline {
                    return .timedOut
                }
                do {
                    try await Task.sleep(for: pollInterval)
                } catch is CancellationError {
                    return .cancelled
                }
            }
        }

        private func shutDown(
            _ process: SpawnedProcess,
            knownTermination: ChildTermination?,
            limits: Limits
        ) async throws -> ChildTermination {
            var termination = knownTermination
            if processGroupExists(process.processGroup) {
                signalProcessGroup(process.processGroup, signal: SIGTERM)
                termination = await waitForShutdown(
                    pid: process.pid,
                    processGroup: process.processGroup,
                    duration: limits.terminationGrace,
                    pollInterval: limits.pollInterval,
                    knownTermination: termination
                )
            }
            if processGroupExists(process.processGroup) {
                signalProcessGroup(process.processGroup, signal: SIGKILL)
                termination = await waitForShutdown(
                    pid: process.pid,
                    processGroup: process.processGroup,
                    duration: limits.killGrace,
                    pollInterval: limits.pollInterval,
                    knownTermination: termination
                )
            }
            guard let termination, !processGroupExists(process.processGroup) else {
                throw CleanupError(processGroup: process.processGroup)
            }
            return termination
        }

        private func waitForShutdown(
            pid: pid_t,
            processGroup: pid_t,
            duration: Duration,
            pollInterval: Duration,
            knownTermination: ChildTermination? = nil
        ) async -> ChildTermination? {
            var termination = knownTermination
            let deadline = ContinuousClock.now.advanced(by: duration)
            repeat {
                if termination == nil {
                    termination = try? reap(pid)
                }
                if termination != nil && !processGroupExists(processGroup) {
                    return termination
                }
                await sleepIgnoringCancellation(for: pollInterval)
            } while ContinuousClock.now < deadline

            if termination == nil {
                termination = try? reap(pid)
            }
            return termination
        }

        private func sleepIgnoringCancellation(for duration: Duration) async {
            await Task(priority: .utility) {
                try? await Task.sleep(for: duration)
            }.value
        }

        private func reap(_ pid: pid_t) throws -> ChildTermination? {
            var status: Int32 = 0
            while true {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid {
                    return ChildTermination(status: status)
                }
                if result == 0 {
                    return nil
                }
                if errno == EINTR {
                    continue
                }
                if errno == ECHILD {
                    return nil
                }
                throw LaunchError(operation: .wait, code: errno)
            }
        }

        private func signalProcessGroup(_ processGroup: pid_t, signal: Int32) {
            guard processGroup > 0 else { return }
            _ = kill(-processGroup, signal)
        }

        private func processGroupExists(_ processGroup: pid_t) -> Bool {
            guard processGroup > 0 else { return false }
            if kill(-processGroup, 0) == 0 {
                return true
            }
            return errno == EPERM
        }

        private func spawn(_ command: Command) throws -> SpawnedProcess {
            let stdoutPipe = try makePipe()
            let stderrPipe: ProcessPipe
            do {
                stderrPipe = try makePipe()
            } catch {
                closePipe(stdoutPipe)
                throw error
            }
            do {
                try setNonblocking(stdoutPipe.readFileDescriptor)
                try setNonblocking(stderrPipe.readFileDescriptor)
            } catch {
                closePipe(stdoutPipe)
                closePipe(stderrPipe)
                throw error
            }

            do {
                var fileActions: posix_spawn_file_actions_t?
                try requirePOSIXSuccess(
                    posix_spawn_file_actions_init(&fileActions),
                    operation: .fileActionsInitialization
                )
                defer { posix_spawn_file_actions_destroy(&fileActions) }

                try configure(
                    &fileActions,
                    stdoutPipe: stdoutPipe,
                    stderrPipe: stderrPipe
                )

                var attributes: posix_spawnattr_t?
                try requirePOSIXSuccess(
                    posix_spawnattr_init(&attributes),
                    operation: .spawnAttributesInitialization
                )
                defer { posix_spawnattr_destroy(&attributes) }

                try requirePOSIXSuccess(
                    posix_spawnattr_setpgroup(&attributes, 0),
                    operation: .processGroupConfiguration
                )
                var signalMask = sigset_t()
                try requirePOSIXSuccess(
                    sigemptyset(&signalMask),
                    operation: .signalMaskInitialization
                )
                try requirePOSIXSuccess(
                    posix_spawnattr_setsigmask(&attributes, &signalMask),
                    operation: .signalMaskConfiguration
                )
                var defaultSignals = sigset_t()
                try requirePOSIXSuccess(
                    sigemptyset(&defaultSignals),
                    operation: .signalDefaultsInitialization
                )
                try requirePOSIXSuccess(
                    sigaddset(&defaultSignals, SIGTERM),
                    operation: .signalDefaultsInitialization
                )
                try requirePOSIXSuccess(
                    posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
                    operation: .signalDefaultsConfiguration
                )
                let spawnFlags = POSIX_SPAWN_SETPGROUP
                    | POSIX_SPAWN_SETSIGMASK
                    | POSIX_SPAWN_SETSIGDEF
                try requirePOSIXSuccess(
                    posix_spawnattr_setflags(&attributes, Int16(spawnFlags)),
                    operation: .spawnFlagsConfiguration
                )

                var pid: pid_t = 0
                let environment = ProcessInfo.processInfo.environment
                    .map { "\($0.key)=\($0.value)" }
                    .sorted()
                let spawnResult = withCStringArray([command.executable.path] + command.arguments) { arguments in
                    withCStringArray(environment) { environment in
                        command.executable.path.withCString { executable in
                            posix_spawn(
                                &pid,
                                executable,
                                &fileActions,
                                &attributes,
                                arguments,
                                environment
                            )
                        }
                    }
                }
                try requirePOSIXSuccess(spawnResult, operation: .launch)

                close(stdoutPipe.writeFileDescriptor)
                close(stderrPipe.writeFileDescriptor)
                return SpawnedProcess(
                    pid: pid,
                    processGroup: pid,
                    stdoutFileDescriptor: stdoutPipe.readFileDescriptor,
                    stderrFileDescriptor: stderrPipe.readFileDescriptor
                )
            } catch {
                closePipe(stdoutPipe)
                closePipe(stderrPipe)
                throw error
            }
        }

        private func configure(
            _ actions: inout posix_spawn_file_actions_t?,
            stdoutPipe: ProcessPipe,
            stderrPipe: ProcessPipe
        ) throws {
            let operations: [(Int32, Operation)] = [
                (posix_spawn_file_actions_adddup2(&actions, stdoutPipe.writeFileDescriptor, STDOUT_FILENO), .stdoutRedirect),
                (posix_spawn_file_actions_adddup2(&actions, stderrPipe.writeFileDescriptor, STDERR_FILENO), .stderrRedirect),
                (posix_spawn_file_actions_addclose(&actions, stdoutPipe.readFileDescriptor), .stdoutReadClose),
                (posix_spawn_file_actions_addclose(&actions, stderrPipe.readFileDescriptor), .stderrReadClose),
                (posix_spawn_file_actions_addclose(&actions, stdoutPipe.writeFileDescriptor), .stdoutWriteClose),
                (posix_spawn_file_actions_addclose(&actions, stderrPipe.writeFileDescriptor), .stderrWriteClose),
            ]
            for (result, operation) in operations {
                try requirePOSIXSuccess(result, operation: operation)
            }
        }

        private func makePipe() throws -> ProcessPipe {
            var fileDescriptors = [Int32](repeating: -1, count: 2)
            guard pipe(&fileDescriptors) == 0 else {
                throw LaunchError(operation: .pipeCreation, code: errno)
            }
            return ProcessPipe(
                readFileDescriptor: fileDescriptors[0],
                writeFileDescriptor: fileDescriptors[1]
            )
        }

        private func setNonblocking(_ fileDescriptor: Int32) throws {
            let flags = fcntl(fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw LaunchError(operation: .nonblockingPipeConfiguration, code: errno)
            }
        }

        private func closePipe(_ pipe: ProcessPipe) {
            close(pipe.readFileDescriptor)
            close(pipe.writeFileDescriptor)
        }

        private func requirePOSIXSuccess(
            _ result: Int32,
            operation: Operation
        ) throws {
            guard result == 0 else {
                throw LaunchError(operation: operation, code: result)
            }
        }

        private func withCStringArray<Result>(
            _ strings: [String],
            body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
        ) -> Result {
            var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
            pointers.append(nil)
            defer {
                for pointer in pointers {
                    free(pointer)
                }
            }
            return pointers.withUnsafeMutableBufferPointer { buffer in
                body(buffer.baseAddress!)
            }
        }
    }

    private struct SpawnedProcess {
        let pid: pid_t
        let processGroup: pid_t
        let stdoutFileDescriptor: Int32
        let stderrFileDescriptor: Int32
    }

    private struct ProcessPipe {
        let readFileDescriptor: Int32
        let writeFileDescriptor: Int32
    }

    private enum SelectedTerminal: Sendable {
        case reapedTermination(ChildTermination)
        case timedOut
        case cancelled
        case outputLimitExceeded(OutputStream)

        var reapedTermination: ChildTermination? {
            switch self {
            case .reapedTermination(let termination):
                termination
            case .timedOut, .cancelled, .outputLimitExceeded:
                nil
            }
        }

        func selectedAfterOutputDrain(
            stdoutExceededLimit: Bool,
            stderrExceededLimit: Bool
        ) -> Self {
            switch self {
            case .timedOut, .cancelled:
                self
            case .reapedTermination, .outputLimitExceeded:
                if stdoutExceededLimit {
                    .outputLimitExceeded(.stdout)
                } else if stderrExceededLimit {
                    .outputLimitExceeded(.stderr)
                } else {
                    self
                }
            }
        }

        func outcome(output: Output) -> Outcome {
            switch self {
            case .reapedTermination(let termination):
                switch termination {
                case .exited(0):
                    return .succeeded(output)
                case .exited(let code):
                    return .nonzeroExit(code: code, output: output)
                case .signaled(let signal):
                    return .signaled(signal: signal, output: output)
                }
            case .timedOut:
                return .timedOut(output)
            case .cancelled:
                return .cancelled
            case .outputLimitExceeded(let stream):
                return .outputLimitExceeded(stream: stream, output: output)
            }
        }
    }

    private enum ChildTermination: Sendable {
        case exited(Int32)
        case signaled(Int32)

        init(status: Int32) {
            let signal = status & 0x7f
            if signal == 0 {
                self = .exited((status >> 8) & 0xff)
            } else {
                self = .signaled(signal)
            }
        }
    }

    private struct CapturedStream: Sendable {
        let data: Data
        let exceededLimit: Bool
    }

    private actor OutputDrain {
        private let fileDescriptor: Int32
        private let capturedByteLimit: Int
        private let pollInterval: Duration
        private var shouldStop = false
        private(set) var exceededLimit = false

        init(
            fileDescriptor: Int32,
            capturedByteLimit: Int,
            pollInterval: Duration
        ) {
            self.fileDescriptor = fileDescriptor
            self.capturedByteLimit = capturedByteLimit
            self.pollInterval = pollInterval
        }

        func start() -> Task<CapturedStream, Never> {
            Task(priority: .utility) { [self] in
                defer { close(fileDescriptor) }
                var captured = Data()
                var buffer = [UInt8](repeating: 0, count: 16_384)
                var readsAfterStop = 0

                while true {
                    let count = buffer.withUnsafeMutableBytes {
                        read(fileDescriptor, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        let remainingCapacity = max(0, capturedByteLimit - captured.count)
                        let capturedCount = min(count, remainingCapacity)
                        if capturedCount > 0 {
                            captured.append(contentsOf: buffer.prefix(capturedCount))
                        }
                        if capturedCount < count {
                            exceededLimit = true
                        }
                        await Task.yield()
                        if shouldStop {
                            readsAfterStop += 1
                            if readsAfterStop == 64 {
                                return CapturedStream(data: captured, exceededLimit: exceededLimit)
                            }
                        }
                        continue
                    }
                    if count == 0 {
                        return CapturedStream(data: captured, exceededLimit: exceededLimit)
                    }
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        if shouldStop {
                            return CapturedStream(data: captured, exceededLimit: exceededLimit)
                        }
                        try? await Task.sleep(for: pollInterval)
                        continue
                    }
                    return CapturedStream(data: captured, exceededLimit: exceededLimit)
                }
            }
        }

        func stop() {
            shouldStop = true
        }
    }
#endif
}
