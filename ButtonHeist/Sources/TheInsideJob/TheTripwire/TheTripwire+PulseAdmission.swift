#if canImport(UIKit)
#if DEBUG

extension TheTripwire {
    /// Bounds render grace and recovery from captures that exceed a display frame.
    struct PulseAdmission {
        private enum Recovery {
            case onePulse
            case twoPulses
        }

        private enum RenderGrace {
            case initial
            case ready(HierarchySignal)
            case pending
            case yielding
        }

        private var renderGrace = RenderGrace.initial
        private var recovery: Recovery?

        mutating func recordCapture(duration: Duration, frameDuration: Duration) {
            precondition(frameDuration > .zero, "Display frame duration must be positive")
            guard duration > frameDuration else { return }
            recovery = duration > frameDuration * 2 ? .twoPulses : .onePulse
        }

        mutating func cancelRecovery() {
            recovery = nil
        }

        mutating func deferForRendering() {
            switch renderGrace {
            case .initial, .ready:
                renderGrace = .pending
            case .pending, .yielding:
                break
            }
        }

        mutating func admit(_ hierarchy: HierarchySignal) -> Bool {
            if let recovery {
                self.recovery = recovery == .twoPulses ? .onePulse : nil
                renderGrace = .yielding
                return false
            }
            switch renderGrace {
            case .pending:
                renderGrace = .yielding
                return false
            case .ready(let previous) where previous != hierarchy:
                renderGrace = .yielding
                return false
            case .initial, .ready, .yielding:
                renderGrace = .ready(hierarchy)
                return true
            }
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
