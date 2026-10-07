#if canImport(UIKit)
#if DEBUG
import Foundation
import ButtonHeistSupport
import UIKit
import os

import TheScore

private struct SessionReleaseTimer {
    private enum State {
        case idle(generation: UInt64)
        case scheduled(task: Task<Void, Never>, generation: UInt64)
    }

    private var state: State = .idle(generation: 0)

    var task: Task<Void, Never>? {
        switch state {
        case .idle:
            return nil
        case .scheduled(let task, _):
            return task
        }
    }

    mutating func replace(
        timeout: TimeInterval,
        onExpired: @escaping @Sendable (UInt64) async -> Void
    ) {
        cancel()
        let scheduledGeneration = generation
        let task = Task { [timeout, scheduledGeneration] in
            guard await Task.cancellableSleep(for: .seconds(timeout)) else { return }
            guard !Task.isCancelled else { return }
            await onExpired(scheduledGeneration)
        }
        state = .scheduled(task: task, generation: scheduledGeneration)
    }

    mutating func cancel() {
        task?.cancel()
        state = .idle(generation: generation &+ 1)
    }

    func isCurrentScheduledGeneration(_ generation: UInt64) -> Bool {
        switch state {
        case .idle:
            return false
        case .scheduled(_, let scheduledGeneration):
            return scheduledGeneration == generation
        }
    }

    private var generation: UInt64 {
        switch state {
        case .idle(let generation), .scheduled(_, let generation):
            return generation
        }
    }
}

