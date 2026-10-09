#if canImport(UIKit)
#if DEBUG
import Foundation
import ThePlans

// Package contract: app-hosted tests import TheInsideJob and assert against
// execution result types from TheScore. This intentional re-export is
// allowlisted by scripts/check-buttonheist-import-contract.sh.
@_exported import TheScore

/// Completed in-process heist result for app and UI tests.
///
/// Constructing a `Heist` builds or accepts a runtime-validated `HeistPlan`,
/// runs it directly against `TheInsideJob` in the app process, and then exposes
/// the result for assertions and reporting.
public struct Heist: Sendable {
    public let result: HeistResult

    @MainActor
    public init(
        _ plan: HeistPlan,
        argument: HeistArgument = .none,
        timeout: HeistTimeout = .default
    ) async throws {
        self.result = try await Self.execute(
            plan,
            argument: argument,
            timeout: timeout
        )
    }

    @MainActor
    public init(
        timeout: HeistTimeout = .default,
        @HeistBuilder _ content: () throws -> HeistContent
    ) async throws {
        let plan = try HeistPlan(content)
        self.result = try await Self.execute(
            plan,
            argument: .none,
            timeout: timeout
        )
    }

    @MainActor
    public init(
        _ input: String,
        parameter: HeistReferenceName = "input",
        timeout: HeistTimeout = .default,
        @HeistBuilder _ content: (HeistReferenceName) throws -> HeistContent
    ) async throws {
        let plan = try HeistPlan(parameter: parameter, content)
        self.result = try await Self.execute(
            plan,
            argument: .string(input),
            timeout: timeout
        )
    }

    @MainActor
    public init(
        _ input: AccessibilityTarget,
        parameter: HeistReferenceName = "input",
        timeout: HeistTimeout = .default,
        @HeistBuilder _ content: (AccessibilityTarget) throws -> HeistContent
    ) async throws {
        let plan = try HeistPlan(targetParameter: parameter, content)
        self.result = try await Self.execute(
            plan,
            argument: .accessibilityTarget(input),
            timeout: timeout
        )
    }

    @MainActor
    private static func execute(
        _ plan: HeistPlan,
        argument: HeistArgument,
        timeout: HeistTimeout
    ) async throws -> HeistResult {
        let result = try await TheInsideJob.shared.executeInAppHeist(
            plan,
            argument: argument,
            timeout: timeout
        )
        HeistResultRecording.recordIfEnabled(result, plan: plan)
        guard !result.isFailure else {
            throw Failure(result)
        }
        return result
    }
}

public extension Heist {
    struct Failure: Error, Sendable, LocalizedError, CustomStringConvertible {
        public let failedStepPath: HeistExecutionPath
        public let failedStepKind: HeistExecutionStepKind
        public let message: String
        public let diagnostic: String?
        public let result: HeistResult
        private let report: HeistReport

        public init(_ result: HeistResult) {
            let report = HeistReport.project(result: result)
            let failedNode = report.failedNode
            self.failedStepPath = failedNode?.path ?? "$"
            self.failedStepKind = failedNode?.kind ?? .fail
            self.message = failedNode?.failure?.detail.observed
                ?? failedNode?.message
                ?? "heist failed"
            self.diagnostic = failedNode?.failure.map { Self.diagnostic($0.detail) }
            self.result = result
            self.report = report
        }

        public var errorDescription: String? { description }

        public var description: String {
            var lines = [Self.failureHeadline(report.failedNode)]
            let location = failureLocation
            if !location.isEmpty {
                lines.append("Where:")
                lines.append(contentsOf: location.map { "  \($0)" })
            }
            lines.append("Cause: \(message)")
            if let failure = report.failedNode?.failure?.detail {
                if !failure.contract.isEmpty, failure.contract != message {
                    lines.append("Contract: \(failure.contract)")
                }
                if let expected = failure.expected, !expected.isEmpty {
                    lines.append("\(expectedLabel(for: failure)): \(expected)")
                }
            }
            lines.append(contentsOf: recentStepLines)
            lines.append(contentsOf: failedWaitEvidenceLines)
            if let screenshot = report.diagnostics.failureScreenshotSummary {
                lines.append(screenshot)
            }
            if let interfaceDump = report.diagnostics.failureInterfaceDump(elementLimit: .max) {
                lines.append(interfaceDump)
            }
            return lines.joined(separator: "\n")
        }

        private var failureLocation: [String] {
            guard let failedNode = report.failedNode else { return [] }
            var lineage: [HeistReport.Node] = []
            guard report.nodes.contains(where: {
                $0.appendLineage(to: failedNode.path, into: &lineage)
            }) else { return [] }
            return zip(lineage, lineage.dropFirst()).compactMap(Self.locationDescription)
        }

