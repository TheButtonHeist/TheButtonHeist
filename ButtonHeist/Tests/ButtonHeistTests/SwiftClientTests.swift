import ButtonHeistTestSupport
import Testing
import ThePlans
import TheScore
@testable import ButtonHeist

@Suite(.serialized, .timeLimit(.minutes(1)))
@ButtonHeistActor
struct SwiftClientTests {
    @Test func `one scoped connection serves plans and interface captures`() async throws {
        let (heist, connection) = makeConnectedFence(configuration: .init(autoReconnect: false))
        let interface = makeTestInterface(elements: [makeTestHeistElement(label: "Record")])
        let expected = HeistResultFixture.result(steps: [HeistResultFixture.action()], durationMs: 137)
        connection.responseScript = { message in
            switch message {
            case .requestInterface: .interface(interface)
            case .heistPlan: .heistResult(expected)
            default: nil
            }
        }

        let result = try await withSession(heist) { heist in
            #expect(try await heist.captureInterface() == interface)
            let result = try await heist.run(timeout: 12) {
                oneFingerTap(.label("Record"))
            }
            #expect(try await heist.captureInterface() == interface)
            #expect(connection.connectCount == 1)
            return result
        }

        let captureModes = connection.sent.compactMap { message, _ -> InterfaceQuery.Mode? in
            guard case .requestInterface(let query) = message else { return nil }
            return query.mode
        }
        #expect(captureModes == [.current, .current])
        #expect(result == expected)
        #expect(connection.sent.sentHeistActionCommands == [.oneFingerTap(TapTarget(selection: .element(.label("Record"))))])
        #expect(connection.sent.sentHeistRun?.timeout == 12)
        #expect(connection.disconnectCount == 1)
        #expect(!connection.isConnected)
    }

    @Test func `prebuilt plans preserve root arguments and failed execution evidence`() async throws {
        let (heist, connection) = makeConnectedFence(configuration: .init(autoReconnect: false))
        let plan = try HeistPlan(parameter: "name") { name in
            TypeText(name, into: .label("Name"))
        }
        let expected = HeistResultFixture.result(steps: [
            HeistResultFixture.explicitFailure(message: "missing Name field"),
        ], durationMs: 241)
        connection.responseScript = { _ in .heistResult(expected) }

        let result = try await withSession(heist) { heist in
            try await heist.run(plan, argument: .string("Retake"), timeout: 9)
        }

        #expect(result == expected)
        #expect(connection.sent.sentHeistPlan == plan)
        #expect(connection.sent.sentHeistRun?.argument == .string("Retake"))
        #expect(connection.sent.sentHeistRun?.timeout == 9)
    }

    @Test func `invalid root arguments fail before sending commands`() async throws {
        let (heist, connection) = makeConnectedFence(configuration: .init(autoReconnect: false))
        let plan = try HeistPlan(parameter: "name") { name in
            TypeText(name, into: .label("Name"))
        }

        await #expect(throws: HeistPlanBuildError.self) {
            try await heist.run(plan)
        }

