#if canImport(UIKit)
import ButtonHeistSupport
import os
import UIKit
import XCTest
import TheScore
@testable import TheInsideJob

@MainActor
final class TheGetawayTransportWiringTests: XCTestCase {

    func testReconnectWithSameClientIdCancelsOnlyPriorIncarnationWork() async throws {
        let clientId = 7
        let muscle = TheMuscle(sessionToken: "transport-wiring-token", sessionReleaseTimeout: 1)
        let brains = TheBrains(tripwire: TheTripwire())
        let getaway = TheGetaway(
            muscle: muscle,
            brains: brains,
            identity: .init(
                launchId: "transport-wiring-launch",
                effectiveInstanceId: "transport-wiring-instance",
                tlsActive: false
            )
        )
        let transport = ServerTransport(token: "transport-wiring-token")
        let wiringOutcome = await getaway.wireTransport(transport) { _ in }
        guard case .admitted(let admission) = wiringOutcome else {
            return XCTFail("Expected transport wiring to be admitted")
        }
        let delivery = admission.delivery
        let controlPlane = try XCTUnwrap(getaway.transportWiring.wired?.controlPlane)
        await controlPlane.observe(.clientConnected(
            clientId: clientId,
            remoteAddress: "127.0.0.1"
        ))
        try await authenticate(clientId: clientId, muscle: muscle, delivery: delivery)

        let blockerEntered = CompletionSignal()
        let releaseBlocker = CompletionSignal()
        XCTAssertEqual(brains.submitTransportRequest(
            lease: TransportClientLease(clientId: 1_000, incarnation: 1)
        ) {
            blockerEntered.finish()
            await releaseBlocker.wait()
        }, .accepted)
        await blockerEntered.wait()

        let priorResponses = TransportResponseSink()
        await controlPlane.observe(.dataReceived(
            clientId: clientId,
            data: try requestData(id: "prior-incarnation", message: .getNotifications),
            respond: priorResponses.respond
        ))
        for _ in 0..<100 { await Task.yield() }

        await controlPlane.observe(.clientDisconnected(clientId: clientId))
        for _ in 0..<100 { await Task.yield() }

        await controlPlane.observe(.clientConnected(
            clientId: clientId,
            remoteAddress: "127.0.0.1"
        ))
        try await authenticate(clientId: clientId, muscle: muscle, delivery: delivery)
        let currentResponses = TransportResponseSink()
        await controlPlane.observe(.dataReceived(
            clientId: clientId,
            data: try requestData(id: "current-incarnation", message: .getNotifications),
            respond: currentResponses.respond
        ))
        for _ in 0..<100 { await Task.yield() }

        releaseBlocker.finish()
        await currentResponses.delivered.wait()

        XCTAssertEqual(priorResponses.count, 0)
        XCTAssertEqual(currentResponses.count, 1)
        await getaway.tearDown()
        await muscle.tearDown()
    }

