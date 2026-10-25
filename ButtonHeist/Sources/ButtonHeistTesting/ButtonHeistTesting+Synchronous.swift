#if canImport(UIKit)
#if DEBUG
import Foundation
import os

import TheInsideJob
import ThePlans

/// XCTest-facing result recording policy for synchronous heist helpers.
///
/// Use `.always` when a passing run should retain evidence of the exact interface
/// it matched. This is useful in app-hosted test processes where environment
/// variables such as `BUTTONHEIST_RESULTS_MODE` and `BUTTONHEIST_RESULTS_DIR`
/// may not be inherited from the test runner.
public enum HeistTestResultRecording: Sendable, Equatable {
    /// Use the normal `BUTTONHEIST_RESULTS_MODE` / `BUTTONHEIST_RESULTS_DIR`
    /// environment-variable behavior.
    case environment
    /// Do not record this heist result, even when ambient recording is enabled.
    case off
    /// Write only failed heist results to the supplied directory.
    case failures
    /// Write failed and passing heist results to the supplied directory.
    case always

    fileprivate var explicitRecorderMode: HeistResultRecordingMode? {
        switch self {
        case .environment, .off:
            return nil
        case .failures:
            return .failures
        case .always:
            return .all
        }
    }

    fileprivate var usesEnvironment: Bool {
        self == .environment
    }
}

/// Synchronously runs an in-process heist from a plain XCTest method.
///
/// This helper intentionally keeps the XCTest method synchronous and pumps the
/// current run loop while the heist runs on the main actor. In app-hosted
/// XCTest/KIF-style targets, converting these tests to `async` can expose an
/// XCTest async-task teardown crash at process exit, especially when the app is
/// also doing background cleanup. Keep the test method synchronous unless the
/// host target has proven its async teardown path is safe.
///
/// On failure, this records an `XCTFail` at the call site and returns `nil`.
/// The failure message includes the heist failure description, including the
/// settled interface dump when one is available.
///
/// The asynchronous run is bounded by `timeout`. Reaching that bound cancels
/// and releases the owned task, records an `XCTFail` at the call site, and
/// returns `nil`. Invalid bounds fail closed as an immediate timeout.
@discardableResult
public func runHeistSync(
    _ path: HeistDefinitionPath,
    timeout: HeistTimeout = .default,
    recordResult: HeistTestResultRecording = .environment,
    to resultDirectory: URL? = nil,
    file: StaticString = #filePath,
    line: UInt = #line,
    @HeistBuilder _ content: @escaping () throws -> HeistContent
) -> Heist? {
    runHeistSynchronously(
        prepareCommand: { try HeistRunCommand(path, content) },
        timeout: timeout,
        recordResult: recordResult,
        resultDirectory: resultDirectory,
        file: file,
        line: line
    )
}

/// Synchronously runs a string-argument heist from a plain XCTest method.
@discardableResult
public func runHeistSync(
    _ path: HeistDefinitionPath,
    argument input: String,
    parameter: HeistReferenceName = "input",
    timeout: HeistTimeout = .default,
    recordResult: HeistTestResultRecording = .environment,
    to resultDirectory: URL? = nil,
    file: StaticString = #filePath,
    line: UInt = #line,
    @HeistBuilder _ content: @escaping (HeistReferenceName) throws -> HeistContent
) -> Heist? {
    runHeistSynchronously(
        prepareCommand: {
            try HeistRunCommand(path, argument: input, parameter: parameter, content)
        },
        timeout: timeout,
        recordResult: recordResult,
        resultDirectory: resultDirectory,
        file: file,
        line: line
    )
}

