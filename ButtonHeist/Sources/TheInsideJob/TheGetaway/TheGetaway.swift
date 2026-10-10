#if canImport(UIKit)
#if DEBUG
import UIKit

import ThePlans
@_spi(ButtonHeistInternals) import TheScore

/// The getaway driver — runs comms between the wire and the crew.
///
/// TheGetaway owns message routing between the transport and crew members.
/// Transport wiring, encoding, broadcast, and status construction live in
/// focused extension files so this root stays a coordinator.
@MainActor
final class TheGetaway {

    // MARK: - Crew References (not owned)

    let muscle: TheMuscle
    let brains: TheBrains

    /// Identity info provided by TheInsideJob for ServerInfo responses.
    struct ServerIdentity {
        let launchId: ServerLaunchID
        let effectiveInstanceId: InsideJobInstanceID
        var tlsActive: Bool
    }

    var identity: ServerIdentity
    let pongPayload: PongPayload
    let mainThreadProbe: TransportControlPlane.Probe

    struct TransportWiringAttempt {
        let transport: ServerTransport
        let delivery: ClientDelivery
    }

    struct TransportWiringBoundary {
        let beforeControlPlaneAdmission: @MainActor @Sendable (
            TransportWiringAttempt
        ) async -> Void

        static let immediate = TransportWiringBoundary(
            beforeControlPlaneAdmission: { _ in }
        )
    }

    enum TransportWiringOutcome {
        case admitted(TransportWiringAttempt)
        case rejected
    }

    struct WiredTransport {
        let attempt: TransportWiringAttempt
        let controlPlane: TransportControlPlane
        let mainActorEvents: AsyncStream<TransportControlPlane.MainActorEvent>.Continuation
        let mainActorConsumer: Task<Void, Never>
    }

    enum TransportWiringState {
        case unwired
        case wiring(
            TransportWiringAttempt,
            cleanup: Task<Void, Never>?
        )
        case wired(WiredTransport)

        var transport: ServerTransport? {
            switch self {
            case .unwired:
                nil
            case .wiring(let attempt, _):
                attempt.transport
            case .wired(let session):
                session.attempt.transport
            }
        }

        var wired: WiredTransport? {
            guard case .wired(let session) = self else { return nil }
            return session
        }

        var cleanup: Task<Void, Never>? {
            guard case .wiring(_, let cleanup) = self else { return nil }
            return cleanup
        }

        var delivery: ClientDelivery? {
            switch self {
            case .unwired:
                nil
            case .wiring(let attempt, _):
                attempt.delivery
            case .wired(let session):
                session.attempt.delivery
            }
        }

        func admits(_ attempt: TransportWiringAttempt) -> Bool {
            guard case .wiring(let current, _) = self else { return false }
            return current.delivery === attempt.delivery
        }

        func admitsEvent(delivery: ClientDelivery) -> Bool {
            guard case .wired(let current) = self else { return false }
            return current.attempt.delivery === delivery
        }
    }

    /// Transport wiring is one explicit state machine so teardown cannot leave a
    /// stale transport or consumer behind while control-plane admission is suspended.
    var transportWiring: TransportWiringState = .unwired
    let transportWiringBoundary: TransportWiringBoundary

    var transport: ServerTransport? {
        transportWiring.transport
    }

    // MARK: - Init

    init(
        muscle: TheMuscle,
        brains: TheBrains,
        identity: ServerIdentity,
        transportWiringBoundary: TransportWiringBoundary = .immediate,
        mainThreadProbe: @escaping TransportControlPlane.Probe = {
            try await MainThreadProbe.execute($0)
        }
    ) {
        self.muscle = muscle
        self.brains = brains
        self.identity = identity
        self.pongPayload = Self.capturePongPayload(identity: identity)
        self.transportWiringBoundary = transportWiringBoundary
        self.mainThreadProbe = mainThreadProbe
    }

    // MARK: - Message Execution

