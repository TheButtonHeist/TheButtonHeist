#if canImport(UIKit)
#if DEBUG
import ButtonHeistTestSupport
import XCTest
import Network
import ButtonHeistSupport

@testable import TheInsideJob

final class TheMuscleStateMachineTests: XCTestCase {
    func testAuthenticationPolicyRejectsInvalidConfiguration() {
        XCTAssertNil(InsideJobAuthenticationPolicy(maximumFailedAttempts: 0))
    }

    func testTokenAdmissionLocksAddressAfterConfiguredFailures() throws {
        var admission = ClientAdmission.TokenAuthentication(
            sessionToken: "good-token",
            policy: try XCTUnwrap(.init(maximumFailedAttempts: 2, lockoutDuration: 30))
        )

        guard case .rejected(.invalidToken(let firstError, let firstAttempts)) = admission.admit(
            "bad-token",
            driverId: nil,
            address: "127.0.0.1"
        ) else {
            return XCTFail("Expected the first bad token to be rejected")
        }
        XCTAssertEqual(firstError.message, "Invalid token. Retry with the session token.")
        XCTAssertEqual(firstError.recoveryHint, "Retry with the session token.")
        XCTAssertEqual(firstAttempts, 1)

        guard case .rejected(.lockoutStarted(let secondError, let secondAttempts)) = admission.admit(
            "bad-token",
            driverId: nil,
            address: "127.0.0.1"
        ) else {
            return XCTFail("Expected the second bad token to be rejected")
        }
        XCTAssertEqual(secondError.recoveryHint, "Retry with the session token.")
        XCTAssertEqual(secondAttempts, 2)

        guard case .lockedOut(let error) = admission.admit(
            "good-token",
            driverId: nil,
            address: "127.0.0.1"
        ) else {
            return XCTFail("Expected the locked-out address to stay locked out")
        }
        XCTAssertEqual(error.message, "Too many failed attempts. Try again later.")
    }

    func testTokenAdmissionPrunesExpiredFailureHistory() throws {
        var admission = ClientAdmission.TokenAuthentication(
            sessionToken: "good-token",
            policy: try XCTUnwrap(.init(
                maximumFailedAttempts: 2,
                failedAddressRetentionDuration: 5
            ))
        )
        let start = Date(timeIntervalSince1970: 100)
        _ = admission.admit("bad-token", driverId: nil, address: "expired", now: start)

        guard case .rejected(.invalidToken(_, let attempts)) = admission.admit(
            "bad-token",
            driverId: nil,
            address: "expired",
            now: start.addingTimeInterval(6)
        ) else {
            return XCTFail("Expected the expired address to start fresh")
        }
        XCTAssertEqual(attempts, 1)
    }

    func testTokenAdmissionEvictsOldestFailingAddressAtCapacity() throws {
        var admission = ClientAdmission.TokenAuthentication(
            sessionToken: "good-token",
            policy: try XCTUnwrap(.init(
                maximumFailedAttempts: 3,
                maximumTrackedFailedAddresses: 1
            ))
        )
        let start = Date(timeIntervalSince1970: 100)
        _ = admission.admit("bad-token", driverId: nil, address: "oldest", now: start)
        _ = admission.admit(
            "bad-token",
            driverId: nil,
            address: "newest",
            now: start.addingTimeInterval(1)
        )

        guard case .rejected(.invalidToken(_, let attempts)) = admission.admit(
            "bad-token",
            driverId: nil,
            address: "oldest",
            now: start.addingTimeInterval(2)
        ) else {
            return XCTFail("Expected the evicted address to start fresh")
        }
        XCTAssertEqual(attempts, 1)
    }