    func testGetNotificationsReturnsCanonicalVaultHistoryProjection() async throws {
        let clientId = 7
        let muscle = TheMuscle(sessionToken: "transport-wiring-token", sessionReleaseTimeout: 1)
        let brains = TheBrains(tripwire: TheTripwire())
        let getaway = TheGetaway(
            muscle: muscle,
            brains: brains,
            identity: .init(
                launchId: "transport-wiring-launch",
                effectiveInstanceId: "transport-wiring-instance",
                tlsActive: false
            )
        )
        let transport = ServerTransport(token: "transport-wiring-token")
        let wiringOutcome = await getaway.wireTransport(transport) { _ in }
        guard case .admitted(let admission) = wiringOutcome else {
            return XCTFail("Expected transport wiring to be admitted")
        }
        let controlPlane = try XCTUnwrap(getaway.transportWiring.wired?.controlPlane)
        await controlPlane.observe(.clientConnected(
            clientId: clientId,
            remoteAddress: "127.0.0.1"
        ))
        try await authenticate(
            clientId: clientId,
            muscle: muscle,
            delivery: admission.delivery
        )

        let elementOnlyButton = UIButton(type: .system)
        elementOnlyButton.accessibilityLabel = "Subtotal"
        let notificationWindow = brains.vault.accessibilityNotifications.beginActionWindow()
        brains.vault.accessibilityNotifications.recordForTesting(
            code: 1008,
            notificationData: CapturedAccessibilityNotificationPayload("Saved" as NSString),
            associatedElement: .none
        )
        brains.vault.accessibilityNotifications.recordForTesting(
            code: 1001,
            notificationData: .none,
            associatedElement: CapturedAccessibilityNotificationPayload(elementOnlyButton)
        )
        brains.vault.accessibilityNotifications.recordForTesting(
            code: 1008,
            notificationData: CapturedAccessibilityNotificationPayload("Ready" as NSString),
            associatedElement: .none
        )
        let committed = await notificationWindow.admitCausallyCovered { coverage in
            _ = await brains.vault.semanticObservationStream
                .commitVisibleObservationForTesting(.makeForTests())
            return brains.vault.semanticObservationStream.currentObservation(
                covering: coverage
            )
        }
        XCTAssertNotNil(committed)

        let responses = TransportResponseSink()
        await controlPlane.observe(.dataReceived(
            clientId: clientId,
            data: try requestData(id: "notifications", message: .getNotifications),
            respond: responses.respond
        ))
        await responses.delivered.wait()

        guard case .notifications(let notifications) = try XCTUnwrap(responses.messages.first) else {
            await getaway.tearDown()
            await muscle.tearDown()
            return XCTFail("Expected canonical notifications response")
        }
        XCTAssertEqual(notifications, brains.notifications())
        XCTAssertEqual(notifications.map(\.text), ["Saved", nil, "Ready"])
        XCTAssertEqual(notifications[0].element, nil)
        XCTAssertEqual(notifications[1].element?.assertable.label, "Subtotal")
        XCTAssertNil(notifications[2].element)

        await getaway.tearDown()
        await muscle.tearDown()
    }

    func testReplacementWiringWaitsForPriorInteractionCleanup() async {
        let muscle = TheMuscle(sessionToken: "transport-wiring-token", sessionReleaseTimeout: 1)
        let brains = TheBrains(tripwire: TheTripwire())
        let getaway = TheGetaway(
            muscle: muscle,
            brains: brains,
            identity: .init(
                launchId: "transport-wiring-launch",
                effectiveInstanceId: "transport-wiring-instance",
                tlsActive: false
            )
        )
        let firstTransport = ServerTransport(token: "transport-wiring-token")
        let firstWiring = await getaway.wireTransport(firstTransport) { _ in }
        guard case .admitted(let firstAdmission) = firstWiring else {
            return XCTFail("Expected initial transport wiring to be admitted")
        }

        let operationStarted = CompletionSignal()
        let cancellationObserved = CompletionSignal()
        let releaseCleanup = CompletionSignal()
        XCTAssertEqual(brains.submitTransportRequest(
            lease: TransportClientLease(clientId: 7, incarnation: 1)
        ) {
            operationStarted.finish()
            let cleanup = Task { [releaseCleanup] in
                await releaseCleanup.wait()
            }
            await withTaskCancellationHandler {
                await cleanup.value
            } onCancel: {
                cancellationObserved.finish()
            }
        }, .accepted)
        await operationStarted.wait()

        let secondTransport = ServerTransport(token: "transport-wiring-token")
        let replacementCompleted = CompletionSignal()
        let replacement = Task { @MainActor in
            let outcome = await getaway.wireTransport(secondTransport) { _ in }
            replacementCompleted.finish()
            guard case .admitted = outcome else { return false }
            return true
        }
        await cancellationObserved.wait()
        XCTAssertFalse(replacementCompleted.isFinished)

        releaseCleanup.finish()
        guard await replacement.value else {
            return XCTFail("Expected replacement wiring to be admitted after cleanup")
        }
        let replacedDeliveryIsActive = await firstAdmission.delivery.isActive
        XCTAssertFalse(replacedDeliveryIsActive)
        await getaway.tearDown()
        await muscle.tearDown()
    }

