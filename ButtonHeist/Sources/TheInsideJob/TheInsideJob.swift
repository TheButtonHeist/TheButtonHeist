#if canImport(UIKit)
#if DEBUG
import UIKit
import os.log

import ButtonHeistSupport
import TheScore

let insideJobLogger = ButtonHeistLog.logger(.insideJob(.server))

public enum InsideJobStopOutcome: Sendable, Equatable {
    case stopped
    case teardownTimedOut
}

/// The job itself: resolves startup/runtime configuration, assembles the crew,
/// and coordinates transport start/stop with the app lifecycle.
@MainActor
public final class TheInsideJob {

    // MARK: - Singleton

    enum SharedState {
        case unconfigured
        case configured(InsideJobRuntimeConfiguration)
        case live(TheInsideJob)

        mutating func configure(
            _ resolve: () throws(InsideJobConfigurationError) -> InsideJobRuntimeConfiguration
        ) throws(InsideJobConfigurationError) {
            switch self {
            case .unconfigured:
                self = .configured(try resolve())
            case .configured:
                throw .alreadyConfigured
            case .live:
                throw .alreadyLive
            }
        }
    }

    private static var sharedState: SharedState = .unconfigured

    public static var shared: TheInsideJob {
        switch sharedState {
        case .live(let existing):
            return existing
        case .configured(let runtimeConfiguration):
            let instance = TheInsideJob(
                runtimeConfiguration: runtimeConfiguration
            )
            sharedState = .live(instance)
            return instance
        case .unconfigured:
            let instance = TheInsideJob(
                runtimeConfiguration: InsideJobRuntimeConfiguration.resolve()
            )
            sharedState = .live(instance)
            return instance
        }
    }

    public static func configure(
        token: String? = nil,
        instanceId: String? = nil,
        allowedScopes: Set<ConnectionScope>? = nil,
        port: UInt16 = 0,
        addressFamily: ListenerAddressFamily = .dualStack,
        fingerprintsEnabled: Bool? = nil,
        authenticationPolicy: InsideJobAuthenticationPolicy = .default
    ) throws(InsideJobConfigurationError) {
        try sharedState.configure { () throws(InsideJobConfigurationError) -> InsideJobRuntimeConfiguration in
            try InsideJobRuntimeConfiguration.resolve(
                token: token,
                instanceId: instanceId,
                allowedScopes: allowedScopes,
                port: port,
                addressFamily: addressFamily,
                fingerprintsEnabled: fingerprintsEnabled,
                authenticationPolicy: authenticationPolicy
            )
        }
    }

    static func configure(
        runtimeConfiguration: InsideJobRuntimeConfiguration
    ) throws(InsideJobConfigurationError) {
        try sharedState.configure { runtimeConfiguration }
    }

    // MARK: - Properties

    private var lifecycle = StateStore(
        initial: ServerPhase.stopped,
        reducer: InsideJobLifecycleReducer()
    )
    var lifecycleObservation = LifecycleObservationState.uninstalled

    var serverPhase: ServerPhase {
        lifecycle.state
    }

    let muscle: TheMuscle
    let tripwire = TheTripwire()
    let brains: TheBrains
    let getaway: TheGetaway

    let runtimeConfiguration: InsideJobRuntimeConfiguration
    let transportProvider: @MainActor (SessionAuthToken, Set<ConnectionScope>) -> ServerTransport
    let lifecycleBoundaryTasks = TaskTracker()

    // MARK: - Computed State

    var isRunning: Bool {
        switch serverPhase {
        case .starting, .running, .suspending, .suspended, .resuming, .stopping: return true
        case .stopped:
            return false
        }
    }

    var transport: ServerTransport? {
        switch serverPhase {
        case .running(let resources):
            return resources.transport
        case .suspending(let suspension):
            return suspension.resources.transport
        case .starting, .stopping, .stopped, .suspended, .resuming:
            return nil
        }
    }

    var lifecycleObservationIsInstalled: Bool {
        lifecycleObservation.isInstalled
    }

    var retainedIdleTimerBaseline: Bool? {
        switch serverPhase {
        case .running(let resources):
            return resources.idleTimerBaseline
        case .suspending(let suspension):
            return suspension.resources.idleTimerBaseline
        case .suspended(let suspended):
            return suspended.idleTimerBaseline
        case .resuming(let attempt):
            return attempt.suspendedRuntime.idleTimerBaseline
        case .starting, .stopped, .stopping:
            return nil
        }
    }

    /// Port currently bound by the InsideJob TCP listener, if the runtime is
    /// running or suspending. This is primarily useful for app-hosted XCTest
    /// live-driving probes that start the server manually because auto-start is
    /// disabled under XCTest.
    public var listeningPort: UInt16? {
        switch serverPhase {
        case .running(let resources):
            return resources.actualPort
        case .suspending(let suspension):
            return suspension.resources.actualPort
        case .starting, .stopped, .suspended, .resuming, .stopping:
            return nil
        }
    }

    @discardableResult
    func applyLifecycleEvent(
        _ event: InsideJobLifecycleReducer.Event
    ) -> StateTransition<ServerPhase, InsideJobLifecycleReducer.Effect, InsideJobLifecycleReducer.Rejection> {
        lifecycle.reduce(event)
    }

