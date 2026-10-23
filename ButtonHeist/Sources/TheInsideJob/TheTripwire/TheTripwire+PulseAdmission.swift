#if canImport(UIKit)
#if DEBUG

extension TheTripwire {
    /// Admits live capture pulses after giving newly changed UIKit a render opportunity.
    struct PulseAdmission {
        private enum State {
            case initial
            case ready(HierarchySignal)
            case awaitingRender
            case yielding
        }

        private var state = State.initial

        mutating func deferForRendering() {
            guard case .yielding = state else {
                state = .awaitingRender
                return
            }
        }

        mutating func admit(_ hierarchy: HierarchySignal) -> Bool {
            switch state {
            case .awaitingRender:
                state = .yielding
                return false
            case .ready(let previous) where previous != hierarchy:
                state = .yielding
                return false
            case .initial, .ready, .yielding:
                state = .ready(hierarchy)
                return true
            }
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
