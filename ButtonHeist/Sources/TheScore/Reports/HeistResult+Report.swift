import Foundation
import ThePlans

/// The canonical semantic interpretation of a completed heist execution.
public struct HeistReport: Sendable, Equatable {
    public struct Summary: Sendable, Equatable {
        public let executedTopLevelStepCount: Int
        public let executedNodeCount: Int
        public let outputNodeCount: Int
        public let abortedAtPath: HeistExecutionPath?
        public let durationMs: Int
        public let expectations: Expectations?
        public let finalScreenId: String?

    }

    public struct Expectations: Sendable, Equatable {
        public let checked: Int
        public let met: Int
        public var allMet: Bool { checked == met }
    }

    public struct Failure: Sendable, Equatable {
        public let detail: HeistFailureDetail
        /// The failure headline for this node. Compound wrappers whose child
        /// supplies the actionable failure intentionally have no headline.
        public var message: String? { suppressesMessage ? nil : detail.observed }
        public let actionKind: ActionFailure.Kind?
        private let suppressesMessage: Bool

        package var diagnosticMessage: String { message ?? detail.observed }

        package init(
            detail: HeistFailureDetail,
            actionKind: ActionFailure.Kind?,
            suppressesMessage: Bool
        ) {
            self.detail = detail
            self.actionKind = actionKind
            self.suppressesMessage = suppressesMessage
        }
    }

    public struct Node: Sendable, Equatable {
        public let path: HeistExecutionPath
        public let kind: HeistExecutionStepKind
        public let capability: HeistInvocationPath?
        public let invocationDisplayName: String?
        public let command: HeistActionCommandType?
        public let target: AccessibilityTarget?
        public let status: HeistExecutionStepStatus
        private let successMessage: String?
        public var message: String? { failure?.detail.observed ?? successMessage }
        public let failure: Failure?
        public let abortedAtChildPath: HeistExecutionPath?
        public let activationTrace: ActivationTrace?
        public let children: [Node]
        package let evidence: Evidence?

        public var expectation: ExpectationResult? {
            evidence?.expectationResult
        }

        /// The recorded reason expectation truth could not be reconstructed.
        ///
        /// This is evidence uncertainty, not an interpretation failure. The
        /// execution node and its terminal failure remain available.
        public var expectationGap: Observation.Gap? {
            evidence?.expectationGap
        }

        public var warning: HeistExecutionWarning? {
            guard case .warning(let warning) = evidence else { return nil }
            return warning
        }

        package init(
            step: HeistExecutionStepResult,
            children: [Node]
        ) {
            path = step.path
            kind = step.kind
            capability = step.invocation?.path
            invocationDisplayName = step.invocation?.runHeistSummary
            command = step.actionCommand?.wireType
            target = step.reportTarget
            status = step.status
            successMessage = step.failure == nil ? step.reportMessage : nil
            failure = step.failure.map {
                Failure(
                    detail: $0,
                    actionKind: step.actionEvidence?.result?.outcome.failureKind
                        ?? $0.category.actionFailureKind,
                    suppressesMessage: step.reportSuppressesFailureMessage
                )
            }
            abortedAtChildPath = step.abortedAtChildPath
            activationTrace = step.reportActionResult?.activationTrace
            self.children = children
            evidence = Evidence(step: step)
        }
    }