/// Orchestrates client registration, admission, delivery, and disconnects.
actor TheMuscle {

    private static let disconnectGracePeriod: Duration = .milliseconds(100)
    private static let authTimeoutSeconds: UInt64 = 10
    private var admission: ClientAdmission.Reducer
    private var session: SessionLease
    private var delivery: ClientDelivery = .idle(latest: nil)
    private var sessionReleaseTimer = SessionReleaseTimer()

    private var delayedDisconnects = ClientAdmission.DelayedDisconnects(
        gracePeriod: TheMuscle.disconnectGracePeriod
    )
    private let authenticationTimeouts = ClientAdmission.Timeout.Deadlines(
        deadline: .seconds(TheMuscle.authTimeoutSeconds)
    )

    // MARK: - Init

    /// Caller must be on `@MainActor` because runtime assembly is MainActor-isolated.
    @MainActor
    init(
        sessionToken: SessionAuthToken,
        sessionReleaseTimeout: TimeInterval,
        authenticationPolicy: InsideJobAuthenticationPolicy = .default
    ) {
        self.admission = ClientAdmission.Reducer(
            sessionToken: sessionToken,
            authenticationPolicy: authenticationPolicy
        )
        self.session = SessionLease(
            releaseTimeout: sessionReleaseTimeout
        )
    }

    // MARK: - Test Seams

    /// Test seam: wait for the currently scheduled session release timer.
    func awaitSessionReleaseTimerForTesting() async {
        let timer = sessionReleaseTimer.task
        await timer?.value
    }

    /// Test seam: whether a session release timer is currently scheduled.
    var hasSessionReleaseTimerForTesting: Bool {
        sessionReleaseTimer.task != nil
    }

    /// Owner that currently holds the session (nil = no active session).
    var sessionOwner: SessionOwner? {
        session.activeSessionOwner
    }

    var exposedDriverId: DriverID? {
        session.exposedDriverId
    }

    /// Client IDs belonging to the active session.
    var activeSessionConnections: Set<Int> {
        session.activeSessionConnections
    }

    /// Whether a driver session is currently active on this Inside Job instance.
    var isSessionActive: Bool {
        session.isSessionActive
    }

    /// Number of active connections participating in the session.
    var activeSessionConnectionCount: Int {
        session.activeSessionConnectionCount
    }

    var callbackDeliveryGenerationForTesting: ClientDelivery.Generation? {
        delivery.generation
    }

    // MARK: - Callback Wiring

    @discardableResult
    func beginCallbackWiring(_ generation: ClientDelivery.Generation) -> ClientDelivery.BeginOutcome {
        delivery.begin(generation)
    }

    /// Install transport-facing callbacks. Called once by `TheGetaway.wireTransport`.
    @discardableResult
    func installCallbacks(
        sendToClient: @escaping @Sendable (Data, Int) async -> ServerSendOutcome,
        disconnectClient: @escaping @Sendable (Int) async -> Void,
        onClientAuthenticated: @escaping @MainActor @Sendable (Int, @escaping SocketResponseHandler) async -> Void,
        generation: ClientDelivery.Generation
    ) -> ClientDelivery.InstallOutcome {
        delivery.install(ClientDelivery.Callbacks(
            sendToClient: sendToClient,
            disconnectClient: disconnectClient,
            onClientAuthenticated: onClientAuthenticated
        ), for: generation)
    }

    func invalidateCallbacks(for generation: ClientDelivery.Generation) {
        delivery.invalidate(generation)
    }

    // MARK: - Public API

    /// Register the remote address for a client (called when TCP connection is established).
    func registerClientAddress(
        _ clientId: Int,
        address: ClientNetworkAddress,
        generation: ClientDelivery.Generation
    ) async {
        guard admitsCurrentGeneration(generation) else { return }
        await executeAdmissionEffects(
            admission.registerClientAddress(clientId, address: address),
            generation: generation
        )
    }

    @discardableResult
    func sendServerHello(
        clientId: Int,
        generation: ClientDelivery.Generation
    ) async -> ResponseDeliveryOutcome {
        await sendResponse(.serverHello, to: .client(clientId), generation: generation)
    }

    /// Send an already-encoded envelope to a single client.
    @discardableResult
    func sendData(_ data: Data, toClient clientId: Int) async -> ServerSendOutcome {
        guard admission.contains(clientId) else {
            return .failed(.clientNotFound(clientId))
        }
        guard let generation = delivery.generation else {
            return .failed(.transportUnavailable)
        }
        return await delivery.send(data, toClient: clientId, generation: generation)
    }

    @discardableResult
    func sendResponse(
        _ message: ServerMessage,
        requestId: RequestID? = nil,
        respond: @escaping SocketResponseHandler,
        generation: ClientDelivery.Generation
    ) async -> ResponseDeliveryOutcome {
        await sendResponse(
            message,
            requestId: requestId,
            to: .response(respond),
            generation: generation
        )
    }

    func disconnectClient(
        _ clientId: Int,
        generation: ClientDelivery.Generation
    ) async {
        _ = await delivery.disconnect(clientId, generation: generation)
    }

    func admitClientMessage(
        _ clientId: Int,
        data: Data,
        respond: @escaping SocketResponseHandler,
        generation: ClientDelivery.Generation
    ) async -> ClientAdmission {
        guard admitsCurrentGeneration(generation) else {
            return .handled
        }
        return await resolve(admission.admit(
            clientId,
            data: data,
            respond: respond
        ), generation: generation)
    }

    func handleClientDisconnected(
        _ clientId: Int,
        generation: ClientDelivery.Generation
    ) async {
        guard admitsCurrentGeneration(generation) else { return }
        await executeAdmissionEffects(admission.removeClient(clientId), generation: generation)
        applySessionEffects(session.removeConnection(clientId, at: Date()))
    }

    func tearDown() async {
        delivery.reset()
        await executeAdmissionEffects(admission.removeAllClients(), generation: nil)
        let disconnectGeneration = delayedDisconnects
        await disconnectGeneration.drain()
        if delayedDisconnects === disconnectGeneration {
            delayedDisconnects = ClientAdmission.DelayedDisconnects(gracePeriod: Self.disconnectGracePeriod)
        }
        await releaseSession()
    }

    // MARK: - Admission Orchestration

    private func resolve(
        _ decision: ClientAdmission.Decision,
        generation: ClientDelivery.Generation
    ) async -> ClientAdmission {
        switch decision {
        case .admitted(let message):
            return .admitted(message)
        case .handled(let effect):
            await executeAdmissionEffects(effect, generation: generation)
            return .handled
        case .sessionAdmission(let sessionAdmission):
            await admitSession(sessionAdmission, generation: generation)
            return .handled
        }
    }

    private func admitSession(
        _ sessionAdmission: ClientAdmission.SessionAdmission,
        generation: ClientDelivery.Generation
    ) async {
        switch session.acquire(
            owner: sessionAdmission.owner,
            clientId: sessionAdmission.clientId,
            at: Date()
        ) {
        case .accepted(let sessionEffect):
            applySessionEffects(sessionEffect)
            let effect = admission.completeAuthentication(sessionAdmission)
            await executeAdmissionEffects(effect, generation: generation)
            _ = await delivery.clientAuthenticated(
                sessionAdmission.clientId,
                respond: sessionAdmission.respond,
                generation: generation
            )

        case .rejected(let diagnostic):
            await executeAdmissionEffects(admission.rejectForSessionLock(
                sessionAdmission.clientId,
                diagnostic: diagnostic,
                respond: sessionAdmission.respond
            ), generation: generation)
        }
    }

    private func executeAdmissionEffects(
        _ effects: [ClientAdmission.Effect],
        generation: ClientDelivery.Generation?
    ) async {
        for effect in effects {
            if let generation,
               !admitsCurrentGeneration(generation) {
                return
            }
            switch effect {
            case .replaceAuthenticationDeadline(let clientId):
                guard let generation else {
                    preconditionFailure("Authentication deadlines require a callback generation")
                }
                authenticationTimeouts.replace(for: clientId) { [weak self] in
                    await self?.executeAuthenticationTimeout(clientId, generation: generation)
                }
            case .cancelAuthenticationDeadline(let clientId):
                authenticationTimeouts.cancel(clientId)
            case .cancelAllAuthenticationDeadlines:
                authenticationTimeouts.cancelAll()
            case .sendResponse(let message, let requestId, let respond):
                guard let generation else {
                    preconditionFailure("Transport responses require a callback generation")
                }
                await sendResponse(
                    message,
                    requestId: requestId,
                    to: .response(respond),
                    generation: generation
                )
            case .sendClient(let message, let requestId, let clientId):
                guard let generation else {
                    preconditionFailure("Client sends require a callback generation")
                }
                await sendResponse(
                    message,
                    requestId: requestId,
                    to: .client(clientId),
                    generation: generation
                )
            case .delayedDisconnect(let clientId):
                guard let generation else {
                    preconditionFailure("Delayed disconnects require a callback generation")
                }
                authenticationTimeouts.cancel(clientId)
                scheduleDelayedDisconnect(clientId, generation: generation)
            case .log(let event):
                recordAdmissionLog(event)
            }
        }
    }

    private func recordAdmissionLog(_ event: ClientAdmission.Log) {
        switch event {
        case .clientAuthenticatedWithToken(let clientId):
            muscleLogger.debug("Client \(clientId) authenticated with token")
        case .sessionLockRejected(let clientId, let message):
            muscleLogger.debug("Client \(clientId) rejected - \(message, privacy: .public)")
        case .rateLimited:
            break
        case .undecodableUnauthenticatedMessage(let clientId):
            muscleLogger.debug("Client \(clientId) sent unparsable message before authenticating")
        case .undecodableAuthenticatedMessage(let clientId):
            muscleLogger.debug("Authenticated client \(clientId) sent unparsable message")
        case .authenticatedProtocolMessage(let clientId, let wireType):
            muscleLogger.debug(
                "Authenticated client \(clientId) sent protocol message \(wireType.rawValue, privacy: .public) after admission"
            )
        case .unauthenticatedMessage(let clientId, let message):
            muscleLogger.debug("Client \(clientId) rejected before auth: \(message, privacy: .public)")
        case .authenticationTimeout(let clientId, let timeoutSeconds):
            muscleLogger.debug("Client \(clientId) did not authenticate within \(timeoutSeconds)s deadline")
        case .versionMismatch(let clientId, let serverVersion, let clientVersion):
            muscleLogger.warning(
                "Client \(clientId) buttonHeistVersion mismatch: server=\(serverVersion), client=\(clientVersion)"
            )
        case .missingRegisteredAddress(let clientId):
            muscleLogger.warning("Client \(clientId) has no registered address, rejecting auth")
        case .lockedOut(let clientId, let address):
            muscleLogger.debug("Client \(clientId) locked out (address: \(address)), rejecting")
        case .invalidToken:
            break
        case .lockoutStarted(let address, let attempts):
            muscleLogger.warning("Address \(address) locked out after \(attempts) failed attempts")
        }
    }

    // MARK: - Delayed Disconnect

    /// Schedule a delayed disconnect so the recipient can flush the final error payload.
    private func scheduleDelayedDisconnect(
        _ clientId: Int,
        generation: ClientDelivery.Generation
    ) {
        delayedDisconnects.schedule(clientId: clientId) { [weak self] in
            await self?.disconnectClient(clientId, generation: generation)
        }
    }

    // MARK: - Authentication Deadline

    private func executeAuthenticationTimeout(
        _ clientId: Int,
        generation: ClientDelivery.Generation
    ) async {
        guard admitsCurrentGeneration(generation) else { return }
        await executeAdmissionEffects(
            admission.authenticationTimeout(
                clientId,
                timeoutSeconds: Self.authTimeoutSeconds
            ),
            generation: generation
        )
    }

    // MARK: - Session Release

    private func sessionReleaseTimerFired(generation: UInt64) async {
        guard sessionReleaseTimer.isCurrentScheduledGeneration(generation) else { return }
        await releaseSession()
    }

    private func releaseSession() async {
        applySessionEffects(session.release())
    }

    private func applySessionEffects(_ effects: [SessionLease.Effect]) {
        for effect in effects {
            switch effect {
            case .log(let event):
                logSessionEvent(event)
            case .cancelReleaseTimer:
                cancelSessionReleaseTimer()
            case .replaceReleaseTimer(let timeout):
                replaceSessionReleaseTimer(timeout: timeout)
            }
        }
    }

    private func logSessionEvent(_ event: SessionLease.LogEvent) {
        switch event {
        case .sessionClaimed(let clientId):
            muscleLogger.info("Session claimed by client \(clientId)")
        case .clientRejoinedDuringGracePeriod(let clientId):
            muscleLogger.debug("Client \(clientId) rejoined session during grace period")
        case .sessionReleased:
            muscleLogger.info("Session released")
        case .releaseTimerStarted(let timeout):
            muscleLogger.debug("All session connections gone, starting \(timeout)s release timer")
        }
    }

    private func replaceSessionReleaseTimer(timeout: TimeInterval) {
        sessionReleaseTimer.replace(timeout: timeout) { [weak self] generation in
            await self?.sessionReleaseTimerFired(generation: generation)
        }
    }

    private func cancelSessionReleaseTimer() {
        sessionReleaseTimer.cancel()
    }

    // MARK: - Helpers

    private enum ResponseDestination: Sendable {
        case response(ClientAdmission.ResponseHandler)
        case client(Int)
    }

    @discardableResult
    private func sendResponse(
        _ message: ServerMessage,
        requestId: RequestID? = nil,
        to destination: ResponseDestination,
        generation: ClientDelivery.Generation
    ) async -> ResponseDeliveryOutcome {
        switch ResponseEnvelopeDelivery.encodeEnvelope(message, requestId: requestId) {
        case .success(let data):
            let sendOutcome: ServerSendOutcome
            switch destination {
            case .response(let respond):
                sendOutcome = await delivery.respond(
                    data,
                    using: respond,
                    generation: generation
                )
            case .client(let clientId):
                sendOutcome = await delivery.send(
                    data,
                    toClient: clientId,
                    generation: generation
                )
            }
            let outcome: ResponseDeliveryOutcome
            switch sendOutcome {
            case .delivered:
                outcome = .delivered
            case .failed(let failure):
                outcome = ResponseDeliveryOutcome(sendFailure: failure)
            }
            logResponseDeliveryOutcome(outcome)
            return outcome

        case .failure(let failure):
            let outcome = ResponseDeliveryOutcome.failed(.responseEncodingFailed(failure))
            logResponseDeliveryOutcome(outcome)
            return outcome
        }
    }

    private func logResponseDeliveryOutcome(_ outcome: ResponseDeliveryOutcome) {
        switch outcome {
        case .delivered:
            break
        case .refused(let failure), .failed(let failure):
            muscleLogger.error("\(failure.description)")
        case .transportUnavailable:
            muscleLogger.error("\(outcome.description)")
        }
    }

    private func admitsCurrentGeneration(_ candidate: ClientDelivery.Generation) -> Bool {
        delivery.isWired(generation: candidate)
    }
}
#endif // DEBUG
#endif // canImport(UIKit)