        private var recentStepLines: [String] {
            guard let failedIndex = report.outputNodes.firstIndex(where: { $0.path == failedStepPath }) else {
                return []
            }
            let recent = report.outputNodes[...failedIndex]
                .filter { $0.status != .skipped && ($0.kind == .action || $0.kind == .wait) }
                .suffix(5)
            guard !recent.isEmpty else { return [] }

            var lines = ["Recent steps:"]
            for node in recent {
                let status = node.status == .failed ? "✗" : "✓"
                var line = "  \(status) \(Self.stepDescription(node))"
                if let timing = Self.expectationEvidence(node)?.timing {
                    line += "  \(Self.duration(timing.elapsedMs))"
                }
                lines.append(line)
                if node.kind != .wait || node.status != .failed,
                   let observation = Self.expectationEvidence(node)?.observation {
                    lines.append("    \(Self.screenChangeDescription(observation))")
                }
            }
            return lines
        }

        private var failedWaitEvidenceLines: [String] {
            guard let failedNode = report.failedNode,
                  failedNode.kind == .wait,
                  let evidence = Self.expectationEvidence(failedNode)
            else { return [] }

            let screenChanges = evidence.observation.events.compactMap { event -> ScreenFacts? in
                guard case .screenChanged(let facts) = event else { return nil }
                return facts
            }
            let elementChanges = evidence.observation.events.count { event in
                guard case .elementsChanged = event else { return false }
                return true
            }
            let notifications = evidence.observation.events.count { event in
                guard case .notification = event else { return false }
                return true
            }
            var lines = ["Wait evidence:"]
            switch evidence.observation.coverage {
            case .complete:
                lines.append("  \(Self.screenChangeCountDescription(screenChanges, recorded: false))")
                lines.append("  Semantic element changes: \(elementChanges)")
                lines.append("  Notifications: \(notifications)")
                let lastChange = evidence.timing.lastTreeChangeElapsedMs?.milliseconds ?? 0
                let quietMs = max(0, evidence.timing.elapsedMs.milliseconds - lastChange)
                lines.append("  Final interface quiet: \(Self.duration(quietMs))")
                lines.append("  Observation coverage: complete")
            case .incomplete:
                if screenChanges.isEmpty {
                    lines.append("  Screen changes: unknown")
                } else {
                    lines.append("  \(Self.screenChangeCountDescription(screenChanges, recorded: true))")
                }
                lines.append("  Semantic element changes recorded: \(elementChanges)")
                lines.append("  Notifications recorded: \(notifications)")
                lines.append("  Observation coverage: incomplete")
            }
            return lines
        }

        private static func failureHeadline(_ node: HeistReport.Node?) -> String {
            guard let node else { return "Heist failed" }
            var headline = "\(stepDescription(node)) failed"
            if node.kind == .wait, let timing = expectationEvidence(node)?.timing {
                headline += " after \(duration(timing.elapsedMs))"
            }
            return headline
        }

        private static func stepDescription(_ node: HeistReport.Node) -> String {
            switch node.kind {
            case .action:
                let command = node.command.map { sentenceCase($0.rawValue) } ?? "Action"
                return node.target.map { "\(command) \($0)" } ?? command
            case .wait:
                let predicate = expectationEvidence(node)?.predicate?.description ?? "condition"
                return "Wait for \(predicate)"
            case .conditional: return "Conditional"
            case .forEachElement: return "For each element"
            case .forEachString: return "For each string"
            case .forEachIteration: return "Iteration"
            case .repeatUntil: return "Repeat until"
            case .repeatUntilIteration: return "Repeat attempt"
            case .warn: return "Warning"
            case .fail: return "Heist"
            case .heist: return "Nested heist"
            case .invoke: return node.invocationDisplayName ?? "Invoked heist"
            }
        }

        private static func expectationEvidence(_ node: HeistReport.Node) -> HeistExpectationEvidence? {
            node.evidence?.expectationEvidence
        }

        private static func screenChangeDescription(_ observation: Observation.Evidence) -> String {
            let changes = observation.events.compactMap { event -> ScreenFacts? in
                guard case .screenChanged(let facts) = event else { return nil }
                return facts
            }
            if let last = changes.last {
                return last.idAfter.map { "Screen changed to “\($0)”" } ?? "Screen changed"
            }
            switch observation.coverage {
            case .complete:
                return "No semantic screen change observed"
            case .incomplete:
                return "Screen change unknown — observation coverage was incomplete"
            }
        }

        private static func screenChangeCountDescription(
            _ changes: [ScreenFacts],
            recorded: Bool
        ) -> String {
            let label = recorded ? "Screen changes recorded" : "Screen changes"
            let screenIds = changes.compactMap(\.idAfter)
            guard !screenIds.isEmpty else { return "\(label): \(changes.count)" }
            return "\(label): \(changes.count) (\(screenIds.map { "“\($0)”" }.joined(separator: ", ")))"
        }