    func testMainThreadProbeBypassesActiveInteractionRequest() async throws {
        let clientId = 7
        let muscle = TheMuscle(sessionToken: "transport-wiring-token", sessionReleaseTimeout: 1)
        let brains = TheBrains(tripwire: TheTripwire())
        let getaway = TheGetaway(
            muscle: muscle,
            brains: brains,
            identity: .init(
                launchId: "transport-wiring-launch",
                effectiveInstanceId: "transport-wiring-instance",
                tlsActive: false
            ),
            mainThreadProbe: { _ in
                MainThreadProbeResponse(outcome: .responsive)
            }
        )
        let transport = ServerTransport(token: "transport-wiring-token")
        let wiringOutcome = await getaway.wireTransport(transport) { _ in }
        guard case .admitted(let admission) = wiringOutcome else {
            return XCTFail("Expected transport wiring to be admitted")
        }
        let delivery = admission.delivery
        let controlPlane = try XCTUnwrap(getaway.transportWiring.wired?.controlPlane)
        await controlPlane.observe(.clientConnected(
            clientId: clientId,
            remoteAddress: "127.0.0.1"
        ))
        try await authenticate(
            clientId: clientId,
            muscle: muscle,
            delivery: delivery
        )

        let interactionEntered = CompletionSignal()
        let releaseInteraction = CompletionSignal()
        XCTAssertEqual(brains.submitTransportRequest(
            lease: TransportClientLease(clientId: clientId, incarnation: 0)
        ) {
            interactionEntered.finish()
            await releaseInteraction.wait()
        }, .accepted)
        await interactionEntered.wait()

        let responses = TransportResponseSink()
        let probe = try JSONEncoder().encode(
            RequestEnvelope(
                requestId: "main-thread-probe",
                message: .mainThreadProbe(try XCTUnwrap(MainThreadProbeRequest.admit(
                    responsivenessTimeoutMilliseconds: 1_000,
                    workTimeoutMilliseconds: 1_000
                )))
            )
        )
        await controlPlane.observe(.dataReceived(
            clientId: clientId,
            data: probe,
            respond: responses.respond
        ))
        await responses.delivered.wait()

        let response = try XCTUnwrap(responses.messages.first)
        guard case .mainThreadProbe(let payload) = response else {
            releaseInteraction.finish()
            await brains.stopInteractionRequests()
            await getaway.tearDown()
            await muscle.tearDown()
            return XCTFail("Expected a main-thread probe response")
        }
        XCTAssertEqual(payload.outcome, .responsive)

        releaseInteraction.finish()
        await brains.stopInteractionRequests()
        await getaway.tearDown()
        await muscle.tearDown()
    }

    private func authenticate(
        clientId: Int,
        muscle: TheMuscle,
        delivery: ClientDelivery
    ) async throws {
        let respond: SocketResponseHandler = { _ in .delivered }
        let hello = try JSONEncoder().encode(RequestEnvelope(message: .clientHello))
        _ = await muscle.admitClientMessage(
            clientId,
            data: hello,
            respond: respond,
            delivery: delivery
        )
        let authentication = try JSONEncoder().encode(RequestEnvelope(message: .authenticate(
            AuthenticatePayload(token: "transport-wiring-token", driverId: nil)
        )))
        _ = await muscle.admitClientMessage(
            clientId,
            data: authentication,
            respond: respond,
            delivery: delivery
        )
    }

    private func requestData(
        id: RequestID,
        message: ClientMessage
    ) throws -> Data {
        try JSONEncoder().encode(RequestEnvelope(requestId: id, message: message))
    }

    func testOlderWiringPausedBeforeAdmissionCannotReplaceCurrentWiring() async {
        let muscle = TheMuscle(sessionToken: "transport-wiring-token", sessionReleaseTimeout: 1)
        let brains = TheBrains(tripwire: TheTripwire())
        let staleTransport = ServerTransport(token: "transport-wiring-token")
        let currentTransport = ServerTransport(token: "transport-wiring-token")
        let enteredStaleAdmission = CompletionSignal()
        let releaseStaleAdmission = CompletionSignal()
        let getaway = TheGetaway(
            muscle: muscle,
            brains: brains,
            identity: .init(
                launchId: "transport-wiring-launch",
                effectiveInstanceId: "transport-wiring-instance",
                tlsActive: false
            ),
            transportWiringBoundary: .init(
                beforeControlPlaneAdmission: { attempt in
                    guard attempt.transport === staleTransport else { return }
                    enteredStaleAdmission.finish()
                    await releaseStaleAdmission.wait()
                }
            )
        )

        let staleWiringTask = Task { @MainActor in
            let outcome = await getaway.wireTransport(staleTransport) { _ in }
            guard case .rejected = outcome else { return false }
            return true
        }
        await enteredStaleAdmission.wait()

        let currentOutcome = await getaway.wireTransport(currentTransport) { _ in }
        guard case .admitted(let currentAdmission) = currentOutcome else {
            return XCTFail("Expected current wiring to be admitted")
        }
        releaseStaleAdmission.finish()
        let staleRejectedWiring = await staleWiringTask.value

        XCTAssertTrue(staleRejectedWiring, "Expected stale admission to reject its wiring attempt")
        let currentDeliveryIsActive = await currentAdmission.delivery.isActive
        XCTAssertTrue(currentDeliveryIsActive)
        guard case .wired(let wiredTransport) = getaway.transportWiring else {
            return XCTFail("Expected current transport to remain wired, got \(getaway.transportWiring)")
        }
        XCTAssertTrue(wiredTransport.attempt.transport === currentTransport)
        await getaway.tearDown()
        await muscle.tearDown()
    }

