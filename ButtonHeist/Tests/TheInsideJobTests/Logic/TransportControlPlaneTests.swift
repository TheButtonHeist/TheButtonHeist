#if canImport(UIKit)
import os
import XCTest

import TheScore
@testable import TheInsideJob

@MainActor
final class TransportControlPlaneTests: XCTestCase {
    func testControlChangesCoalesceConnectionChurnIntoOneBoundedWakeup() async {
        let muscle = TheMuscle(sessionToken: "control-plane-token", sessionReleaseTimeout: 1)
        let transport = ServerTransport(token: "control-plane-token")
        let publishedCount = OSAllocatedUnfairLock(initialState: 0)
        let events = AsyncStream<TransportControlPlane.MainActorEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(TransportControlPlane.mainActorEventBufferLimit)
        )
        let delivery = ClientDelivery(callbacks: ClientDelivery.Callbacks(
            sendToClient: { _, _ in .delivered },
            disconnectClient: { _ in },
            onClientAuthenticated: { _, _, _ in }
        ))
        let controlPlane = TransportControlPlane(
            transport: transport,
            muscle: muscle,
            delivery: delivery,
            pongPayload: PongPayload(bundleIdentifier: "com.buttonheist.tests"),
            probe: { _ in MainThreadProbeResponse(outcome: .responsive) },
            publish: { event in
                publishedCount.withLock { $0 += 1 }
                return events.continuation.yield(event)
            }
        )
        await controlPlane.start()

        await controlPlane.observe(.clientConnected(clientId: 7, remoteAddress: nil))
        await controlPlane.observe(.clientConnected(clientId: 7, remoteAddress: nil))
        await controlPlane.observe(.clientDisconnected(clientId: 7))
        await controlPlane.observe(.backlogOverflow(maxEvents: 64))

        XCTAssertEqual(publishedCount.withLock { $0 }, 1)
        let changes = await controlPlane.consumeControlChanges()
        XCTAssertEqual(changes.endedLeases.count, 2)
        XCTAssertEqual(changes.backlogOverflowLimit, 64)
        XCTAssertEqual(
            TransportControlPlane.mainActorEventBufferLimit,
            ClientRequestPipeline.maximumQueuedRequests + 1
        )

        events.continuation.finish()
        await controlPlane.stop()
        await delivery.invalidate()
        await muscle.tearDown()
    }
}
#endif