    func testTokenAdmissionPreservesActiveLockoutAtCapacity() throws {
        var admission = ClientAdmission.TokenAuthentication(
            sessionToken: "good-token",
            policy: try XCTUnwrap(.init(
                maximumFailedAttempts: 1,
                maximumTrackedFailedAddresses: 1
            ))
        )
        let start = Date(timeIntervalSince1970: 100)
        guard case .rejected(.lockoutStarted) = admission.admit(
            "bad-token",
            driverId: nil,
            address: "locked",
            now: start
        ) else {
            return XCTFail("Expected the first address to enter lockout")
        }
        guard case .rejected(.invalidToken) = admission.admit(
            "bad-token",
            driverId: nil,
            address: "untracked",
            now: start.addingTimeInterval(1)
        ) else {
            return XCTFail("Capacity exhaustion must not claim a new address is locked out")
        }
        guard case .lockedOut = admission.admit(
            "good-token",
            driverId: nil,
            address: "locked",
            now: start.addingTimeInterval(2)
        ) else {
            return XCTFail("Active lockout must survive capacity pressure")
        }
    }

    func testClientAuthenticationRejectsAuthenticationBeforeHello() {
        XCTAssertEqual(
            ClientAdmission.Authentication.Reducer().reduce(
                .connected(address: "127.0.0.1"),
                event: .authenticationCompletionRequested
            ),
            .rejected(.missingHello, state: .connected(address: "127.0.0.1"))
        )
        var registry = ClientAdmission.Registry()
        registry.registerAddress(1, address: "127.0.0.1")

        XCTAssertEqual(
            registry.completeAuthentication(1),
            .rejected(.missingHello, state: .connected(address: "127.0.0.1"))
        )
        XCTAssertEqual(registry.state(for: 1), .connected(address: "127.0.0.1"))
    }

    func testClientAuthenticationAdvancesThroughHelloBeforeAuthenticated() {
        XCTAssertEqual(
            ClientAdmission.Authentication.Reducer().reduce(
                .connected(address: "127.0.0.1"),
                event: .helloValidationRequested
            ),
            .advanced(.helloValidated(address: "127.0.0.1"), outcome: .helloValidated)
        )
        var registry = ClientAdmission.Registry()
        registry.registerAddress(1, address: "127.0.0.1")

        XCTAssertEqual(
            registry.validateHello(1),
            .advanced(.helloValidated(address: "127.0.0.1"), outcome: .helloValidated)
        )
        XCTAssertEqual(
            registry.completeAuthentication(1),
            .advanced(.authenticated(address: "127.0.0.1"), outcome: .authenticated)
        )
        XCTAssertEqual(registry.state(for: 1), .authenticated(address: "127.0.0.1"))
    }

    func testClientAuthenticationRejectsDuplicateHelloAfterValidation() {
        var registry = ClientAdmission.Registry()
        registry.registerAddress(1, address: "127.0.0.1")

        _ = registry.validateHello(1)

        XCTAssertEqual(
            registry.validateHello(1),
            .rejected(.helloAlreadyValidated, state: .helloValidated(address: "127.0.0.1"))
        )
        XCTAssertEqual(registry.state(for: 1), .helloValidated(address: "127.0.0.1"))
    }

    func testAdmissionLifecycleOwnsCredentialAndAuthenticationDeadlineEffects() throws {
        var admission = ClientAdmission.Reducer(
            sessionToken: "good-token",
            authenticationPolicy: try XCTUnwrap(.init(maximumFailedAttempts: 2, lockoutDuration: 30))
        )
        let respond: SocketResponseHandler = { _ in .delivered }

        guard case .replaceAuthenticationDeadline(let registeredClientId)? =
            admission.registerClientAddress(1, address: "127.0.0.1").first
        else {
            return XCTFail("Expected registration to replace the authentication deadline")
        }
        XCTAssertEqual(registeredClientId, 1)

        let hello = try JSONEncoder().encode(RequestEnvelope(message: .clientHello))
        guard case .handled = admission.admit(1, data: hello, respond: respond) else {
            return XCTFail("Expected client hello to be handled")
        }
        let authentication = try JSONEncoder().encode(RequestEnvelope(message: .authenticate(
            AuthenticatePayload(token: "good-token", driverId: "driver")
        )))
        guard case .sessionAdmission(let sessionAdmission) = admission.admit(
            1,
            data: authentication,
            respond: respond
        ) else {
            return XCTFail("Expected valid credentials to request session admission")
        }
        guard case .cancelAuthenticationDeadline(let authenticatedClientId)? =
            admission.completeAuthentication(sessionAdmission).first
        else {
            return XCTFail("Expected authentication to cancel its deadline")
        }
        XCTAssertEqual(authenticatedClientId, 1)

        guard case .cancelAuthenticationDeadline(let removedClientId)? = admission.removeClient(1).first else {
            return XCTFail("Expected client removal to cancel its deadline")
        }
        XCTAssertEqual(removedClientId, 1)

        guard case .cancelAllAuthenticationDeadlines? = admission.removeAllClients().first else {
            return XCTFail("Expected teardown to cancel all authentication deadlines")
        }
    }

