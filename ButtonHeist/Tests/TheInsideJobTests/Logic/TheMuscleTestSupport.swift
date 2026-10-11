#if canImport(UIKit)
import XCTest
import TheScore
@testable import TheInsideJob

private final class TheMuscleCallbackSink: @unchecked Sendable {
    private var sentMessagesStorage: [(data: Data, clientId: Int)] = []
    private var disconnectedClientsStorage: [Int] = []
    private var authenticatedCallbacksStorage: [(clientId: Int, respond: SocketResponseHandler)] = []
    private let lock = NSLock()

    var sentMessages: [(data: Data, clientId: Int)] { lock.withLock { sentMessagesStorage } }
    var disconnectedClients: [Int] { lock.withLock { disconnectedClientsStorage } }
    var authenticatedCallbacks: [(clientId: Int, respond: SocketResponseHandler)] {
        lock.withLock { authenticatedCallbacksStorage }
    }

    func appendSent(_ entry: (Data, Int)) { lock.withLock { sentMessagesStorage.append(entry) } }
    func appendDisconnected(_ clientId: Int) { lock.withLock { disconnectedClientsStorage.append(clientId) } }
    func appendAuthenticatedCallback(_ entry: (Int, SocketResponseHandler)) {
        lock.withLock { authenticatedCallbacksStorage.append(entry) }
    }
}

@MainActor
class TheMuscleTestCase: XCTestCase {
    var muscle: TheMuscle!

    private var sink: TheMuscleCallbackSink!
    private(set) var delivery: ClientDelivery!

    var sentMessages: [(data: Data, clientId: Int)] { sink.sentMessages }
    var disconnectedClients: [Int] { sink.disconnectedClients }
    var authenticatedCallbacks: [(clientId: Int, respond: SocketResponseHandler)] {
        sink.authenticatedCallbacks
    }

    override func setUp() async throws {
        try await super.setUp()
        muscle = makeMuscle()
        sink = TheMuscleCallbackSink()
        await installCallbacks()
    }

    override func tearDown() async throws {
        await delivery.invalidate()
        await muscle.tearDown()
        muscle = nil
        sink = nil
        try await super.tearDown()
    }

    func replaceMuscle(sessionReleaseTimeout: TimeInterval) async {
        await delivery.invalidate()
        await muscle.tearDown()
        muscle = makeMuscle(sessionReleaseTimeout: sessionReleaseTimeout)
        sink = TheMuscleCallbackSink()
        await installCallbacks()
    }

    func installCallbacks() async {
        let sink = self.sink!
        await delivery?.invalidate()
        delivery = ClientDelivery(callbacks: ClientDelivery.Callbacks(
            sendToClient: { data, clientId in
                sink.appendSent((data, clientId))
                return .delivered
            },
            disconnectClient: { clientId in
                sink.appendDisconnected(clientId)
            },
            onClientAuthenticated: { _, clientId, respond in
                sink.appendAuthenticatedCallback((clientId, respond))
            }
        ))
    }

    func encodeAuth(token: SessionAuthToken, driverId: DriverID? = nil) throws -> Data {
        try JSONEncoder().encode(
            RequestEnvelope(message: .authenticate(AuthenticatePayload(token: token, driverId: driverId)))
        )
    }

    func decodeServerMessage(_ data: Data) -> ServerMessage? {
        do {
            return try JSONDecoder().decode(ResponseEnvelope.self, from: data).message
        } catch {
            XCTFail("Failed to decode ResponseEnvelope: \(error)")
            return nil
        }
    }

    func sessionLockedPayloads(from responses: [Data]) -> [SessionLockedPayload] {
        responses.compactMap { data in
            guard case .sessionLocked(let payload) = decodeServerMessage(data) else { return nil }
            return payload
        }
    }

    func authenticate(
        clientId: Int,
        token: SessionAuthToken,
        driverId: DriverID? = nil,
        address: ClientNetworkAddress = "127.0.0.1",
        respond: @escaping SocketResponseHandler
    ) async throws {
        await muscle.registerClientAddress(
            clientId,
            address: address,
            delivery: delivery
        )
        guard let hello = try? JSONEncoder().encode(RequestEnvelope(message: .clientHello)) else {
            return XCTFail("Failed to encode clientHello")
        }
        _ = await muscle.admitClientMessage(
            clientId,
            data: hello,
            respond: respond,
            delivery: delivery
        )
        _ = await muscle.admitClientMessage(
            clientId,
            data: try encodeAuth(token: token, driverId: driverId),
            respond: respond,
            delivery: delivery
        )
    }

    func respondSink() -> SocketResponseHandler {
        { _ in .delivered }
    }

    func collectResponses() -> (respond: SocketResponseHandler, responses: () -> [Data]) {
        final class Box: @unchecked Sendable {
            var items: [Data] = []
            let lock = NSLock()
        }
        let box = Box()
        return (
            { data in
                box.lock.withLock { box.items.append(data) }
                return .delivered
            },
            { box.lock.withLock { box.items } }
        )
    }

    func yieldScheduler() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    private func makeMuscle(
        sessionReleaseTimeout: TimeInterval = InsideJobRuntimeConfiguration.defaultSessionTimeout
    ) -> TheMuscle {
        TheMuscle(sessionToken: "test-token", sessionReleaseTimeout: sessionReleaseTimeout)
    }
}

#endif // canImport(UIKit)