/// Synchronously runs an accessibility-target heist from a plain XCTest method.
@_disfavoredOverload
@discardableResult
public func runHeistSync(
    _ path: HeistDefinitionPath,
    argument input: AccessibilityTarget,
    parameter: HeistReferenceName = "input",
    timeout: HeistTimeout = .default,
    recordResult: HeistTestResultRecording = .environment,
    to resultDirectory: URL? = nil,
    file: StaticString = #filePath,
    line: UInt = #line,
    @HeistBuilder _ content: @escaping (AccessibilityTarget) throws -> HeistContent
) -> Heist? {
    runHeistSynchronously(
        prepareCommand: {
            try HeistRunCommand(path, argument: input, parameter: parameter, content)
        },
        timeout: timeout,
        recordResult: recordResult,
        resultDirectory: resultDirectory,
        file: file,
        line: line
    )
}

private func runHeistSynchronously(
    prepareCommand: () throws -> HeistRunCommand,
    timeout: HeistTimeout,
    recordResult: HeistTestResultRecording,
    resultDirectory: URL?,
    file: StaticString,
    line: UInt
) -> Heist? {
    let command: HeistRunCommand
    do {
        command = try prepareCommand()
    } catch {
        recordHeistXCTestIssue(.commandPreparationFailed(error), file: file, line: line)
        return nil
    }

    guard Thread.isMainThread else {
        recordHeistXCTestIssue(
            .synchronousHeistRequiresMainThread,
            file: file,
            line: line
        )
        return nil
    }

    return runHeistSyncOperation(
        timeout: timeout.seconds + heistResultDeliveryHeadroomSeconds,
        file: file,
        line: line
    ) { @MainActor in
        try await HeistResultRecording.withEnvironmentRecording(recordResult.usesEnvironment) {
            do {
                let heist = try await Heist(
                    command.plan,
                    argument: command.argument,
                    timeout: timeout
                )
                try await recordResultIfRequested(
                    heist.result,
                    plan: command.plan,
                    policy: recordResult,
                    resultDirectory: resultDirectory
                )
                return heist
            } catch let failure as Heist.Failure {
                do {
                    try await recordResultIfRequested(
                        failure.result,
                        plan: command.plan,
                        policy: recordResult,
                        resultDirectory: resultDirectory
                    )
                } catch {
                    throw HeistXCTestFailure(
                        primaryError: failure,
                        resultRecordingError: error
                    )
                }
                throw failure
            }
        }
    }
}

private let heistResultDeliveryHeadroomSeconds: TimeInterval = 5

@discardableResult
func runHeistSyncOperation<Value: Sendable>(
    timeout: TimeInterval = 60,
    file: StaticString = #filePath,
    line: UInt = #line,
    waitControl: HeistSyncWaitControl = .mainRunLoop,
    _ operation: @escaping @Sendable () async throws -> Value
) -> Value? {
    guard Thread.isMainThread else {
        recordHeistXCTestIssue(
            .synchronousOperationRequiresMainThread,
            file: file,
            line: line
        )
        return nil
    }

    let state = HeistSyncState<Value>()
    let task = Task {
        do {
            state.finish(.success(try await operation()))
        } catch {
            state.finish(.failure(error))
        }
    }
    state.attach(task)

    return waitForSynchronousResult(
        state,
        timeout: timeout,
        waitControl: waitControl,
        file: file,
        line: line
    )
}

func waitForSynchronousResult<Value: Sendable>(
    _ state: HeistSyncState<Value>,
    timeout: TimeInterval,
    waitControl: HeistSyncWaitControl,
    file: StaticString,
    line: UInt
) -> Value? {
    let boundedTimeout = timeout.isFinite && timeout > 0 ? timeout : 0
    let deadline = waitControl.now() + boundedTimeout

    while true {
        switch state.status {
        case .running:
            let remaining = deadline - waitControl.now()
            guard remaining > 0 else {
                return resolveHeistSyncDeadline(
                    state.resolveDeadline(),
                    timeout: boundedTimeout,
                    file: file,
                    line: line
                )
            }
            waitControl.wait(min(remaining, 0.05))
        case .completed(let result):
            return resolveHeistSyncResult(result, file: file, line: line)
        case .timedOut:
            recordHeistXCTestIssue(.operationTimedOut(boundedTimeout), file: file, line: line)
            return nil
        }
    }
}

