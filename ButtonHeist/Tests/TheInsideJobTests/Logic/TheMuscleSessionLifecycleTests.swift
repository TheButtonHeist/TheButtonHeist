#if canImport(UIKit)
import XCTest
import TheScore
@testable import TheInsideJob

@MainActor
final class TheMuscleSessionLifecycleTests: TheMuscleTestCase {
    func testNoSessionValidTokenAcquires() async throws {
        try await authenticate(clientId: 1, token: "test-token", respond: respondSink())

        let driverId = await muscle.sessionOwner
        XCTAssertNotNil(driverId, "Session should be claimed")
        let connections = await muscle.activeSessionConnections
        XCTAssertTrue(connections.contains(1))
    }

    func testSameDriverRejectedWhileActive() async throws {
        try await authenticate(clientId: 1, token: "test-token", respond: respondSink())

        let (respond, responses) = collectResponses()
        try await authenticate(clientId: 2, token: "test-token", respond: respond)

        let connections = await muscle.activeSessionConnections
        XCTAssertTrue(connections.contains(1))
        XCTAssertFalse(connections.contains(2))
        XCTAssertEqual(connections.count, 1)

        let payload = try XCTUnwrap(
            sessionLockedPayloads(from: responses()).first,
            "A second active same-driver connection should be rejected"
        )
        XCTAssertEqual(payload.activeConnections, 1)
        XCTAssertTrue(payload.message.contains("Session is already active for this driver"))
    }

    func testDifferentDriverBusy() async throws {
        try await authenticate(
            clientId: 1,
            token: "test-token",
            driverId: "driver-a",
            respond: respondSink()
        )

        let (respond, responses) = collectResponses()
        try await authenticate(
            clientId: 2,
            token: "test-token",
            driverId: "driver-b",
            respond: respond
        )

        let connections = await muscle.activeSessionConnections
        XCTAssertFalse(connections.contains(2))

        let payload = try XCTUnwrap(
            sessionLockedPayloads(from: responses()).first,
            "Should send sessionLocked to different driver"
        )
        XCTAssertEqual(
            payload.message,
            "Session is locked by another driver; owner driver id: driver-a; active connections: 1."
        )
        XCTAssertEqual(payload.activeConnections, 1)
    }

    func testSameDriverRejoinsAfterDisconnect() async throws {
        try await authenticate(clientId: 1, token: "test-token", respond: respondSink())
        await muscle.handleClientDisconnected(1, delivery: delivery)

        try await authenticate(clientId: 2, token: "test-token", respond: respondSink())

        let connections = await muscle.activeSessionConnections
        XCTAssertTrue(connections.contains(2), "Same driver should rejoin session")
    }

    func testDrainingSessionSurvivesForRejoin() async throws {
        try await authenticate(clientId: 1, token: "test-token", respond: respondSink())
        await muscle.handleClientDisconnected(1, delivery: delivery)

        let connectionsDuringDrain = await muscle.activeSessionConnections
        XCTAssertTrue(connectionsDuringDrain.isEmpty, "No connections during draining")
        let driverIdDuringDrain = await muscle.sessionOwner
        XCTAssertNotNil(driverIdDuringDrain, "Driver should still own session while draining")
        let hasReleaseTimerDuringDrain = await muscle.hasSessionReleaseTimerForTesting
        XCTAssertTrue(hasReleaseTimerDuringDrain)

        await installCallbacks()
        try await authenticate(clientId: 2, token: "test-token", respond: respondSink())

        let connectionsAfter = await muscle.activeSessionConnections
        let driverIdAfter = await muscle.sessionOwner
        XCTAssertTrue(connectionsAfter.contains(2), "New client should be in session")
        XCTAssertEqual(driverIdAfter, driverIdDuringDrain)
        let hasReleaseTimerAfterRejoin = await muscle.hasSessionReleaseTimerForTesting
        XCTAssertFalse(hasReleaseTimerAfterRejoin)
    }

    func testDifferentDriverBlockedDuringGracePeriod() async throws {
        try await authenticate(
            clientId: 1,
            token: "test-token",
            driverId: "driver-a",
            respond: respondSink()
        )
        await muscle.handleClientDisconnected(1, delivery: delivery)

        let (respond, responses) = collectResponses()
        try await authenticate(
            clientId: 2,
            token: "test-token",
            driverId: "driver-b",
            respond: respond
        )

        let payload = try XCTUnwrap(
            sessionLockedPayloads(from: responses()).first,
            "Different driver should be blocked during grace period"
        )
        XCTAssertEqual(payload.activeConnections, 0)
        XCTAssertTrue(payload.message.contains("owner driver id: driver-a"))
        XCTAssertTrue(payload.message.contains("active connections: 0"))
        XCTAssertTrue(payload.message.contains("remaining timeout:"))
    }

    func testDisconnectingNonSessionClientDoesNotStartReleaseTimer() async throws {
        await replaceMuscle(sessionReleaseTimeout: 0)

        try await authenticate(
            clientId: 1,
            token: "test-token",
            driverId: "driver-a",
            respond: respondSink()
        )
        await muscle.registerClientAddress(
            2,
            address: "127.0.0.1",
            delivery: delivery
        )

        await muscle.handleClientDisconnected(2, delivery: delivery)
        await yieldScheduler()

        let connections = await muscle.activeSessionConnections
        XCTAssertTrue(connections.contains(1))
        let driverId = await muscle.sessionOwner
        XCTAssertEqual(driverId, .driver("driver-a"))
    }

    func testLastSessionConnectionStartsReleaseTimer() async throws {
        await replaceMuscle(sessionReleaseTimeout: 0)

        try await authenticate(
            clientId: 1,
            token: "test-token",
            driverId: "driver-a",
            respond: respondSink()
        )
        await muscle.handleClientDisconnected(1, delivery: delivery)
        await muscle.awaitSessionReleaseTimerForTesting()

        let driverId = await muscle.sessionOwner
        XCTAssertNil(driverId)
    }

    func testTokenBackedSessionLockDoesNotExposeTokenAsOwner() async throws {
        try await authenticate(clientId: 1, token: "test-token", respond: respondSink())

        let (respond, responses) = collectResponses()
        try await authenticate(
            clientId: 2,
            token: "test-token",
            driverId: "driver-b",
            respond: respond
        )

        let payload = try XCTUnwrap(sessionLockedPayloads(from: responses()).first)
        XCTAssertFalse(payload.message.contains("test-token"))
    }

    func testTearDownClearsState() async throws {
        try await authenticate(clientId: 1, token: "test-token", respond: respondSink())

        let connectionsBefore = await muscle.activeSessionConnections
        XCTAssertTrue(connectionsBefore.contains(1))

        await muscle.tearDown()

        let driverId = await muscle.sessionOwner
        XCTAssertNil(driverId)
        let connections = await muscle.activeSessionConnections
        XCTAssertTrue(connections.isEmpty)
    }
}

#endif // canImport(UIKit)
