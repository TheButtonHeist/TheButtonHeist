#if canImport(UIKit)
#if DEBUG
import UIKit

extension TheTripwire {
    /// UIKit signal and display-frame budget for one observation cycle.
    struct PulseReading: Sendable, Equatable {
        let frameDuration: Duration
        let tripwireSignal: TripwireSignal
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
