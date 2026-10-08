#if canImport(UIKit)
#if DEBUG
import UIKit

@MainActor
extension TheInsideJob {
    func activateRuntime() {
        getaway.identity.tlsActive = true

        installLifecycleObservationIfNeeded()
        engageIdleTimerProtection()

        tripwire.startPulse()
        brains.vault.semanticObservationStream.start()
        brains.safecracker.startKeyboardObservation()
    }

    func releaseRuntimeOwnedResources(policy: RuntimeReleasePolicy, idleTimerBaseline: Bool) {
        switch policy {
        case .suspend:
            restoreIdleTimerProtection(to: idleTimerBaseline)
        case .stop:
            stopLifecycleObservationIfNeeded()
            restoreIdleTimerProtection(to: idleTimerBaseline)
        }

        brains.vault.semanticObservationStream.stop()
        tripwire.stopPulse()
        brains.safecracker.stopKeyboardObservation()
    }

    func engageIdleTimerProtection() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func restoreIdleTimerProtection(to baseline: Bool) {
        UIApplication.shared.isIdleTimerDisabled = baseline
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