    package enum Evidence: Sendable, Equatable {
        case action(
            command: HeistActionCommand,
            evidence: HeistActionEvidence,
            expectation: Result<ExpectationResult, Observation.Gap>?
        )
        case wait(
            evidence: HeistExpectationEvidence,
            expectation: Result<ExpectationResult, Observation.Gap>,
            outcome: HeistPredicateEvidenceOutcome
        )
        case caseSelection(HeistCaseSelectionEvidence)
        case forEachString(declaration: HeistForEachStringDeclaration, evidence: HeistForEachStringEvidence)
        case forEachElement(declaration: HeistForEachElementDeclaration, evidence: HeistForEachElementEvidence)
        case repeatUntil(declaration: HeistRepeatUntilDeclaration, evidence: HeistRepeatUntilEvidence)
        case invocation(invocation: HeistInvocationStep, evidence: HeistInvocationEvidence)
        case warning(HeistExecutionWarning)

        init?(step: HeistExecutionStepResult) {
            switch step.node {
            case .action(let command, _):
                guard let evidence = step.actionEvidence else { return nil }
                self = .action(
                    command: command,
                    evidence: evidence,
                    expectation: evidence.expectationEvidence?.replayResult
                )
            case .wait:
                guard let evidence = step.waitEvidence else { return nil }
                let replay = evidence.replayResult
                let outcome: HeistPredicateEvidenceOutcome = switch replay {
                case .success(let expectation):
                    switch (step.status, expectation.met) {
                    case (.passed, true): .matched
                    case (.passed, false): .handledElse
                    default: .failed
                    }
                case .failure:
                    .failed
                }
                self = .wait(
                    evidence: evidence,
                    expectation: replay,
                    outcome: outcome
                )
            case .conditional:
                guard let evidence = step.caseSelectionEvidence else { return nil }
                self = .caseSelection(evidence)
            case .forEachString(let declaration, _), .forEachStringIteration(let declaration, _):
                guard let evidence = step.forEachStringEvidence else { return nil }
                self = .forEachString(declaration: declaration, evidence: evidence)
            case .forEachElement(let declaration, _), .forEachElementIteration(let declaration, _):
                guard let evidence = step.forEachElementEvidence else { return nil }
                self = .forEachElement(declaration: declaration, evidence: evidence)
            case .repeatUntil(let declaration, _), .repeatUntilIteration(let declaration, _):
                guard let evidence = step.repeatUntilEvidence else { return nil }
                self = .repeatUntil(declaration: declaration, evidence: evidence)
            case .invocation(let path, let argument, _):
                guard let evidence = step.invocationEvidence else { return nil }
                self = .invocation(
                    invocation: HeistInvocationStep(path: path, argument: argument),
                    evidence: evidence
                )
            case .warning:
                guard let warning = step.warningEvidence else { return nil }
                self = .warning(warning)
            case .failure, .heist:
                return nil
            }
        }

        package var observation: Observation.Evidence? {
            switch self {
            case .action(_, let evidence, _):
                evidence.result?.observationEvidence
            case .wait(let evidence, _, _):
                evidence.observation
            case .caseSelection,
                 .forEachString,
                 .forEachElement,
                 .repeatUntil,
                 .invocation,
                 .warning:
                nil
            }
        }

        package var expectationEvidence: HeistExpectationEvidence? {
            switch self {
            case .action(_, let evidence, _):
                evidence.expectationEvidence
            case .wait(let evidence, _, _):
                evidence
            case .caseSelection,
                 .forEachString,
                 .forEachElement,
                 .repeatUntil,
                 .invocation,
                 .warning:
                nil
            }
        }

        package var expectationResult: ExpectationResult? {
            expectationReplay?.success
        }

        package var expectationGap: Observation.Gap? {
            expectationReplay?.failure
        }

        private var expectationReplay: Result<ExpectationResult, Observation.Gap>? {
            switch self {
            case .action(_, _, let replay): replay
            case .wait(_, let replay, _): replay
            case .caseSelection,
                 .forEachString,
                 .forEachElement,
                 .repeatUntil,
                 .invocation,
                 .warning:
                nil
            }
        }
    }

    public struct Diagnostics: Sendable, Equatable {
        package let failureCapture: HeistFailureCapture?
        package let failureInterface: Interface?

        public var failureScreenshotSummary: String? {
            guard let failureCapture else { return nil }
            if let screenshot = failureCapture.payload {
                return HeistFailureDiagnostics.screenshotSummary(screenshot)
            }
            return HeistFailureDiagnostics.unavailableScreenshotSummary(
                message: failureCapture.message
            )
        }

        public var failureScreenshotFailureKind: ActionFailure.Kind? {
            failureCapture?.failureKind
        }

        package func failureInterfaceDump(elementLimit: Int) -> String? {
            failureInterface.map {
                HeistFailureDiagnostics.interfaceDump($0, elementLimit: elementLimit)
            }
        }
    }

    public struct Metrics: Codable, Sendable, Equatable {
        public let measurements: [Measurement]
        public let ceilings: [CeilingMetric]
    }

    public enum MetricName: String, Codable, Sendable, Equatable, CaseIterable {
        case heistDurationMs
        case actionPipelineTargetResolutionMs = "actionPipeline.targetResolutionMs"
        case actionPipelineActionDispatchMs = "actionPipeline.actionDispatchMs"
        case actionPipelineTotalMs = "actionPipeline.totalMs"
    }

    public struct Measurement: Codable, Sendable, Equatable {
        public let name: MetricName
        public let valueMs: ElapsedMilliseconds
        public let path: HeistExecutionPath?
        public let kind: HeistExecutionStepKind?
        public let status: HeistExecutionStepStatus?

        public init(
            name: MetricName,
            valueMs: ElapsedMilliseconds,
            path: HeistExecutionPath? = nil,
            kind: HeistExecutionStepKind? = nil,
            status: HeistExecutionStepStatus? = nil
        ) {
            self.name = name
            self.valueMs = valueMs
            self.path = path
            self.kind = kind
            self.status = status
        }
    }

    public enum CeilingMetricSource: String, Codable, Sendable, Equatable, CaseIterable {
        case caseSelectionTimeout = "caseSelection.timeout"
    }

