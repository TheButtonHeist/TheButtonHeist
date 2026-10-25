import ButtonHeistTestSupport
import Testing
import ThePlans
import TheScore
@testable import ButtonHeist

@Suite(.serialized)
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

    @Test func `cancelling an outstanding operation disconnects the scoped connection`() async throws {
        let (heist, connection) = makeConnectedFence(configuration: .init(autoReconnect: false))
        let sent = AsyncStream<Void>.makeStream()
        connection.responseScript = { _ in sent.continuation.yield(()); return nil }
        let task = Task {
            defer { sent.continuation.finish() }
            return try await withSession(heist) { heist in
                try await heist.captureInterface()
            }
        }
        defer { task.cancel(); sent.continuation.finish() }
        for await _ in sent.stream { break }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!connection.isConnected)
        #expect(connection.disconnectCount == 1)
    }
}

private enum ClientTestFailure: Error {
    case requested
}
