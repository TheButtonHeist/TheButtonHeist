import Testing
import ButtonHeistTestSupport
import ThePlans
import TheScore

@Suite struct HeistReportTests {
    @Test func `skipped action report preserves declaration identity without evidence`() throws {
        let command = HeistActionCommand.activate(
            .predicate(ElementPredicate(label: "Checkout"))
        )
        let step = HeistExecutionStepResult.action(
            path: try HeistExecutionPath(validating: "$.body[0]"),
            execution: .skipped(command: command)
        )

        let report = HeistReport.project(result: try HeistResult(steps: [step], durationMs: 0))
        let node = try #require(report.outputNodes.first)

        #expect(node.command == .activate)
        #expect(node.target == command.reportTarget)
        #expect(node.evidence == nil)
    }

    @Test func `unavailable invocation evidence projects declaration identity`() throws {
        let step = HeistExecutionStepResult.invocation(
            path: try HeistExecutionPath(validating: "$.body[0]"),
            invocationPath: "Cart.checkout",
            argument: .string("Milk"),
            completion: .failed(
                evidence: nil,
                failure: HeistFailureDetail(
                    category: .runtimeUnavailable,
                    contract: "invocation evidence is observed",
                    observed: "runtime unavailable"
                )
            )
        )

        let report = HeistReport.project(result: try HeistResult(steps: [step], durationMs: 1))
        let node = try #require(report.outputNodes.first)

        #expect(node.invocationDisplayName == #"RunHeist("Cart.checkout", "Milk")"#)
        #expect(node.evidence == nil)
        #expect(node.failure?.actionKind == .accessibilityTreeUnavailable)
        #expect(report.failure?.actionKind == .accessibilityTreeUnavailable)
    }

    @Test func `report reducer derives summary from the admitted result tree`() throws {
        let child = HeistExecutionStepResult.warning(
            path: "$.body[0].heist.body[0]",
            message: "notice",
            completion: .passed()
        )
        let children = try #require(HeistPassingChildren([child]))
        let root = HeistExecutionStepResult.heist(
            path: "$.body[0]",
            name: "Checkout",
            completion: .passed(children: children)
        )
        let result = try HeistResult(steps: [root], durationMs: 5)

        let report = HeistReport.project(result: result)

        #expect(result.steps == [root])
        #expect(report.outputNodes.map(\.path) == [root.path, child.path])
        #expect(report.nodes.first?.children.first?.path == child.path)
        #expect(report.summary.executedTopLevelStepCount == 1)
        #expect(report.summary.executedNodeCount == 2)
        #expect(report.summary.outputNodeCount == 2)
        #expect(report.summary.durationMs == 5)
        #expect(report.metrics.measurements.first?.name == .heistDurationMs)
        #expect(report.metrics.measurements.first?.valueMs == 5)
        #expect(report.warnings == [HeistExecutionWarning(path: child.path, message: "notice")])
    }

}
