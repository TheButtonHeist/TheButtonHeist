import ButtonHeistTestSupport
import TheScore
@_spi(ButtonHeistInternals) @_spi(ButtonHeistTooling) @testable import ButtonHeist
import XCTest

final class PublicHeistExecutionJSONContractTests: XCTestCase {
    func testCanonicalPublicHeistExecutionFixture() throws {
        let json = try publicHeistExecutionJSON(
            step: HeistResultFixture.warning(message: "heads up")
        )

        try assertPublicHeistJSONContract(
            json,
            equals: PublicHeistActionJSONFixture.warningResponse
        )
    }

    func testFailureContract() throws {
        let json = try publicHeistExecutionJSON(
            step: HeistResultFixture.explicitFailure(message: "stop")
        )
        let node = try XCTUnwrap(try json.object("report").array("nodes").first)

        XCTAssertEqual(try json.string("status"), "partial")
        try assertPublicHeistJSONContract(
            node.object("failure"),
            equals: PublicHeistActionJSONFixture.failure
        )
        try node.assertMissing("evidence")
    }

    func testRuntimeUnavailableFailureWithoutEvidenceUsesCanonicalDiagnostic() throws {
        let step = HeistExecutionStepResult.invocation(
            path: "$.body[0]",
            invocationPath: "Cart.checkout",
            argument: .none,
            completion: .failed(
                evidence: nil,
                failure: HeistFailureDetail(
                    category: .runtimeUnavailable,
                    contract: "runtime is available",
                    observed: "runtime unavailable"
                )
            )
        )

        let failure = try publicHeistExecutionNodeJSON(step: step).object("failure")

        XCTAssertEqual(try failure.string("code"), "request.accessibility_tree_unavailable")
        XCTAssertEqual(try failure.string("kind"), "request")
        XCTAssertEqual(try failure.string("phase"), "request")
        XCTAssertEqual(try failure.bool("retryable"), true)
    }

    func testWaitDeadlineWithoutEvidenceUsesTimeoutDiagnostic() throws {
        let step = HeistExecutionStepResult.wait(
            path: "$.body[0]",
            predicate: .exists(.label("Ready")),
            timeout: 1,
            completion: .failed(
                evidence: nil,
                failure: HeistFailureDetail(
                    category: .timeout,
                    contract: "wait begins within the whole-heist deadline",
                    observed: "whole-heist deadline expired before wait observation"
                )
            )
        )

        let failure = try publicHeistExecutionNodeJSON(step: step).object("failure")

        XCTAssertEqual(try failure.string("code"), "request.timeout")
        XCTAssertEqual(try failure.string("kind"), "request")
        XCTAssertEqual(try failure.string("phase"), "request")
        XCTAssertEqual(try failure.bool("retryable"), true)
        XCTAssertTrue(try failure.string("hint").contains("retry"))
    }

    func testFailureDiagnosticsPreserveCaptureFailureKind() throws {
        let result = try HeistResult(
            steps: [HeistResultFixture.explicitFailure(message: "stop")],
            failureCapture: .unavailable(kind: .timeout, message: "capture timed out"),
            durationMs: 1
        )

        let diagnostics = try publicHeistExecutionJSON(result: result)
            .object("report")
            .object("diagnostics")

        XCTAssertEqual(
            try diagnostics.string("failureScreenshotSummary"),
            "failure screenshot: unavailable message=\"capture timed out\""
        )
        XCTAssertEqual(try diagnostics.string("failureScreenshotFailureKind"), "timeout")
        try diagnostics.assertMissing("failureInterface")
    }

    func testFailureDiagnosticsBoundCapturedInterface() throws {
        let interface = makeTestInterface(elements: (0..<3).map { index in
            makeTestHeistElement(label: "Row \(index)")
        })
        let screenshot = try XCTUnwrap(ScreenPayload.admit(
            pngData: "failure",
            width: 100,
            height: 200,
            interface: interface
        ))
        let result = try HeistResult(
            steps: [HeistResultFixture.explicitFailure(message: "stop")],
            failureCapture: .captured(screenshot),
            durationMs: 1
        )
        let profile = ProjectionProfile(
            kind: .summary,
            limits: .current(failureInterfaceElements: 1)
        )

        let diagnostics = try publicHeistExecutionJSON(result: result, profile: profile)
            .object("report")
            .object("diagnostics")
        let failureInterface = try diagnostics.object("failureInterface")
        let rendering = try failureInterface.object("rendering")

        XCTAssertEqual(try diagnostics.string("failureScreenshotSummary"), "failure screenshot: 100x200 interface=3 elements")
        try diagnostics.assertMissing("failureScreenshotFailureKind")
        XCTAssertEqual(try rendering.string("completeness"), "truncated")
        XCTAssertEqual(try rendering.int("renderedElementCount"), 1)
        XCTAssertEqual(try rendering.int("omittedElementCount"), 2)
        XCTAssertEqual(try failureInterface.array("tree").count, 1)
    }