    func testTearDownDuringTransportWiringPreventsStaleConsumerCommit() async {
        let muscle = TheMuscle(sessionToken: "transport-wiring-token", sessionReleaseTimeout: 1)
        let brains = TheBrains(tripwire: TheTripwire())
        let transport = ServerTransport(token: "transport-wiring-token")
        let enteredAdmission = CompletionSignal()
        let releaseAdmission = CompletionSignal()
        let getaway = TheGetaway(
            muscle: muscle,
            brains: brains,
            identity: .init(
                launchId: "transport-wiring-launch",
                effectiveInstanceId: "transport-wiring-instance",
                tlsActive: false
            ),
            transportWiringBoundary: .init(
                beforeControlPlaneAdmission: { attempt in
                    guard attempt.transport === transport else { return }
                    enteredAdmission.finish()
                    await releaseAdmission.wait()
                }
            )
        )

        let wiringTask = Task { @MainActor in
            let outcome = await getaway.wireTransport(transport) { _ in }
            guard case .rejected = outcome else { return false }
            return true
        }
        await enteredAdmission.wait()

        await getaway.tearDown()
        releaseAdmission.finish()
        let teardownRejectedWiring = await wiringTask.value
        XCTAssertTrue(teardownRejectedWiring, "Expected teardown to reject stale transport wiring")

        guard case .unwired = getaway.transportWiring else {
            return XCTFail("Expected teardown to reject stale transport wiring, got \(getaway.transportWiring)")
        }
        XCTAssertNil(getaway.transport)
        await muscle.tearDown()
    }

    func testRejectedTransportWiringDoesNotStartListener() async throws {
        let listeners = TestSocketListenerProvider(port: 49_153)
        let token: SessionAuthToken = "transport-wiring-token"
        let transport = ServerTransport(
            token: token,
            serverDependencies: .init(listenerProvider: listeners.listenerProvider)
        )
        let enteredAdmission = CompletionSignal()
        let releaseAdmission = CompletionSignal()
        let job = try TheInsideJob(
            token: token.description,
            addressFamily: .ipv4,
            transportWiringBoundary: .init(
                beforeControlPlaneAdmission: { attempt in
                    guard attempt.transport === transport else { return }
                    enteredAdmission.finish()
                    await releaseAdmission.wait()
                }
            ),
            transportProvider: { _, _ in transport }
        )
        let request = TheInsideJob.InsideJobTransportStartRequest(
            id: UUID(),
            transport: transport,
            idleTimerBaseline: false
        )

        let startTask = Task { @MainActor in
            do {
                _ = try await job.startRuntimeResources(for: request)
                return false
            } catch {
                return true
            }
        }
        await enteredAdmission.wait()
        await job.getaway.tearDown()
        releaseAdmission.finish()

        let rejectedStartup = await startTask.value
        XCTAssertTrue(rejectedStartup, "Expected rejected wiring to cancel startup before listener start")
        XCTAssertEqual(listeners.invocationCount, 0)
        await job.muscle.tearDown()
    }

}

private final class TransportResponseSink: Sendable {
    let delivered = CompletionSignal()
    private let storage = OSAllocatedUnfairLock(initialState: [ServerMessage]())

    var count: Int {
        storage.withLock { $0.count }
    }

    var messages: [ServerMessage] {
        storage.withLock { $0 }
    }

    var respond: SocketResponseHandler {
        { [weak self] data in
            guard let self else { return .failed(.transportUnavailable) }
            guard let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data) else {
                return .failed(.transportUnavailable)
            }
            storage.withLock { $0.append(envelope.message) }
            delivered.finish()
            return .delivered
        }
    }
}
#endif // canImport(UIKit)
