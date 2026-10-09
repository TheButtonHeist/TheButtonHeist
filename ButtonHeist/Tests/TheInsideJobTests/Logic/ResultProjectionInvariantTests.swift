#if canImport(UIKit)
#if DEBUG
import ButtonHeistTestSupport
import Testing

@_spi(ButtonHeistInternals) @testable import ThePlans
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

// Projection ledger:
// - result outcome, failed path, and evidence gap survive canonical report and human rendering —
//   `failed outcome path and incomplete evidence survive report and human projection`.
// - compact and public JSON retain the same report semantics —
//   `TheFenceCompactFormattingContractHeistTests.testTimeoutMismatchUsesCanonicalFailureDiagnostics`.
// - result structural admission rejects unreplayable successful evidence —
//   `HeistResultSemanticAdmissionTests.passed action evidence requires expectation replay proof`.

@Suite struct ResultProjectionInvariantTests {
    @Test func `whole heist deadline before wait observation remains a timeout`() throws {
        let path: HeistExecutionPath = "$.body[0]"
        let step = HeistExecution.ResultProjector.heistTimeout(
            wait: WaitStep(predicate: .exists(.label("Ready")), timeout: 1),
            path: path
        )
        let report = HeistReport.project(
            result: try HeistResult(steps: [step], durationMs: 0)
        )

        #expect(step.failure?.category == .timeout)
        #expect(report.failedNode?.failure?.actionKind == .timeout)
    }

    @Test func `failed outcome path and incomplete evidence survive report and human projection`() throws {
        let predicate = AccessibilityPredicate.exists(.label("Saved"))
        let evidence = HeistResultFixture.expectationEvidence(
            predicate: predicate,
            observation: Observation.Evidence(
                baseline: nil,
                events: [.noChange],
                current: nil,
                coverage: .incomplete(.captureUnavailable)
            ),
            terminalCause: .deadline
        )
        let path: HeistExecutionPath = "$.body[0]"
        let step = HeistResultFixture.failedWait(
            path: path.description,
            evidence: evidence,
            failure: HeistFailureDetail(
                category: .timeout,
                contract: "wait predicate is met before timeout",
                observed: "capture unavailable",
                expected: predicate.description
            )
        )
        let result = try HeistResult(steps: [step], durationMs: 1)
        let report = HeistReport.project(result: result)
        let human = Heist.Failure(result)

        #expect(result.outcome == .failed(abortedAtPath: path))
        #expect(report.summary.abortedAtPath == path)
        #expect(report.failedNode?.path == path)
        #expect(report.failedNode?.status == .failed)
        #expect(report.failedNode?.expectationGap == .captureUnavailable)
        #expect(human.failedStepPath == path)
        #expect(human.description.contains("Observation coverage: incomplete"))
        #expect(human.description.contains("Cause: capture unavailable"))
    }
}
#endif
#endif
