#if canImport(UIKit)
#if DEBUG
import UIKit

/// Detects UIKit tripwire triggers without touching the accessibility tree.
///
/// TheTripwire monitors UIKit signals via one persistent CADisplayLink tick.
/// Ambient observation runs at a low rate; active demand raises that same link
/// to at most 30 Hz. Each tick samples controller identity, public navigation
/// state, and ordered visible windows. Pulse admission yields one capture after
/// touch-up or hierarchy change, and at most two after an over-budget capture.
///
/// The accessibility tree is TheVault's domain; TheTripwire never reads it.
@MainActor
final class TheTripwire {

    var pulsePhase: PulsePhase = .idle

    var runningContext: RunningContext? {
        if case .running(let context) = pulsePhase { return context }
        return nil
    }

    /// Window classes iOS uses for system-managed UI decorations that sit
    /// above `windowLevel.normal` but contain no app content the agent can
    /// usefully act on. Treating them as the topmost overlay would hide the
    /// real app window beneath, which is the common cause of "0 elements"
    /// snapshots while a software keyboard is up. `nonisolated` so the
    /// passthrough check can run as a plain `(UIWindow) -> Bool` — the data
    /// is immutable and touches no main-actor state.
    nonisolated static let systemPassthroughWindowClassNames: Set<String> = [
        "UIRemoteKeyboardWindow",
        "UITextEffectsWindow",
    ]

    static var pulseFrameRateRange: CAFrameRateRange {
        pulseFrameRateRange(knobs: .current)
    }

    static func pulseFrameRateRange(knobs: ButtonHeistRuntimeKnobs) -> CAFrameRateRange {
        let preferred = knobs.tripwirePulseFramesPerSecond
        let minimum = max(1, Int((Double(preferred) * 0.8).rounded(.down)))
        let maximum = max(preferred, Int((Double(preferred) * 1.2).rounded(.up)))
        return CAFrameRateRange(
            minimum: Float(minimum),
            maximum: Float(maximum),
            preferred: Float(preferred)
        )
    }

    static func activeDisplayFrameRateRange(maximumFramesPerSecond: Int) -> CAFrameRateRange {
        precondition(maximumFramesPerSecond > 0, "display refresh rate must be positive")
        let maximum = Float(min(30, maximumFramesPerSecond))
        return CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
