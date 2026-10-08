#if canImport(UIKit)
#if DEBUG
import Foundation
import ButtonHeistSupport

struct SemanticObservationDeadline: Sendable, Equatable {
    let start: RuntimeElapsed.Instant
    let timeoutSeconds: Double

    init(start: RuntimeElapsed.Instant, timeoutSeconds: Double) {
        precondition(timeoutSeconds.isFinite && timeoutSeconds >= 0, "observation timeout must be finite and non-negative")
        self.start = start
        self.timeoutSeconds = timeoutSeconds
    }

    init(start: RuntimeElapsed.Instant, timeout: Duration) {
        self.init(start: start, timeoutSeconds: timeout / .seconds(1))
    }

    func hasTimeRemaining(at now: RuntimeElapsed.Instant) -> Bool {
        elapsedSeconds(at: now) < timeoutSeconds
    }

    /// The absolute instant at which this budget expires.
    var expiration: RuntimeElapsed.Instant {
        start.advanced(by: .saturatingSeconds(timeoutSeconds))
    }

    /// Chooses the original deadline whose absolute expiration is earlier.
    ///
    /// This intentionally returns one input unchanged instead of rebuilding a
    /// deadline from the remaining interval: result projection still needs the
    /// leaf's authored budget even when the enclosing heist expires first.
    func earlier(than other: Self) -> Self {
        expiration <= other.expiration ? self : other
    }

    func remainingSeconds(at now: RuntimeElapsed.Instant = RuntimeElapsed.now) -> Double {
        max(0, timeoutSeconds - elapsedSeconds(at: now))
    }

    func remainingDuration(at now: RuntimeElapsed.Instant = RuntimeElapsed.now) -> Duration {
        .saturatingSeconds(remainingSeconds(at: now))
    }

    var budgetMilliseconds: Int {
        Int((timeoutSeconds * 1_000).rounded(.up))
    }

    private func elapsedSeconds(at now: RuntimeElapsed.Instant) -> Double {
        max(0, start.duration(to: now) / .seconds(1))
    }

}

#endif // DEBUG
#endif // canImport(UIKit)