    func testClientRemovalClearsAuthenticationAndRateLimitStateTogether() {
        var registry = ClientAdmission.Registry()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        registry.registerAddress(1, address: "127.0.0.1")
        for _ in 0..<ClientAdmission.RateLimiter.defaultMaxMessagesPerSecond {
            XCTAssertEqual(registry.admitMessage(1, at: now), .accept)
        }
        XCTAssertEqual(registry.admitMessage(1, at: now), .drop(shouldNotify: true))

        XCTAssertEqual(registry.remove(1), .connected(address: "127.0.0.1"))
        XCTAssertFalse(registry.contains(1))
        XCTAssertNil(registry.state(for: 1))

        registry.registerAddress(1, address: "127.0.0.1")
        XCTAssertEqual(registry.admitMessage(1, at: now), .accept)
    }

    func testSessionLeaseDrainingRejectionUsesOneStructuredDiagnostic() {
        var lease = SessionLease(releaseTimeout: 30)
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        guard case .accepted(let claimEffects) = lease.acquire(
            owner: .driver("alpha"),
            clientId: 1,
            at: now
        ) else {
            return XCTFail("Expected first driver to claim the session")
        }
        XCTAssertEqual(claimEffects, [.log(.sessionClaimed(clientId: 1))])

        XCTAssertEqual(
            lease.removeConnection(1, at: now),
            [
                .replaceReleaseTimer(timeout: 30),
                .log(.releaseTimerStarted(timeout: 30)),
            ]
        )
        guard case .draining(_, let releaseDeadline) = lease.phase else {
            return XCTFail("Expected final connection removal to start draining")
        }
        XCTAssertEqual(releaseDeadline, now.addingTimeInterval(30))

        guard case .rejected(let diagnostic) = lease.acquire(
            owner: .driver("beta"),
            clientId: 2,
            at: now.addingTimeInterval(12)
        ) else {
            return XCTFail("Expected different driver to be rejected while draining")
        }
        guard case .drainingOwner(
            owner: .exposed("alpha"),
            remainingTimeoutSeconds: let remainingTimeoutSeconds
        ) = diagnostic else {
            return XCTFail("Expected draining lock diagnostic, got \(diagnostic)")
        }
        XCTAssertEqual(remainingTimeoutSeconds, 18)

        let payload = diagnostic.payload()
        XCTAssertEqual(payload.activeConnections, 0)
        XCTAssertTrue(payload.message.contains("Session is locked by another driver"))
        XCTAssertTrue(payload.message.contains("owner driver id: alpha"))
        XCTAssertTrue(payload.message.contains("active connections: 0"))
        XCTAssertTrue(payload.message.contains("remaining timeout:"))
    }

    func testSessionLeaseActiveRejectionUsesTypedDiagnosticWithoutDrainingTimeout() {
        var lease = SessionLease(releaseTimeout: 30)
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        guard case .accepted(let claimEffects) = lease.acquire(
            owner: .driver("alpha"),
            clientId: 1,
            at: now
        ) else {
            return XCTFail("Expected first driver to claim the session")
        }
        XCTAssertEqual(claimEffects, [.log(.sessionClaimed(clientId: 1))])

        guard case .rejected(let sameDriverDiagnostic) = lease.acquire(
            owner: .driver("alpha"),
            clientId: 2,
            at: now
        ) else {
            return XCTFail("Expected same driver to be rejected while already active")
        }
        guard case .sameDriverActive(owner: .exposed("alpha")) = sameDriverDiagnostic else {
            return XCTFail("Expected same-driver active diagnostic, got \(sameDriverDiagnostic)")
        }
        XCTAssertEqual(sameDriverDiagnostic.payload().activeConnections, 1)
        XCTAssertFalse(sameDriverDiagnostic.payload().message.contains("remaining timeout:"))

        guard case .rejected(let activeOwnerDiagnostic) = lease.acquire(
            owner: .driver("beta"),
            clientId: 3,
            at: now
        ) else {
            return XCTFail("Expected different driver to be rejected while active")
        }
        guard case .activeOwner(owner: .exposed("alpha")) = activeOwnerDiagnostic else {
            return XCTFail("Expected active-owner diagnostic, got \(activeOwnerDiagnostic)")
        }
        XCTAssertEqual(activeOwnerDiagnostic.payload().activeConnections, 1)
        XCTAssertFalse(activeOwnerDiagnostic.payload().message.contains("remaining timeout:"))
    }

