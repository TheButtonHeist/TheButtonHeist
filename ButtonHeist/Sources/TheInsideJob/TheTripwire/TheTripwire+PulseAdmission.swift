#if canImport(UIKit)
#if DEBUG

extension TheTripwire {
    /// Bounds render grace and recovery from captures that exceed a display frame.
    struct PulseAdmission {
        private enum Recovery {
            case onePulse
            case twoPulses
        }

        private enum State {
            case initial
            case ready(HierarchySignal)
            case pending(Recovery)
            case yielding
        }

        private var state = State.initial

        mutating func recordCapture(duration: Duration, frameDuration: Duration) {
            precondition(frameDuration > .zero, "Display frame duration must be positive")
            guard duration > frameDuration else { return }
            state = .pending(duration > frameDuration * 2 ? .twoPulses : .onePulse)
        }

        mutating func deferForRendering() {
            switch state {
            case .initial, .ready:
                state = .pending(.onePulse)
            case .pending, .yielding:
                break
            }
        }

        mutating func admit(_ hierarchy: HierarchySignal) -> Bool {
            switch state {
            case .pending(.twoPulses):
                state = .pending(.onePulse)
                return false
            case .pending(.onePulse):
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
