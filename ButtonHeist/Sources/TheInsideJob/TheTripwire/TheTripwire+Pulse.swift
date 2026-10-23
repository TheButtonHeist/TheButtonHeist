#if canImport(UIKit)
#if DEBUG
import UIKit

extension TheTripwire {

    // MARK: - Pulse State

    /// Mutable context that exists only while the pulse is running.
    /// Reference type so tick mutations don't require enum reconstruction.
    @MainActor
    final class RunningContext {
        private let displayLink: CADisplayLink
        private let target: PulseTick
        var admission = PulseAdmission()
        var observationDemand: TickDemand?
        var receiveObservationPulse: (@MainActor (PulseReading) -> Void)?

        var displayFrameRateRange: CAFrameRateRange? {
            displayLink.preferredFrameRateRange
        }

        init(tripwire: TheTripwire) {
            target = PulseTick(tripwire: tripwire)
            displayLink = CADisplayLink(
                target: target,
                selector: #selector(PulseTick.handleTick)
            )
            displayLink.preferredFrameRateRange = TheTripwire.pulseFrameRateRange
            displayLink.add(to: .main, forMode: .common)
            displayLink.isPaused = true
        }

        func stop() {
            displayLink.invalidate()
        }

        func updateDisplayLink(
            frameRateRange: CAFrameRateRange,
            isPaused: Bool
        ) {
            displayLink.preferredFrameRateRange = frameRateRange
            displayLink.isPaused = isPaused
        }
    }

    enum PulsePhase {
        case idle
        case running(RunningContext)
    }

    enum TickDemand: Equatable, Sendable {
        case ambient
        case immediate
    }

    // MARK: - Pulse Lifecycle

    var isPulseRunning: Bool { runningContext != nil }

    func startPulse() {
        guard case .idle = pulsePhase else { return }
        pulsePhase = .running(RunningContext(tripwire: self))
    }

    func stopPulse() {
        guard let context = runningContext else { return }
        context.stop()
        context.receiveObservationPulse = nil
        context.observationDemand = nil

        pulsePhase = .idle
    }

    // MARK: - Pulse Delivery

    /// Installs the semantic observation stream as the single durable pulse
    /// consumer. Demand controls whether the display link runs; the callback
    /// never performs work inline with the display-link invocation.
    func observePulses(
        _ receive: @escaping @MainActor (PulseReading) -> Void
    ) {
        guard let context = runningContext else { return }
        precondition(
            context.receiveObservationPulse == nil,
            "Only one semantic observation pulse consumer may be active"
        )
        context.receiveObservationPulse = receive
        updateDisplayLinkRate(context)
    }

    func stopObservingPulses() {
        guard let context = runningContext else { return }
        context.receiveObservationPulse = nil
        context.observationDemand = nil
        updateDisplayLinkRate(context)
    }

    func setObservationPulseDemand(_ demand: TickDemand?) {
        guard let context = runningContext,
              context.observationDemand != demand else { return }
        context.observationDemand = demand
        updateDisplayLinkRate(context)
    }

    /// Gives UIKit a render opportunity after a successful synthetic touch-up.
    func deferObservationForRendering() {
        runningContext?.admission.deferForRendering()
    }

    /// Applies render grace immediately before a live capture can claim evidence.
    func admitObservationPulse(_ reading: PulseReading) -> Bool {
        runningContext?.admission.admit(reading.tripwireSignal.hierarchy) == true
    }

    func recordObservationDuration(_ duration: Duration, frameDuration: Duration) {
        runningContext?.admission.recordCapture(duration: duration, frameDuration: frameDuration)
    }

    // MARK: - Tick Handler

    /// Samples live UIKit and the display-frame budget for the observation stream.
    func captureDisplayLinkPulse(from displayLink: CADisplayLink) {
        guard let context = runningContext else { return }
        let reading = PulseReading(
            frameDuration: .seconds(displayLink.duration),
            tripwireSignal: tripwireSignal()
        )

        context.receiveObservationPulse?(reading)
    }

    private func updateDisplayLinkRate(_ context: RunningContext) {
        let range = context.observationDemand == .immediate
            ? Self.activeDisplayFrameRateRange(maximumFramesPerSecond: activeScreenMaximumFramesPerSecond())
            : Self.pulseFrameRateRange
        context.updateDisplayLink(
            frameRateRange: range,
            isPaused: context.observationDemand == nil
        )
    }

    private func activeScreenMaximumFramesPerSecond() -> Int {
        captureTraversableWindows()
            .lazy
            .compactMap { $0.window.windowScene?.screen.maximumFramesPerSecond }
            .first ?? 60
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
