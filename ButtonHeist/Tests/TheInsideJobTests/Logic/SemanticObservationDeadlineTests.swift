#if canImport(UIKit)
import XCTest
@testable import TheInsideJob

final class SemanticObservationDeadlineTests: XCTestCase {
    func testLargeFiniteTimeoutRemainsLiveAndProducesRepresentableSleep() {
        let now = RuntimeElapsed.now
        let deadline = SemanticObservationDeadline(
            start: now,
            timeoutSeconds: Double.greatestFiniteMagnitude
        )

        XCTAssertTrue(deadline.hasTimeRemaining(at: now))
        XCTAssertEqual(
            deadline.remainingSeconds(at: now),
            Double.greatestFiniteMagnitude
        )
        XCTAssertGreaterThan(deadline.remainingDuration(at: now), .zero)
        XCTAssertEqual(deadline.budgetMilliseconds, Int.max)
    }

    func testBudgetMillisecondsRoundUpAndSaturateAtIntegerBoundary() {
        for seconds in [Double(Int.max) / 1_000, 1e20, Double.greatestFiniteMagnitude] {
            let deadline = SemanticObservationDeadline(start: .now, timeoutSeconds: seconds)
            XCTAssertEqual(deadline.budgetMilliseconds, Int.max)
        }
        XCTAssertEqual(
            SemanticObservationDeadline(start: .now, timeoutSeconds: 0.0011).budgetMilliseconds,
            2
        )
    }
}
#endif
