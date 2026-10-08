#if canImport(UIKit)
#if DEBUG
import Foundation
import UIKit

import TheScore

@MainActor
extension TheInsideJob {
    func makeRuntimeTransport() -> ServerTransport {
        return transportProvider(runtimeConfiguration.token.value, runtimeConfiguration.allowedScopes.value)
    }

    func stopRuntime() async -> InsideJobStopOutcome {
        let requestedAttempt = InsideJobStopAttempt(id: UUID())
        let change = applyLifecycleEvent(.stopRequested(requestedAttempt))
        let attempt: InsideJobStopAttempt

        if change.effects.isEmpty {
            guard case .stopping(let activeAttempt) = serverPhase else {
                return .stopped
            }
            attempt = activeAttempt
        } else {
            attempt = requestedAttempt
            let effects = change.effects
            spawnLifecycleTask { [weak self] in
                guard let self else {
                    requestedAttempt.finish()
                    return
                }
                await self.performLifecycleEffects(effects)
                let finishChange = self.applyLifecycleEvent(.stopFinished(requestedAttempt.id))
                await self.performLifecycleEffects(finishChange.effects)
                requestedAttempt.finish()
            }
        }

        return await attempt.waitForCompletion() ? .stopped : .teardownTimedOut
    }

    func startRuntimeResources(
        for request: InsideJobTransportStartRequest
    ) async throws -> InsideJobRuntimeResources {
        let wiringOutcome = await getaway.wireTransport(request.transport) { [weak self] maxEvents in
            await self?.handleTransportEventBacklogOverflow(maxEvents: maxEvents)
        }
        guard case .admitted(let wiredTransport) = wiringOutcome else {
            throw CancellationError()
        }

        let exposure = ServerExposure(
            allowedScopes: runtimeConfiguration.allowedScopes.value,
            addressFamily: runtimeConfiguration.addressFamily
        )
        let actualPort = try await wiredTransport.transport.start(
            port: runtimeConfiguration.preferredPort.value,
            bindToLoopback: exposure.bindsToLoopbackOnly,
            addressFamily: exposure.addressFamily
        )
        let serviceName = advertiseService(on: wiredTransport.transport, port: actualPort)
        let resources = InsideJobRuntimeResources(
            transport: wiredTransport.transport,
            actualPort: actualPort,
            bonjourServiceName: serviceName,
            idleTimerBaseline: request.idleTimerBaseline
        )
        return resources
    }

    func handleTransportEventBacklogOverflow(maxEvents: Int) async {
        insideJobLogger.error("Transport event backlog exceeded \(maxEvents), stopping server")
        spawnLifecycleTask { [weak self] in
            await self?.stop()
        }
    }

    func cleanupFailedTransportStartup(_ transport: ServerTransport?) async {
        if let transport {
            await transport.stop()
            await getaway.tearDownIfWired(to: transport)
        }
        getaway.identity.tlsActive = false
    }

    func performLifecycleEffects(_ effects: [InsideJobLifecycleReducer.Effect]) async {
        for effect in effects {
            await performLifecycleEffect(effect)
        }
    }

    func performLifecycleSchedulingEffects(_ effects: [InsideJobLifecycleReducer.Effect]) {
        guard !effects.isEmpty else { return }
        spawnLifecycleTask { [weak self] in
            await self?.performLifecycleEffects(effects)
        }
    }

    func performLifecycleEffect(_ effect: InsideJobLifecycleReducer.Effect) async {
        switch effect {
        case .scheduleSuspend:
            await suspend()
        case .scheduleResume(let attempt):
            if let attempt {
                await performLifecycleEffect(.cancelResume(attempt))
            }
            await resumeAfterLifecycleBoundary()
        case .scheduleStop:
            await stop()
        case .stopTransport(let transport):
            await transport.stop()
        case .cleanupTransport(let transport):
            await cleanupFailedTransportStartup(transport)
        case .releaseResources(let policy, let idleTimerBaseline):
            releaseRuntimeOwnedResources(policy: policy, idleTimerBaseline: idleTimerBaseline)
        case .cancelResume(let attempt):
            attempt.task.cancel()
            await attempt.task.value
        case .activateRuntime:
            activateRuntime()
        case .tearDownRuntimeServices:
            await getaway.tearDown()
            await muscle.tearDown()
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