    func testSessionLeaseIgnoresNonActiveConnectionRemoval() {
        var lease = SessionLease(releaseTimeout: 30)
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        guard case .accepted = lease.acquire(owner: .driver("alpha"), clientId: 1, at: now) else {
            return XCTFail("Expected first driver to claim the session")
        }

        XCTAssertEqual(lease.removeConnection(2, at: now), [])
        XCTAssertEqual(lease.activeSessionConnections, [1])

        XCTAssertFalse(lease.removeConnection(1, at: now).isEmpty)
        guard case .draining = lease.phase else {
            return XCTFail("Expected active session connection removal to start draining")
        }
    }

    func testSessionLeaseRejoinsDuringGracePeriod() {
        var lease = SessionLease(releaseTimeout: 30)
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        guard case .accepted(let claimEffects) = lease.acquire(
            owner: .driver("alpha"),
            clientId: 1,
            at: now
        ) else {
            return XCTFail("Expected first driver to claim the session")
        }
        XCTAssertEqual(claimEffects, [.log(.sessionClaimed(clientId: 1))])
        _ = lease.removeConnection(1, at: now)
        guard case .draining = lease.phase else {
            return XCTFail("Expected final connection removal to start draining")
        }

        guard case .accepted(let effects) = lease.acquire(
            owner: .driver("alpha"),
            clientId: 2,
            at: now.addingTimeInterval(5)
        ) else {
            return XCTFail("Expected active driver to rejoin during the grace period")
        }
        XCTAssertEqual(
            effects,
            [
                .cancelReleaseTimer,
                .log(.clientRejoinedDuringGracePeriod(clientId: 2)),
            ]
        )
        XCTAssertEqual(lease.activeSessionOwner, .driver("alpha"))
        XCTAssertEqual(lease.exposedDriverId, "alpha")
        XCTAssertEqual(lease.activeSessionConnections, [2])
    }

    func testSessionLeaseReleaseReportsIdleAndActiveOutcomes() {
        var lease = SessionLease(releaseTimeout: 30)
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(lease.release(), [.cancelReleaseTimer])

        guard case .accepted(let claimEffects) = lease.acquire(
            owner: .driver("alpha"),
            clientId: 1,
            at: now
        ) else {
            return XCTFail("Expected first driver to claim the session")
        }
        XCTAssertEqual(claimEffects, [.log(.sessionClaimed(clientId: 1))])

        XCTAssertEqual(lease.release(), [.cancelReleaseTimer, .log(.sessionReleased)])
        XCTAssertNil(lease.activeSessionOwner)
        XCTAssertEqual(lease.activeSessionConnections, [])
        XCTAssertEqual(lease.release(), [.cancelReleaseTimer])
    }

    func testClientDeliveryReportsInvalidatedFailuresAsTypedOutcomes() async {
        let delivery = ClientDelivery(callbacks: clientDeliveryCallbacks(counter: ClientDeliveryTestCounter()))
        await delivery.invalidate()

        let sendOutcome = await delivery.send(Data("hello".utf8), toClient: 1)
        guard case .failed(.transportUnavailable) = sendOutcome else {
            return XCTFail("Expected missing transport to be a typed send failure, got \(sendOutcome)")
        }

        let disconnectOutcome = await delivery.disconnect(1)
        XCTAssertEqual(disconnectOutcome, .rejected)
    }