        private static func locationDescription(
            _ pair: (HeistReport.Node, HeistReport.Node)
        ) -> String? {
            let (parent, child) = pair
            guard let edge = child.path.childEdge(after: parent.path) else { return nil }
            switch edge.branch {
            case .conditionalCase(let index):
                guard case .caseSelection(let evidence) = parent.evidence,
                      evidence.selection.cases.indices.contains(index)
                else { return "Matched condition \(index + 1)" }
                return "When \(evidence.selection.cases[index].predicate)"
            case .conditionalElse:
                guard case .caseSelection(let evidence) = parent.evidence,
                      evidence.selection.cases.count == 1,
                      let predicate = evidence.selection.cases.first?.predicate
                else { return "Otherwise, when no condition matched" }
                return "Otherwise, when \(predicate) was not met"
            case .waitElseBody:
                guard let predicate = expectationEvidence(parent)?.predicate else {
                    return "Otherwise, after the wait was not met"
                }
                return "Otherwise, after waiting for \(predicate)"
            case .forEachElementIterations:
                guard case .forEachElement(_, let evidence) = child.evidence else {
                    return "For each element, item \(edge.ordinal + 1)"
                }
                let summary = evidence.targetSummary.map { " “\($0)”" } ?? ""
                return "For each element, item \((evidence.iterationOrdinal ?? edge.ordinal) + 1)\(summary)"
            case .forEachStringIterations:
                guard case .forEachString(_, let evidence) = child.evidence else {
                    return "For each string, item \(edge.ordinal + 1)"
                }
                let value = evidence.value.map { " “\($0)”" } ?? ""
                return "For each string, item \((evidence.iterationOrdinal ?? edge.ordinal) + 1)\(value)"
            case .repeatUntilIterations:
                return "Repeat attempt \(edge.ordinal + 1)"
            case .invocationBody:
                return parent.invocationDisplayName
            case .heistBody:
                return "Nested heist"
            case .body:
                return nil
            }
        }

        private static func sentenceCase(_ value: String) -> String {
            value.prefix(1).uppercased() + value.dropFirst()
        }

        private static func duration(_ value: ElapsedMilliseconds) -> String {
            duration(value.milliseconds)
        }

        private static func duration(_ milliseconds: Int) -> String {
            guard milliseconds >= 1_000 else { return "\(milliseconds)ms" }
            return String(format: "%.1fs", Double(milliseconds) / 1_000)
        }

        private func expectedLabel(for failure: HeistFailureDetail) -> String {
            guard failedStepKind == .action else { return "Expected" }
            switch failure.category {
            case .action, .targetResolution:
                return "Target"
            case .explicitFailure,
                 .internalInvariant,
                 .invocation,
                 .loop,
                 .runtimeUnavailable,
                 .timeout,
                 .validation,
                 .expectation,
                 .wait:
                return "Expected"
            }
        }

        private static func diagnostic(_ failure: HeistFailureDetail) -> String {
            [
                "category=\(failure.category.rawValue)",
                "contract=\(failure.contract)",
                "observed=\(failure.observed)",
                failure.expected.map { "expected=\($0)" },
            ].compactMap { $0 }.joined(separator: " ")
        }
    }

}

private extension HeistReport.Node {
    func appendLineage(
        to path: HeistExecutionPath,
        into lineage: inout [HeistReport.Node]
    ) -> Bool {
        lineage.append(self)
        if self.path == path { return true }
        for child in children where child.appendLineage(to: path, into: &lineage) {
            return true
        }
        lineage.removeLast()
        return false
    }
}

@MainActor
extension TheInsideJob {
    func executeInAppHeist(
        _ plan: HeistPlan,
        argument: HeistArgument = .none,
        timeout: HeistTimeout = .default
    ) async throws -> HeistResult {
        switch await brains.executeInAppRequest({ [self] in
            await executeAdmittedInAppHeist(
                plan,
                argument: argument,
                timeout: timeout
            )
        }) {
        case .completed(let result):
            return try result.get()
        case .cancelled:
            throw HeistExecution.Failure.submissionCancelled
        case .rejected(.busy):
            throw HeistExecution.Failure.interactionQueueFull
        case .rejected(.cleanupTimedOut):
            throw HeistExecution.Failure.cleanupTimedOut
        case .rejected(.stopping):
            throw HeistExecution.Failure.runtimeStopping
        }
    }

    private func executeAdmittedInAppHeist(
        _ plan: HeistPlan,
        argument: HeistArgument,
        timeout: HeistTimeout
    ) async -> Result<HeistResult, HeistExecution.Failure> {
        let shouldRestoreRuntime = !brains.semanticObservationIsActive
        if shouldRestoreRuntime {
            tripwire.startPulse()
            brains.vault.semanticObservationStream.start()
            brains.safecracker.startKeyboardObservation()
        }
        defer {
            if shouldRestoreRuntime {
                brains.vault.semanticObservationStream.stop()
                tripwire.stopPulse()
                brains.safecracker.stopKeyboardObservation()
            }
        }
        // Each top-level heist starts from a fresh live visible state. This
        // keeps conditionals, waits, and first actions from inheriting the
        // previous run's settled semantic world when the app is already on
        // another screen.
        await brains.vault.resetInterfaceForLifecycle()
        guard case .committed = await brains.vault.semanticObservationStream
            .refreshedVisibleObservation(boundary: .cancellation) else {
            return .failure(.accessibilityTreeUnavailable)
        }
        let result = await brains.executeHeistPlan(
            plan,
            argument: argument,
            timeout: timeout
        )
        return result
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