        #expect(connection.sent.isEmpty)
        #expect(connection.connectCount == 0)
    }

    @Test func `a throwing plan builder fails before connecting`() async {
        let (heist, connection) = makeConnectedFence()

        await #expect(throws: ClientTestFailure.requested) {
            try await heist.run { throw ClientTestFailure.requested }
        }

        #expect(connection.connectCount == 0)
        #expect(connection.sent.isEmpty)
    }

    @Test func `interface query reaches the same transport without projection`() async throws {
        let (heist, connection) = makeConnectedFence(configuration: .init(autoReconnect: false))
        let query = InterfaceQuery(subtree: .label("Editor"), maxScrollsPerContainer: 2, maxScrollsPerDiscovery: 4)
        _ = try await withSession(heist) { heist in
            try await heist.captureInterface(query, timeout: 3)
        }

        let queries = connection.sent.compactMap { message, _ -> InterfaceQuery? in
            guard case .requestInterface(let query) = message else { return nil }
            return query
        }
        #expect(queries == [query])
    }

    @Test func `scope disconnects when its operation throws`() async throws {
        let (heist, connection) = makeConnectedFence(configuration: .init(autoReconnect: false))

        await #expect(throws: ClientTestFailure.requested) {
            try await withSession(heist) { _ in throw ClientTestFailure.requested }
        }

        #expect(connection.disconnectCount == 1)
        #expect(!connection.isConnected)
    }

    @Test func `scope cleans up a failed connection without running its operation`() async throws {
        let (heist, connection) = makeConnectedFence(configuration: .init(autoReconnect: false))
        connection.connectEventsOverride = [.disconnected(.localDisconnect)]
        var entered = false

        await #expect(throws: (any Error).self) {
            try await withSession(heist) { _ in entered = true }
        }

        #expect(!entered)
        #expect(!heist.handoff.connectionLifecycle.isConnected)
        #expect(!heist.handoff.discovery.isActive)
    }

    @Test func `an already cancelled scope never connects or enters its operation`() async {
        let (heist, connection) = makeConnectedFence()
        var entered = false
        let task = Task {
            try await withSession(heist) { _ in entered = true }
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!entered)
        #expect(connection.connectCount == 0)
        #expect(!heist.handoff.discovery.isActive)
    }

    @Test func `cancelling connection setup closes the transport before entering the scope`() async {
        let (heist, connection) = makeConnectedFence()
        connection.connectEventsOverride = []
        let connecting = AsyncStream<Void>.makeStream()
        heist.handoff.makeConnection = { _ in
            connecting.continuation.yield(())
            return connection
        }
        var entered = false
        let task = Task {
            defer { connecting.continuation.finish() }
            try await withSession(heist) { _ in entered = true }
        }
        defer { task.cancel(); connecting.continuation.finish() }
        for await _ in connecting.stream { break }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!entered)
        #expect(connection.disconnectCount == 1)
        #expect(!heist.handoff.discovery.isActive)
    }

    @Test(arguments: [
        DisconnectReason.missingToken,
        .authFailed("bad token"),
        .sessionLocked("another driver owns the app"),
        .buttonHeistVersionMismatch(serverVersion: "0.0.0", clientVersion: buttonHeistVersion),
    ])
    func `connection rejection preserves its diagnostic and never enters the scope`(_ reason: DisconnectReason) async {
        let (heist, connection) = makeConnectedFence()
        connection.connectEventsOverride = [.disconnected(reason)]
        var entered = false

        do {
            try await withSession(heist) { _ in entered = true }
            Issue.record("Expected connection rejection")
        } catch let error as FenceError {
            #expect(error.diagnosticFailure.details == reason.failureDetails)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(!entered)
        #expect(connection.sent.isEmpty)
        #expect(!heist.handoff.connectionLifecycle.isConnected)
        #expect(!heist.handoff.discovery.isActive)
    }

    @Test(arguments: Operation.allCases)
    func `server errors preserve their payload and the scope disconnects`(_ operation: Operation) async {
        let (heist, connection) = makeConnectedFence()
        let expected = ServerError(kind: .validationError, message: "invalid target")
        connection.responseScript = { _ in .error(expected) }

        do {
            try await withSession(heist) { try await operation.execute(on: $0) }
            Issue.record("Expected the server error to throw")
        } catch FenceError.serverError(let received) {
            #expect(received == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(connection.disconnectCount == 1)
    }

    @Test(arguments: Operation.allCases)
    func `an unexpected reply throws a protocol error and disconnects`(_ operation: Operation) async {
        let (heist, connection) = makeConnectedFence()
        connection.responseScript = { _ in .actionResult(.success(payload: .activate)) }

        do {
            try await withSession(heist) { try await operation.execute(on: $0) }
            Issue.record("Expected a protocol error")
        } catch let error as FenceError {
            #expect(error.diagnosticFailure.details == FailureDetails(code: .protocolMismatch))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(connection.disconnectCount == 1)
    }

    @Test(arguments: Operation.allCases, [DeviceSendOutcome.enqueued, .failed(.notConnected)])
    func `immediate and queued send failures throw and disconnect`(_ operation: Operation, _ outcome: DeviceSendOutcome) async {
        let (heist, connection) = makeConnectedFence()
        connection.responseScript = nil
        connection.sendOutcome = outcome
        connection.asyncSendFailure = .notConnected

        do {
            try await withSession(heist) { try await operation.execute(on: $0) }
            Issue.record("Expected send failure")
        } catch FenceError.notConnected {
            #expect(connection.disconnectCount == 1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: Operation.allCases)
    func `a dropped transport fails the pending operation and stops discovery`(_ operation: Operation) async {
        let (heist, connection) = makeConnectedFence(configuration: .init(autoReconnect: false))
        connection.responseScript = { _ in
            Task {
                connection.isConnected = false
                connection.onEvent?(.disconnected(.serverClosed))
            }
            return nil
        }

        do {
            try await withSession(heist) { try await operation.execute(on: $0) }
            Issue.record("Expected transport disconnect")
        } catch let error as FenceError {
            #expect(error.diagnosticFailure.details == FailureDetails(code: .transportServerClosed))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(!heist.handoff.connectionLifecycle.isConnected)
        #expect(!heist.handoff.discovery.isActive)
    }

    @Test(arguments: Operation.allCases)
    func `an expired response deadline throws and disconnects`(_ operation: Operation) async throws {
        let (heist, connection) = makeConnectedFence(configuration: .init(postActionExpectationTimeoutBuffer: 0))
        connection.responseScript = nil
        // This positive timeout projects to zero scheduler ticks, without a wall-clock delay.
        let timeout = try HeistTimeout(validatingSeconds: .leastNonzeroMagnitude)

        do {
            try await withSession(heist) { try await operation.execute(on: $0, timeout: timeout) }
            Issue.record("Expected response timeout")
        } catch FenceError.actionTimeout {
            #expect(connection.disconnectCount == 1)
        }
    }

    @Test(arguments: Operation.allCases)
    func `cancelling either public operation releases its scoped connection`(_ operation: Operation) async {
        let (heist, connection) = makeConnectedFence()
        let sent = AsyncStream<Void>.makeStream()
        connection.responseScript = { _ in sent.continuation.yield(()); return nil }
        let task = Task {
            defer { sent.continuation.finish() }
            try await withSession(heist) { try await operation.execute(on: $0) }
        }
        defer { task.cancel(); sent.continuation.finish() }
        for await _ in sent.stream { break }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(connection.disconnectCount == 1)
        #expect(!heist.handoff.discovery.isActive)
    }

    @Test func `overlapping captures match replies by request identity`() async throws {
        let (heist, connection) = makeConnectedFence()
        let sent = AsyncStream<Void>.makeStream()
        defer { sent.continuation.finish() }
        connection.responseScript = { _ in sent.continuation.yield(()); return nil }
        let first = makeTestInterface(elements: [makeTestHeistElement(label: "First")])
        let second = makeTestInterface(elements: [makeTestHeistElement(label: "Second")])

        try await withSession(heist) { heist in
            let firstTask = Task { try await heist.captureInterface() }
            defer { firstTask.cancel() }
            var arrivals = sent.stream.makeAsyncIterator()
            _ = await arrivals.next()
            let firstID = try #require(connection.sent.last?.1)
            let secondTask = Task { try await heist.captureInterface() }
            defer { secondTask.cancel() }
            _ = await arrivals.next()
            let secondID = try #require(connection.sent.last?.1)

            connection.onEvent?(.message(.interface(second), requestId: secondID))
            connection.onEvent?(.message(.interface(first), requestId: firstID))

            #expect(try await firstTask.value == first)
            #expect(try await secondTask.value == second)
            #expect(connection.connectCount == 1)
        }
        #expect(connection.disconnectCount == 1)
    }

    enum Operation: CaseIterable {
        case run
        case capture

        @ButtonHeistActor
        func execute(on heist: TheFence, timeout: HeistTimeout = .default) async throws {
            switch self {
            case .run:
                _ = try await heist.run(timeout: timeout) { Warn("client contract") }
            case .capture:
                _ = try await heist.captureInterface(timeout: timeout)
            }
        }
    }
}

private enum ClientTestFailure: Error {
    case requested
}