    public struct CeilingMetric: Codable, Sendable, Equatable {
        public let source: CeilingMetricSource
        public let budgetMs: ElapsedMilliseconds
        public let elapsedMs: ElapsedMilliseconds
        public let path: HeistExecutionPath
        public let kind: HeistExecutionStepKind
        public let status: HeistExecutionStepStatus

        public init(
            source: CeilingMetricSource,
            budgetMs: ElapsedMilliseconds,
            elapsedMs: ElapsedMilliseconds,
            path: HeistExecutionPath,
            kind: HeistExecutionStepKind,
            status: HeistExecutionStepStatus
        ) {
            self.source = source
            self.budgetMs = budgetMs
            self.elapsedMs = elapsedMs
            self.path = path
            self.kind = kind
            self.status = status
        }
    }

    public let summary: Summary
    public let metrics: Metrics
    public let nodes: [Node]
    public let diagnostics: Diagnostics

    public var failure: Failure? { failedNode?.failure }

    public var warnings: [HeistExecutionWarning] {
        outputNodes.compactMap(\.warning)
    }

    public var outputNodes: [Node] {
        var output: [Node] = []
        for node in nodes {
            node.appendInExecutionOrder(to: &output)
        }
        return output
    }

    private init(
        summary: Summary,
        metrics: Metrics,
        nodes: [Node],
        diagnostics: Diagnostics
    ) {
        self.summary = summary
        self.metrics = metrics
        self.nodes = nodes
        self.diagnostics = diagnostics
    }

    /// Interprets the result tree once and produces every semantic report fact.
    ///
    /// Incomplete observation evidence remains a node fact instead of making
    /// interpretation partial over an already-admitted execution result.
    public static func project(result: HeistResult) -> HeistReport {
        var reducer = Reducer(durationMs: result.durationMs)
        result.steps.walk(
            enter: { (step: HeistExecutionStepResult) in
                reducer.enter(step)
            },
            leave: { (step: HeistExecutionStepResult) in
                reducer.leave(step)
            }
        )
        return reducer.report(result: result)
    }
}

private extension HeistReport {
    struct Frame {
        let step: HeistExecutionStepResult
        var children: [Node] = []
    }

    struct Reducer {
        let durationMs: ElapsedMilliseconds
        var frames: [Frame] = []
        var roots: [Node] = []
        var outputNodeCount = 0
        var executedNodeCount = 0
        var expectationsChecked = 0
        var expectationsMet = 0
        var finalScreenId: String?
        var firstFailedPath: HeistExecutionPath?
        var metricAccumulator: MetricAccumulator

        init(durationMs: ElapsedMilliseconds) {
            self.durationMs = durationMs
            var metricAccumulator = MetricAccumulator()
            metricAccumulator.append(.heistDurationMs, valueMs: durationMs)
            self.metricAccumulator = metricAccumulator
        }

        mutating func enter(_ step: HeistExecutionStepResult) {
            frames.append(Frame(step: step))
            outputNodeCount += 1
            executedNodeCount += step.status == .skipped ? 0 : 1
            metricAccumulator.appendMetrics(for: step)
            let observation: Observation.Evidence? = switch step.node {
            case .action: step.actionEvidence?.result?.observationEvidence
            case .wait: step.waitEvidence?.observation
            default: nil
            }
            if let screenId = observation?.current?
                .context
                .screenId {
                finalScreenId = screenId
            }
        }

        mutating func leave(_ step: HeistExecutionStepResult) {
            guard let frame = frames.popLast() else { return }
            let node = Node(step: step, children: frame.children)
            if node.expectation != nil || node.expectationGap != nil {
                expectationsChecked += 1
                expectationsMet += node.expectation?.met == true ? 1 : 0
            }
            if firstFailedPath == nil, node.failure != nil, node.status == .failed {
                firstFailedPath = step.path
            }
            if frames.isEmpty {
                roots.append(node)
            } else {
                frames[frames.index(before: frames.endIndex)].children.append(node)
            }
        }

        func report(result: HeistResult) -> HeistReport {
            let expectations = expectationsChecked > 0
                ? Expectations(checked: expectationsChecked, met: expectationsMet)
                : nil

            return HeistReport(
                summary: Summary(
                    executedTopLevelStepCount: result.steps.count { $0.status != .skipped },
                    executedNodeCount: executedNodeCount,
                    outputNodeCount: outputNodeCount,
                    abortedAtPath: firstFailedPath,
                    durationMs: durationMs.milliseconds,
                    expectations: expectations,
                    finalScreenId: finalScreenId
                ),
                metrics: Metrics(
                    measurements: metricAccumulator.measurements,
                    ceilings: metricAccumulator.ceilings
                ),
                nodes: roots,
                diagnostics: Diagnostics(
                    failureCapture: result.failureCapture,
                    failureInterface: result.failureDiagnosticInterface
                )
            )
        }
    }
}