    func testActionExpectationContract() throws {
        let node = try publicHeistExecutionNodeJSON(
            step: PublicHeistExecutionJSONContractFixture.actionWithExpectation()
        )

        try assertPublicHeistJSONContract(
            node.object("evidence"),
            equals: PublicHeistActionJSONFixture.actionWithExpectation
        )
        try assertPublicHeistJSONContract(
            node.object("expectation"),
            equals: PublicHeistActionJSONFixture.expectation
        )
    }

    func testExpectationGapContractIsTotalForEveryObservationGap() throws {
        for expectationGap in PublicHeistExecutionJSONContractFixture.expectationGaps {
            let node = try publicHeistExecutionNodeJSON(
                step: PublicHeistExecutionJSONContractFixture.failedWait(
                    expectationGap: expectationGap.gap
                )
            )

            XCTAssertEqual(
                try node.string("expectationGap"),
                expectationGap.publicCode
            )
            try node.assertPresent("failure")
            try node.assertMissing("expectation")
        }
    }

    func testWaitEvidenceContract() throws {
        let evidence = try evidence(
            for: PublicHeistExecutionJSONContractFixture.wait()
        )

        try assertPublicHeistJSONContract(
            evidence,
            equals: PublicHeistActionJSONFixture.wait
        )
    }

    func testCaseSelectionEvidenceContractAndOmittedCases() throws {
        let evidence = try evidence(
            for: PublicHeistExecutionJSONContractFixture.caseSelection(),
            profile: PublicHeistExecutionJSONContractFixture.oneVisibleCaseProfile
        )

        try assertPublicHeistJSONContract(
            evidence,
            equals: PublicHeistControlFlowJSONFixture.caseSelection
        )
    }

    func testForEachStringEvidenceContract() throws {
        let evidence = try evidence(
            for: PublicHeistExecutionJSONContractFixture.forEachString()
        )

        try assertPublicHeistJSONContract(
            evidence,
            equals: PublicHeistControlFlowJSONFixture.forEachString
        )
    }

    func testForEachElementEvidenceContract() throws {
        let evidence = try evidence(
            for: PublicHeistExecutionJSONContractFixture.forEachElement()
        )

        try assertPublicHeistJSONContract(
            evidence,
            equals: PublicHeistControlFlowJSONFixture.forEachElement
        )
    }

    func testRepeatUntilEvidenceContract() throws {
        let evidence = try evidence(
            for: PublicHeistExecutionJSONContractFixture.repeatUntil()
        )

        try assertPublicHeistJSONContract(
            evidence,
            equals: PublicHeistControlFlowJSONFixture.repeatUntil
        )
    }

    func testInvocationEvidenceContract() throws {
        let evidence = try evidence(
            for: PublicHeistExecutionJSONContractFixture.invocation()
        )

        try assertPublicHeistJSONContract(
            evidence,
            equals: PublicHeistActionJSONFixture.invocation
        )
    }

    func testActionEvidenceOmissionContract() throws {
        let node = try publicHeistExecutionNodeJSON(
            step: PublicHeistExecutionJSONContractFixture.actionWithOmissions()
        )
        let result = try node
            .object("evidence")
            .object("action")
            .object("result")

        try assertPublicHeistJSONContract(
            result.object("omitted"),
            equals: PublicHeistActionJSONFixture.omissions
        )
        try result.assertMissing("subjectEvidence")
    }

    private func evidence(
        for step: HeistExecutionStepResult,
        profile: ProjectionProfile = .summary
    ) throws -> JSONProbe {
        try publicHeistExecutionNodeJSON(step: step, profile: profile).object("evidence")
    }
}
