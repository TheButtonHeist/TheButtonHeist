#if canImport(Network)
import Foundation
import Network
import os

import ButtonHeistTestSupport
import TheScore
@testable import TheInsideJob

/// `@unchecked Sendable` justification: the test client is used from async
/// continuations while teardown may cancel it; `NWConnection` is thread-safe for
/// these operations, `start` is guarded by `started`, and line buffering has its
/// own lock.
final class ButtonHeistNetworkTestClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lineBuffer = TestWireLineBuffer()
    private let started = OSAllocatedUnfairLock(initialState: false)

    init(
        port: UInt16,
        parameters: NWParameters,
        host: NWEndpoint.Host = .ipv6(.loopback),
        queueLabel: String = "com.buttonheist.tests.network-client"
    ) {
        self.connection = NWConnection(
            host: host,
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        self.queue = DispatchQueue(label: queueLabel)
    }

    static func plaintext(
        port: UInt16,
        host: NWEndpoint.Host = .ipv6(.loopback)
    ) -> ButtonHeistNetworkTestClient {
        ButtonHeistNetworkTestClient(port: port, parameters: .tcp, host: host)
    }

    static func tls(
        port: UInt16,
        token: String,
        host: NWEndpoint.Host = .ipv6(.loopback)
    ) -> ButtonHeistNetworkTestClient {
        ButtonHeistNetworkTestClient(
            port: port,
            parameters: ButtonHeistTLSPreSharedKey.networkParameters(from: token),
            host: host
        )
    }

    func connect(timeout: TimeInterval = 5.0) async throws {
        try await TestNetworkTimeout.run(seconds: timeout) { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = TestOneShotVoidContinuation(continuation)
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.resume()
                    case .failed(let error):
                        once.resume(throwing: error)
                    case .cancelled:
                        once.resume(throwing: ButtonHeistNetworkTestFailure("Connection cancelled before ready"))
                    default:
                        break
                    }
                }
                self.startIfNeeded()
            }
        }
    }

    func connectExpectingRejection(timeout: TimeInterval = 5.0) async throws {
        try await TestNetworkTimeout.run(seconds: timeout) { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = TestOneShotVoidContinuation(continuation)
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .waiting, .failed, .cancelled:
                        once.resume()
                    case .ready:
                        once.resume(throwing: ButtonHeistNetworkTestFailure("Connection reached ready unexpectedly"))
                    default:
                        break
                    }
                }
                self.startIfNeeded()
            }
        }
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ data: Data, timeout: TimeInterval = 5.0) async throws {
        try await TestNetworkTimeout.run(seconds: timeout) { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                })
            }
        }
    }

    func sendLine(_ line: String, timeout: TimeInterval = 5.0) async throws {
        try await send(Data((line + "\n").utf8), timeout: timeout)
    }

    func receiveData(timeout: TimeInterval = 5.0) async throws -> Data {
        try await TestNetworkTimeout.run(seconds: timeout) { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                self.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if isComplete {
                        continuation.resume(throwing: ButtonHeistNetworkTestFailure("Connection closed"))
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        }
    }

    func receiveLine(timeout: TimeInterval = 5.0) async throws -> Data {
        while true {
            if let line = lineBuffer.popLine() {
                return line
            }
            let chunk = try await receiveData(timeout: timeout)
            lineBuffer.append(chunk)
        }
    }

    private func startIfNeeded() {
        let shouldStart = started.withLock { started -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        connection.start(queue: queue)
    }
}

/// `@unchecked Sendable` justification: this wrapper has immutable configuration
/// and delegates all mutable network state to `ButtonHeistNetworkTestClient`.
final class ButtonHeistWireTestClient: @unchecked Sendable {
    private let token: String
    private let networkClient: ButtonHeistNetworkTestClient

    init(
        token: String,
        port: UInt16,
        host: NWEndpoint.Host = .ipv6(.loopback)
    ) {
        self.token = token
        self.networkClient = .tls(port: port, token: token, host: host)
    }

    func connect(timeout: TimeInterval = 5.0) async throws {
        try await networkClient.connect(timeout: timeout)
    }

    func cancel() {
        networkClient.cancel()
    }

    func send(_ message: ClientMessage, requestId: RequestID? = nil, timeout: TimeInterval = 5.0) async throws {
        var encoded = try JSONEncoder().encode(RequestEnvelope(
            requestId: requestId,
            message: message
        ))
        encoded.append(0x0A)
        try await networkClient.send(encoded, timeout: timeout)
    }

    func authenticate(driverId: String = "buttonheist-test-client") async throws -> ServerInfo {
        guard case .serverHello = try await receiveEnvelope().message else {
            throw ButtonHeistNetworkTestFailure("Expected serverHello")
        }

        try await send(.clientHello)
        guard case .authRequired = try await receiveEnvelope().message else {
            throw ButtonHeistNetworkTestFailure("Expected authRequired")
        }

        try await send(.authenticate(AuthenticatePayload(
            token: try SessionAuthToken(validating: token),
            driverId: try DriverID(validating: driverId)
        )))
        let envelope = try await receiveEnvelope()
        guard case .info(let info) = envelope.message else {
            throw ButtonHeistNetworkTestFailure("Expected info after authentication")
        }
        return info
    }

    func requestInterface(requestId: RequestID = .fixture("interface")) async throws -> Interface {
        try await send(.requestInterface(InterfaceQuery()), requestId: requestId)
        let envelope = try await receiveEnvelope(requestId: requestId)
        guard case .interface(let interface) = envelope.message else {
            throw ButtonHeistNetworkTestFailure("Expected interface response")
        }
        return interface
    }

    func receiveEnvelope(
        requestId: RequestID? = nil,
        timeout: TimeInterval = 5.0
    ) async throws -> ResponseEnvelope {
        for _ in 0..<10 {
            let line = try await networkClient.receiveLine(timeout: timeout)
            let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: line)
            guard let requestId else {
                return envelope
            }
            if envelope.requestId == requestId {
                return envelope
            }
        }
        throw ButtonHeistNetworkTestFailure(
            "Timed out waiting for response \(requestId?.description ?? "<none>")"
        )
    }
}

struct ButtonHeistNetworkTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

enum TestNetworkTimeout {
    static func run<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                // Group-race timeout against real network I/O; needs wall-clock.
                // swiftlint:disable:next agent_test_task_sleep
                try await Task.sleep(for: .seconds(seconds))
                throw ButtonHeistNetworkTestFailure("Timed out after \(seconds)s")
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

/// `@unchecked Sendable` justification: the accumulated bytes are protected by
/// `lock` and only accessed through `append` / `popLine`.
private final class TestWireLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(chunk)
    }

    func popLine() -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard let newlineIndex = storage.firstIndex(of: 0x0A) else {
            return nil
        }
        let line = storage[..<newlineIndex]
        storage.removeSubrange(storage.startIndex...newlineIndex)
        return Data(line)
    }
}

/// `@unchecked Sendable` justification: network state callbacks can race, so the
/// optional continuation is consumed exactly once under `lock`.
private final class TestOneShotVoidContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        resume { $0.resume(returning: ()) }
    }

    func resume(throwing error: Error) {
        resume { $0.resume(throwing: error) }
    }

    private func resume(_ body: (CheckedContinuation<Void, Error>) -> Void) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        body(continuation)
    }
}
#endif