    // MARK: - Initialization

    public convenience init(
        token: String? = nil,
        instanceId: String? = nil,
        allowedScopes: Set<ConnectionScope>? = nil,
        port: UInt16 = 0,
        addressFamily: ListenerAddressFamily = .dualStack,
        fingerprintsEnabled: Bool? = nil,
        authenticationPolicy: InsideJobAuthenticationPolicy = .default
    ) throws(InsideJobConfigurationError) {
        try self.init(
            token: token,
            instanceId: instanceId,
            allowedScopes: allowedScopes,
            port: port,
            addressFamily: addressFamily,
            fingerprintsEnabled: fingerprintsEnabled,
            authenticationPolicy: authenticationPolicy,
            transportProvider: { ServerTransport(token: $0, allowedScopes: $1) }
        )
    }

    convenience init(
        token: String? = nil,
        instanceId: String? = nil,
        allowedScopes: Set<ConnectionScope>? = nil,
        port: UInt16 = 0,
        addressFamily: ListenerAddressFamily = .dualStack,
        fingerprintsEnabled: Bool? = nil,
        authenticationPolicy: InsideJobAuthenticationPolicy = .default,
        visibleObservationSource: @escaping TheVault.VisibleObservationSource = TheVault.captureVisibleObservation,
        transportWiringBoundary: TheGetaway.TransportWiringBoundary = .immediate,
        transportProvider: @escaping @MainActor (SessionAuthToken, Set<ConnectionScope>) -> ServerTransport = {
            ServerTransport(token: $0, allowedScopes: $1)
        }
    ) throws(InsideJobConfigurationError) {
        self.init(
            runtimeConfiguration: try InsideJobRuntimeConfiguration.resolve(
                token: token,
                instanceId: instanceId,
                allowedScopes: allowedScopes,
                port: port,
                addressFamily: addressFamily,
                fingerprintsEnabled: fingerprintsEnabled,
                authenticationPolicy: authenticationPolicy
            ),
            visibleObservationSource: visibleObservationSource,
            transportWiringBoundary: transportWiringBoundary,
            transportProvider: transportProvider
        )
    }

    init(
        runtimeConfiguration: InsideJobRuntimeConfiguration,
        visibleObservationSource: @escaping TheVault.VisibleObservationSource = TheVault.captureVisibleObservation,
        transportWiringBoundary: TheGetaway.TransportWiringBoundary = .immediate,
        transportProvider: @escaping @MainActor (SessionAuthToken, Set<ConnectionScope>) -> ServerTransport = {
            ServerTransport(token: $0, allowedScopes: $1)
        }
    ) {
        self.runtimeConfiguration = runtimeConfiguration
        self.transportProvider = transportProvider
        self.muscle = TheMuscle(
            sessionToken: runtimeConfiguration.token.value,
            sessionReleaseTimeout: runtimeConfiguration.sessionReleaseTimeout.value,
            authenticationPolicy: runtimeConfiguration.authenticationPolicy
        )
        self.brains = TheBrains(
            tripwire: self.tripwire,
            fingerprintsEnabled: runtimeConfiguration.fingerprintsEnabled.value,
            failureEvidencePolicy: runtimeConfiguration.failureEvidencePolicy.value,
            visibleObservationSource: visibleObservationSource
        )
        self.getaway = TheGetaway(
            muscle: self.muscle,
            brains: self.brains,
            identity: TheGetaway.ServerIdentity(
                launchId: runtimeConfiguration.sessionIdentity.launchId,
                effectiveInstanceId: runtimeConfiguration.sessionIdentity.effectiveInstanceId.value,
                tlsActive: false
            ),
            transportWiringBoundary: transportWiringBoundary
        )
    }

    // MARK: - Public API

    public func start() async throws {
        await awaitPendingLifecycleTasks()

        guard case .stopped = serverPhase else { return }

        let attemptID = UUID()
        let request = InsideJobTransportStartRequest(
            id: attemptID,
            transport: makeRuntimeTransport(),
            idleTimerBaseline: UIApplication.shared.isIdleTimerDisabled
        )
        let startChange = applyLifecycleEvent(.startRequested(request))
        guard case .changed = startChange else { return }

        do {
            let resources = try await startRuntimeResources(for: request)
            let finishChange = applyLifecycleEvent(.startSucceeded(attemptID, resources))
            guard case .running = finishChange.state else {
                await performLifecycleEffect(.cleanupTransport(resources.transport))
                throw CancellationError()
            }
            await performLifecycleEffects(finishChange.effects)
            logStartupSummary(
                actualPort: resources.actualPort,
                bonjourServiceName: resources.bonjourServiceName
            )
        } catch {
            let failureChange = applyLifecycleEvent(.startFailed(attemptID))
            switch failureChange {
            case .changed:
                await performLifecycleEffects(failureChange.effects)
            case .rejected:
                await performLifecycleEffect(.cleanupTransport(request.transport))
            }
            throw error
        }

        guard case .running = serverPhase else {
            throw CancellationError()
        }

    }

    @discardableResult
    public func stop() async -> InsideJobStopOutcome {
        let outcome = await stopRuntime()
        if case .teardownTimedOut = outcome {
            insideJobLogger.error("Server teardown timed out")
        }
        return outcome
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