private extension HeistReport.Node {
    func appendInExecutionOrder(to nodes: inout [HeistReport.Node]) {
        nodes.append(self)
        for child in children {
            child.appendInExecutionOrder(to: &nodes)
        }
    }
}

private extension Result {
    var success: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }

    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

private struct MetricAccumulator {
    var measurements: [HeistReport.Measurement] = []
    var ceilings: [HeistReport.CeilingMetric] = []

    mutating func appendMetrics(for step: HeistExecutionStepResult) {
        switch step.node {
        case .action:
            guard let evidence = step.actionEvidence else { return }
            appendActionTiming(evidence.result, step: step)
        case .wait:
            break
        case .conditional:
            guard let evidence = step.caseSelectionEvidence else { return }
            appendCeiling(
                .caseSelectionTimeout,
                budgetMs: Self.milliseconds(seconds: evidence.selection.timeout),
                elapsedMs: evidence.selection.elapsedMs,
                step: step
            )
        case .forEachElement,
             .forEachString,
             .forEachElementIteration,
             .forEachStringIteration,
             .repeatUntil,
             .repeatUntilIteration,
             .warning,
             .failure,
             .heist,
             .invocation:
            break
        }
    }

    mutating func append(
        _ name: HeistReport.MetricName,
        valueMs: ElapsedMilliseconds?,
        step: HeistExecutionStepResult? = nil
    ) {
        guard let valueMs else { return }
        measurements.append(HeistReport.Measurement(
            name: name,
            valueMs: valueMs,
            path: step?.path,
            kind: step?.kind,
            status: step?.status
        ))
    }

    private mutating func appendActionTiming(_ result: ActionResult?, step: HeistExecutionStepResult) {
        guard let result else { return }
        append(.actionPipelineTargetResolutionMs, valueMs: result.timing?.targetResolutionMs, step: step)
        append(.actionPipelineActionDispatchMs, valueMs: result.timing?.actionDispatchMs, step: step)
        append(.actionPipelineTotalMs, valueMs: result.timing?.totalMs, step: step)
    }

    private mutating func appendCeiling(
        _ source: HeistReport.CeilingMetricSource,
        budgetMs: ElapsedMilliseconds?,
        elapsedMs: ElapsedMilliseconds?,
        step: HeistExecutionStepResult
    ) {
        guard let budgetMs, let elapsedMs else { return }
        ceilings.append(HeistReport.CeilingMetric(
            source: source,
            budgetMs: budgetMs,
            elapsedMs: elapsedMs,
            path: step.path,
            kind: step.kind,
            status: step.status
        ))
    }

    private static func milliseconds(seconds: Double?) -> ElapsedMilliseconds? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let roundedMilliseconds = (seconds * 1_000).rounded()
        guard roundedMilliseconds.isFinite, roundedMilliseconds <= Double(Int.max) else { return nil }
        return requireValidLiteralPayload {
            try ElapsedMilliseconds(validatingMilliseconds: Int(roundedMilliseconds))
        }
    }
}

public extension HeistExecutionStepResult {
    var isFailure: Bool { firstFailedStepInResultOrder != nil }
    var firstFailedStep: HeistExecutionStepResult? { firstFailedStepInResultOrder }
}

public extension Array where Element == HeistExecutionStepResult {
    var firstFailedStep: HeistExecutionStepResult? { firstFailedStepInResultOrder }
}

public extension HeistResult {
    var isFailure: Bool {
        switch outcome {
        case .failed: true
        case .passed: false
        }
    }

    var firstFailedStep: HeistExecutionStepResult? { steps.firstFailedStepInResultOrder }
    var failedStepPath: HeistExecutionPath? { firstFailedStep?.path }
    var failedStepKind: HeistExecutionStepKind? { firstFailedStep?.kind }

    var outputNodes: [HeistExecutionStepResult] {
        steps.compactMapInResultOrder { Optional($0) }
    }

}

package extension HeistReport {
    var failedNode: Node? {
        if let abortedAtPath = summary.abortedAtPath,
           let node = outputNodes.first(where: { $0.path == abortedAtPath }) {
            return node
        }
        return outputNodes.first(where: { $0.status == .failed })
    }
}

private extension Sequence where Element == HeistExecutionStepResult {
    func compactMapInResultOrder<Value>(_ transform: (Element) -> Value?) -> [Value] {
        var values: [Value] = []
        walk(enter: {
            if let value = transform($0) { values.append(value) }
        }, leave: { _ in })
        return values
    }
}
