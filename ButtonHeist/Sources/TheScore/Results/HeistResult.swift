import Foundation
import ThePlans

/// Complete typed result of one heist-plan execution.
public struct HeistResult: Codable, Sendable, Equatable {
    public let steps: [HeistExecutionStepResult]
    package let failureCapture: HeistFailureCapture?
    /// End-to-end wall-clock duration for the complete heist run.
    public let durationMs: ElapsedMilliseconds

    public var outcome: HeistExecutionOutcome {
        if let failed = steps.firstFailedStepInResultOrder {
            return .failed(abortedAtPath: failed.path)
        }
        return .passed
    }

    package init(steps: [HeistExecutionStepResult], durationMs: ElapsedMilliseconds) throws {
        try self.init(steps: steps, failureCapture: nil, durationMs: durationMs)
    }

    package init(
        steps: [HeistExecutionStepResult],
        failureCapture: HeistFailureCapture?,
        durationMs: ElapsedMilliseconds
    ) throws {
        _ = try Self.admitStructure(steps, limits: .default)
        try Self.admitFailureCapture(failureCapture, steps: steps)
        self.steps = steps
        self.failureCapture = failureCapture
        self.durationMs = durationMs
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case steps
        case failureCapture
        case durationMs
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: CodingKeys.self, typeName: "heist result")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let steps = try container.decode([HeistExecutionStepResult].self, forKey: .steps)
        let failureCapture = try container.decodeIfPresent(HeistFailureCapture.self, forKey: .failureCapture)
        let durationMs = try container.decode(ElapsedMilliseconds.self, forKey: .durationMs)
        let limits = decoder.userInfo[.heistResultCodecLimits] as? HeistResultCodecLimits ?? .default
        do {
            _ = try Self.admitStructure(steps, limits: limits)
            try Self.admitFailureCapture(failureCapture, steps: steps)
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: String(describing: error)
            ))
        }
        self.steps = steps
        self.failureCapture = failureCapture
        self.durationMs = durationMs
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(steps, forKey: .steps)
        try container.encodeIfPresent(failureCapture, forKey: .failureCapture)
        try container.encode(durationMs, forKey: .durationMs)
    }

    private static func admitFailureCapture(
        _ failureCapture: HeistFailureCapture?,
        steps: [HeistExecutionStepResult]
    ) throws {
        guard failureCapture == nil || steps.firstFailedStepInResultOrder != nil else {
            throw HeistResultCodecError.incoherentExecutionEvidence(
                path: .body,
                reason: "failure capture requires a failed execution step"
            )
        }
    }

    private static func admitStructure(
        _ roots: [HeistExecutionStepResult],
        limits: HeistResultCodecLimits
    ) throws -> Int {
        var pending = roots.reversed().map {
            (
                step: $0,
                depth: 1,
                parent: Optional<HeistExecutionStepResult>.none,
                childOrdinal: Optional<Int>.none
            )
        }
        var paths: Set<HeistExecutionPath> = []
        var nodeCount = 0
        while let current = pending.popLast() {
            nodeCount += 1
            guard nodeCount <= limits.maxNodeCount else {
                throw HeistResultCodecError.nodeCountExceeded(limit: limits.maxNodeCount, observed: nodeCount)
            }
            guard current.depth <= limits.maxNestingDepth else {
                throw HeistResultCodecError.nestingDepthExceeded(
                    limit: limits.maxNestingDepth,
                    observed: current.depth
                )
            }
            guard paths.insert(current.step.path).inserted else {
                throw HeistResultCodecError.duplicateExecutionPath(current.step.path)
            }
            if let parent = current.parent {
                guard current.step.path.isDescendant(of: parent.path) else {
                    throw HeistResultCodecError.nonDescendantChildPath(
                        parent: parent.path,
                        child: current.step.path
                    )
                }
                guard let childOrdinal = current.childOrdinal else {
                    throw HeistResultCodecError.illegalChildExecutionPath(
                        parent: parent.path,
                        child: current.step.path,
                        parentKind: parent.kind
                    )
                }
                guard current.step.path.isLegalChild(
                    of: parent,
                    child: current.step,
                    childOrdinal: childOrdinal
                ) else {
                    throw HeistResultCodecError.illegalChildExecutionPath(
                        parent: parent.path,
                        child: current.step.path,
                        parentKind: parent.kind
                    )
                }
            } else if current.step.path.isRootStepPath() {
                // Top-level result fragments may carry their original body index.
            } else {
                throw HeistResultCodecError.illegalRootExecutionPath(current.step.path)
            }
            var branchCounts: [HeistExecutionPath.ChildBranch: Int] = [:]
            let children = current.step.children.map { child in
                let edge = child.path.childEdge(after: current.step.path)
                let childOrdinal = edge.map { edge in
                    defer { branchCounts[edge.branch, default: 0] += 1 }
                    return branchCounts[edge.branch, default: 0]
                }
                return (
                    step: child,
                    depth: current.depth + 1,
                    parent: Optional(current.step),
                    childOrdinal: childOrdinal,
                    edge: edge
                )
            }
            try admitAggregateEvidence(
                current.step,
                childEdges: children.compactMap { child in
                    child.edge.map { (child.step, $0) }
                }
            )
            try admitOrderedExecution(current.step.children)
            pending.append(contentsOf: children.reversed().map {
                (
                    step: $0.step,
                    depth: $0.depth,
                    parent: $0.parent,
                    childOrdinal: $0.childOrdinal
                )
            })
        }
        try admitRootIndices(roots)
        try admitOrderedExecution(roots)
        return nodeCount
    }

    private static func admitRootIndices(_ roots: [HeistExecutionStepResult]) throws {
        let rootIndices = roots.compactMap(\.path.rootStepIndex)
        guard rootIndices == Array(0..<rootIndices.count) else {
            throw HeistResultCodecError.incoherentExecutionEvidence(
                path: .body,
                reason: "top-level body root indices must be contiguous and in result order"
            )
        }
    }

    private static func admitOrderedExecution(_ steps: [HeistExecutionStepResult]) throws {
        var admission = OrderedExecutionAdmission()
        for step in steps {
            try admission.admit(step)
        }
    }

    private static func admitAggregateEvidence(
        _ step: HeistExecutionStepResult,
        childEdges: [(step: HeistExecutionStepResult, edge: HeistExecutionPath.ChildEdge)]
    ) throws {
        try admitExpectationEvidence(step)
        switch step.kind {
        case .conditional:
            try admitConditionalEvidence(step, childEdges: childEdges)
        case .forEachElement:
            try admitLoopIterationCount(
                step,
                observed: childEdges.count { $0.edge.branch == .forEachElementIterations },
                expected: step.forEachElementEvidence?.iterationCount,
                loopName: "for_each_element"
            )
        case .forEachString:
            try admitLoopIterationCount(
                step,
                observed: childEdges.count { $0.edge.branch == .forEachStringIterations },
                expected: step.forEachStringEvidence?.iterationCount,
                loopName: "for_each_string"
            )
        case .repeatUntil:
            try admitRepeatUntilEvidence(step, childEdges: childEdges)
        case .action,
             .wait,
             .forEachIteration,
             .repeatUntilIteration,
             .warn,
             .fail,
             .heist:
            break
        case .invoke:
            try admitInvocationEvidence(step)
        }
    }

    private static func admitExpectationEvidence(_ step: HeistExecutionStepResult) throws {
        guard step.kind == .wait, step.status == .failed else { return }

        if step.abortedAtChildPath != nil {
            guard let evidence = step.waitEvidence,
                  let fallback = HeistPassedWaitEvidence(evidence),
                  fallback.usesFallback else {
                throw incoherent(
                    step,
                    "child-aborted wait requires complete unmet fallback evidence"
                )
            }
            return
        }

        let replay: ExpectationResult?
        do {
            replay = try step.replayExpectation()
        } catch {
            return
        }
        guard let replay else { return }

        if replay.met {
            throw incoherent(step, "failed wait expectation must not replay as met")
        }
    }

    private static func admitConditionalEvidence(
        _ step: HeistExecutionStepResult,
        childEdges: [(step: HeistExecutionStepResult, edge: HeistExecutionPath.ChildEdge)]
    ) throws {
        guard let outcome = step.caseSelectionEvidence?.selection.outcome else { return }
        let executionEdges = childEdges.filter(\.edge.isConditionalExecutionBranch)
        let accepts: (HeistExecutionPath.ChildEdge) -> Bool
        switch outcome {
        case .matchedCase(let index):
            guard let matchedIndex = Int(exactly: index) else {
                throw incoherent(step, "matched_case index \(index) is not representable")
            }
            accepts = { $0.branch == .conditionalCase(matchedIndex) }
        case .elseBranch:
            accepts = { $0.branch == .conditionalElse }
        case .timedOut, .noMatch:
            accepts = { _ in false }
        }
        guard executionEdges.allSatisfy({ accepts($0.edge) }) else {
            throw incoherent(step, "conditional children do not match selected branch \(outcome)")
        }
    }

    private static func admitLoopIterationCount(
        _ step: HeistExecutionStepResult,
        observed: Int,
        expected: Int?,
        loopName: String
    ) throws {
        guard let expected else { return }
        guard observed == expected else {
            throw incoherent(
                step,
                "\(loopName) evidence iterationCount \(expected) does not match \(observed) iteration child node(s)"
            )
        }
    }

    private static func admitRepeatUntilEvidence(
        _ step: HeistExecutionStepResult,
        childEdges: [(step: HeistExecutionStepResult, edge: HeistExecutionPath.ChildEdge)]
    ) throws {
        guard let evidence = step.repeatUntilEvidence else { return }
        let iterationCount = childEdges.count { $0.edge.branch == .repeatUntilIterations }
        guard iterationCount == evidence.iterationCount else {
            throw incoherent(
                step,
                "repeat_until evidence iterationCount \(evidence.iterationCount) "
                    + "does not match \(iterationCount) iteration child node(s)"
            )
        }
    }

    private static func admitInvocationEvidence(_ step: HeistExecutionStepResult) throws {
        switch step.status {
        case .passed:
            // Passed invocation completion already admits only `.completed` evidence.
            return
        case .skipped:
            return
        case .failed:
            guard let abortedAtChildPath = step.abortedAtChildPath else {
                guard step.invocationEvidence?.childFailedPath == nil else {
                    throw incoherent(
                        step,
                        "intrinsic failed invocation must not carry child-failure evidence"
                    )
                }
                return
            }
            guard let observedPath = step.invocationEvidence?.childFailedPath else {
                throw incoherent(
                    step,
                    "child-aborted invocation must observe child-failure evidence at \(abortedAtChildPath)"
                )
            }
            guard observedPath == abortedAtChildPath else {
                throw incoherent(
                    step,
                    "child-aborted invocation evidence path \(observedPath) "
                        + "does not match aborted child path \(abortedAtChildPath)"
                )
            }
        }
    }

    private static func incoherent(
        _ step: HeistExecutionStepResult,
        _ reason: String
    ) -> HeistResultCodecError {
        .incoherentExecutionEvidence(path: step.path, reason: reason)
    }

    private struct OrderedExecutionAdmission {
        private(set) var terminalFailurePath: HeistExecutionPath?

        mutating func admit(_ step: HeistExecutionStepResult) throws {
            if let terminalFailurePath {
                guard step.status == .skipped else {
                    throw HeistResult.incoherent(
                        step,
                        "ordered sequence cannot execute after abort at \(terminalFailurePath)"
                    )
                }
                return
            }

            guard step.status == .failed else { return }
            terminalFailurePath = step.abortedAtChildPath ?? step.path
        }
    }

}

public enum HeistExecutionOutcome: Sendable, Equatable {
    case passed
    case failed(abortedAtPath: HeistExecutionPath)
}