    func testClientDeliveryRejectsStaleLifecycleWorkWithoutChangingCurrentCallbacks() async {
        let staleDeliveries = ClientDeliveryTestCounter()
        let currentDeliveries = ClientDeliveryTestCounter()
        let responseDeliveries = ClientDeliveryTestCounter()
        let staleDelivery = ClientDelivery(callbacks: clientDeliveryCallbacks(counter: staleDeliveries))
        let currentDelivery = ClientDelivery(callbacks: clientDeliveryCallbacks(counter: currentDeliveries))
        await staleDelivery.invalidate()
        let staleSendOutcome = await staleDelivery.send(
            Data("stale".utf8),
            toClient: 7
        )
        let staleDisconnectOutcome = await staleDelivery.disconnect(7)
        let staleAuthenticationOutcome = await staleDelivery.clientAuthenticated(
            7,
            respond: { _ in .delivered }
        )
        let staleResponseOutcome = await staleDelivery.respond(
            Data("stale-response".utf8),
            using: { _ in
                await responseDeliveries.increment()
                return .delivered
            }
        )
        guard case .failed(.transportUnavailable) = staleSendOutcome else {
            return XCTFail("Expected stale send to report transport unavailable, got \(staleSendOutcome)")
        }
        guard case .failed(.transportUnavailable) = staleResponseOutcome else {
            return XCTFail("Expected stale response to report transport unavailable, got \(staleResponseOutcome)")
        }
        XCTAssertEqual(staleDisconnectOutcome, .rejected)
        XCTAssertEqual(staleAuthenticationOutcome, .rejected)
        let deliveryCountAfterStaleAttempts = await currentDeliveries.value
        let responseCountAfterStaleAttempts = await responseDeliveries.value
        XCTAssertEqual(deliveryCountAfterStaleAttempts, 0)
        XCTAssertEqual(responseCountAfterStaleAttempts, 0)

        let sendOutcome = await currentDelivery.send(
            Data("current".utf8),
            toClient: 7
        )
        let disconnectOutcome = await currentDelivery.disconnect(7)
        let authenticationOutcome = await currentDelivery.clientAuthenticated(
            7,
            respond: { _ in .delivered }
        )
        let responseOutcome = await currentDelivery.respond(
            Data("current-response".utf8),
            using: { _ in
                await responseDeliveries.increment()
                return .delivered
            }
        )
        let staleDeliveryCount = await staleDeliveries.value
        let currentDeliveryCount = await currentDeliveries.value
        let responseDeliveryCount = await responseDeliveries.value
        XCTAssertEqual(sendOutcome, .delivered)
        XCTAssertEqual(disconnectOutcome, .delivered)
        XCTAssertEqual(authenticationOutcome, .delivered)
        XCTAssertEqual(responseOutcome, .delivered)
        XCTAssertEqual(staleDeliveryCount, 0)
        XCTAssertEqual(currentDeliveryCount, 3)
        XCTAssertEqual(responseDeliveryCount, 1)
    }

    func testServerTransportFailurePreservesNetworkDiagnosticReason() {
        let diagnostic = NetworkTransportFailure(.posix(.ECONNRESET))
        let failure = ServerSendFailure.transportFailed(clientId: 12, diagnostic: diagnostic)

        guard case .transportFailed(let clientId, let capturedDiagnostic) = failure else {
            return XCTFail("Expected typed transport failure, got \(failure)")
        }
        XCTAssertEqual(clientId, 12)
        XCTAssertEqual(capturedDiagnostic.reason, .posix(code: Int(POSIXErrorCode.ECONNRESET.rawValue)))
        XCTAssertTrue(capturedDiagnostic.description.contains("posix"))
        XCTAssertTrue(failure.localizedDescription.contains("posix"))
    }

}

private actor ClientDeliveryTestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private func clientDeliveryCallbacks(counter: ClientDeliveryTestCounter) -> ClientDelivery.Callbacks {
    ClientDelivery.Callbacks(
        sendToClient: { _, _ in
            await counter.increment()
            return .delivered
        },
        disconnectClient: { _ in
            await counter.increment()
        },
        onClientAuthenticated: { _, _, _ in
            await counter.increment()
        }
    )
}

#endif // DEBUG
#endif // canImport(UIKit)