private func resolveHeistSyncResult<Value>(
    _ result: Result<Value, Error>,
    file: StaticString,
    line: UInt
) -> Value? {
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        recordHeistXCTestIssue(.operationFailed(error), file: file, line: line)
        return nil
    }
}

private func resolveHeistSyncDeadline<Value>(
    _ resolution: HeistSyncDeadlineResolution<Value>,
    timeout: TimeInterval,
    file: StaticString,
    line: UInt
) -> Value? {
    switch resolution {
    case .completed(let result):
        return resolveHeistSyncResult(result, file: file, line: line)
    case .timedOut(let task):
        task?.cancel()
        recordHeistXCTestIssue(.operationTimedOut(timeout), file: file, line: line)
        return nil
    }
}

private func recordResultIfRequested(
    _ result: HeistResult,
    plan: HeistPlan,
    policy: HeistTestResultRecording,
    resultDirectory: URL?
) async throws {
    guard let mode = policy.explicitRecorderMode else { return }
    let rootDirectory = resultDirectory ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("buttonheist-results", isDirectory: true)
    _ = try await HeistResultRecording.write(
        result,
        plan: plan,
        configuration: HeistResultRecordingConfiguration(
            rootDirectory: rootDirectory,
            mode: mode
        )
    )
}

struct HeistSyncWaitControl {
    let now: () -> TimeInterval
    let wait: (_ maximumInterval: TimeInterval) -> Void

    static var mainRunLoop: Self {
        HeistSyncWaitControl(
            now: { ProcessInfo.processInfo.systemUptime },
            wait: { maximumInterval in
                _ = RunLoop.current.run(
                    mode: .default,
                    before: Date(timeIntervalSinceNow: maximumInterval)
                )
            }
        )
    }
}

enum HeistSyncStatus<Value: Sendable>: Sendable {
    case running
    case completed(Result<Value, Error>)
    case timedOut
}

enum HeistSyncDeadlineResolution<Value: Sendable>: Sendable {
    case completed(Result<Value, Error>)
    case timedOut(Task<Void, Never>?)
}

final class HeistSyncState<Value: Sendable>: Sendable {
    private enum State: Sendable {
        case starting
        case running(Task<Void, Never>)
        case completed(Result<Value, Error>)
        case timedOut
    }

    private let state = OSAllocatedUnfairLock(initialState: State.starting)

    var status: HeistSyncStatus<Value> {
        state.withLock { current in
            switch current {
            case .starting, .running:
                return .running
            case .completed(let result):
                return .completed(result)
            case .timedOut:
                return .timedOut
            }
        }
    }

    var ownsTask: Bool {
        state.withLock { current in
            guard case .running = current else { return false }
            return true
        }
    }

    func finish(_ result: Result<Value, Error>) {
        state.withLock { current in
            switch current {
            case .starting, .running:
                current = .completed(result)
            case .completed, .timedOut:
                break
            }
        }
    }

    func attach(_ task: Task<Void, Never>) {
        state.withLock { current in
            switch current {
            case .starting:
                current = .running(task)
            case .running:
                preconditionFailure("HeistSyncState can own only one task")
            case .completed:
                break
            case .timedOut:
                task.cancel()
            }
        }
    }

    func resolveDeadline() -> HeistSyncDeadlineResolution<Value> {
        state.withLock { current in
            switch current {
            case .starting:
                current = .timedOut
                return .timedOut(nil)
            case .running(let task):
                current = .timedOut
                return .timedOut(task)
            case .completed(let result):
                return .completed(result)
            case .timedOut:
                return .timedOut(nil)
            }
        }
    }
}

private struct HeistXCTestFailure: Error, CustomStringConvertible {
    let primaryError: Error
    let resultRecordingError: Error

    var description: String {
        "\(primaryError)\nresult recording failed: \(resultRecordingError)"
    }
}
#endif // DEBUG
#endif // canImport(UIKit)