    func executeClientMessage(
        _ admitted: AdmittedClientMessage,
        respond: @escaping SocketResponseHandler,
        delivery: ClientDelivery
    ) async {
        let envelope = admitted.envelope
        let requestId = envelope.requestId
        let message = envelope.message

        switch message {
        case .clientHello, .authenticate, .ping, .mainThreadProbe:
            insideJobLogger.fault("Protocol message reached app dispatch after admission")
            await sendMessage(
                .error(ServerError(
                    kind: .validationError,
                    message: "Transport-control messages are handled before app dispatch."
                )),
                requestId: requestId,
                respond: respond,
                delivery: delivery
            )
        case .requestInterface(let query):
            await sendInterface(
                query: query,
                requestId: requestId,
                respond: respond,
                delivery: delivery
            )
        case .status:
            await sendMessage(
                .status(await captureStatus()),
                requestId: requestId,
                respond: respond,
                delivery: delivery
            )

        // Observation
        case .getPasteboard:
            let result = brains.executePasteboardRead()
            await sendMessage(
                .actionResult(result),
                requestId: requestId,
                respond: respond,
                delivery: delivery
            )
        case .getNotifications:
            await sendMessage(
                .notifications(brains.notifications()),
                requestId: requestId,
                respond: respond,
                delivery: delivery
            )
        case .requestScreen(let payload):
            await sendScreen(
                payload,
                requestId: requestId,
                respond: respond,
                delivery: delivery
            )
        case .runtimeAction(let command):
            let actionResult = await executeDirectRuntimeAction(command)
            await sendMessage(
                .actionResult(actionResult),
                requestId: requestId,
                respond: respond,
                delivery: delivery
            )
        case .heistPlan(let run):
            let message: ServerMessage = switch await brains.executeHeistPlan(
                run.plan,
                argument: run.argument,
                timeout: run.timeout,
                actionExpectationTimeoutPolicy: run.actionExpectationTimeoutPolicy
            ) {
            case .success(let result):
                .heistResult(result)
            case .failure(let failure):
                .error(failure.serverError)
            }
            await sendMessage(
                message,
                requestId: requestId,
                respond: respond,
                delivery: delivery
            )
        }
    }

    func executeDirectRuntimeAction(_ command: HeistActionCommand) async -> ActionResult {
        guard command.durableHeistActionFailure != nil else {
            return .failure(
                payload: command.actionResultPayload,
                failureKind: .validationError,
                message: "Direct runtimeAction accepts only transient non-durable commands; durable commands must run as heistPlan"
            )
        }
        guard brains.semanticObservationIsActive else {
            return brains.runtimeInactiveResult(payload: command.actionResultPayload)
        }
        return await brains.executeRuntimeAction(command)
    }

    func sendInterface(
        query: InterfaceQuery = InterfaceQuery(),
        requestId: RequestID? = nil,
        respond: @escaping SocketResponseHandler,
        delivery: ClientDelivery
    ) async {
        switch await brains.observeInterface(query) {
        case .success(let interface):
            await sendMessage(
                .interface(interface),
                requestId: requestId,
                respond: respond,
                delivery: delivery
            )
        case .failure(let error):
            let message: ServerErrorMessage
            do {
                message = try ServerErrorMessage(validating: error.message)
            } catch {
                insideJobLogger.error("Failed to admit interface error response: \(error)")
                return
            }
            await sendMessage(
                .error(ServerError(kind: .general, message: message)),
                requestId: requestId,
                respond: respond,
                delivery: delivery
            )
        }
    }

    // MARK: - InterfaceObservation Capture

    func sendScreen(
        _ request: ScreenRequestPayload,
        requestId: RequestID? = nil,
        respond: @escaping SocketResponseHandler,
        delivery: ClientDelivery
    ) async {
        let deadline = SemanticObservationDeadline(
            start: RuntimeElapsed.now,
            timeout: .seconds(request.timeout.seconds)
        )
        switch await brains.captureScreenPayload(
            mode: request.mode,
            observationBoundary: .externalDeadline(deadline)
        ) {
        case .success(let payload):
            await sendMessage(
                .screen(payload),
                requestId: requestId,
                respond: respond,
                delivery: delivery
            )
        case .failure(let failure):
            let message: ServerErrorMessage
            do {
                message = try ServerErrorMessage(validating: failure.message)
            } catch {
                insideJobLogger.error("Failed to admit screen-capture error response: \(error)")
                return
            }
            await sendMessage(
                .error(ServerError(kind: .general, message: message)),
                requestId: requestId,
                respond: respond,
                delivery: delivery
            )
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
