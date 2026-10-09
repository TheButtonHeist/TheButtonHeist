import Foundation
import ThePlans

import AccessibilitySnapshotModel
import TheScore

private enum PublicHeistExecutionResponseKey: String, CodingKey {
    case status, report
}

private enum PublicHeistReportCodingKey: String, CodingKey {
    case summary, metrics, nodes, diagnostics
}

private enum PublicHeistReportSummaryCodingKey: String, CodingKey {
    case executedTopLevelStepCount, executedNodeCount, outputNodeCount, abortedAtPath, durationMs, expectations
}

private enum PublicHeistExpectationSummaryCodingKey: String, CodingKey {
    case checked, met, allMet
}

private enum PublicHeistReportNodeCodingKey: String, CodingKey {
    case path, kind, capability, status, message, evidence, failure
    case abortedAtChildPath, expectation, expectationGap, children
}

private enum PublicHeistReportFailureCodingKey: String, CodingKey {
    case category, contract, observed, expected, code, kind, phase, retryable, hint
}

private enum PublicHeistReportDiagnosticsCodingKey: String, CodingKey {
    case failureScreenshotSummary, failureScreenshotFailureKind, failureInterface
}

/// The sole public JSON projection of the canonical `HeistReport`.
struct PublicHeistExecutionResponse: Encodable {
    private let report: HeistReport
    private let profile: ProjectionProfile

    init(report: HeistReport, profile: ProjectionProfile) {
        self.report = report
        self.profile = profile.heistReport
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PublicHeistExecutionResponseKey.self)
        try container.encode(report.failure == nil ? PublicResponseStatus.ok : .partial, forKey: .status)
        try encodeReport(to: container.superEncoder(forKey: .report))
    }

    private func encodeReport(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PublicHeistReportCodingKey.self)
        try encode(report.summary, to: container.superEncoder(forKey: .summary))
        try container.encode(report.metrics, forKey: .metrics)
        var nodes = container.nestedUnkeyedContainer(forKey: .nodes)
        for node in report.nodes {
            try encode(node, to: nodes.superEncoder())
        }
        if report.diagnostics.failureScreenshotSummary != nil || report.diagnostics.failureInterface != nil {
            try encodeDiagnostics(to: container.superEncoder(forKey: .diagnostics))
        }
    }

    private func encode(_ summary: HeistReport.Summary, to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PublicHeistReportSummaryCodingKey.self)
        try container.encode(summary.executedTopLevelStepCount, forKey: .executedTopLevelStepCount)
        try container.encode(summary.executedNodeCount, forKey: .executedNodeCount)
        try container.encode(summary.outputNodeCount, forKey: .outputNodeCount)
        try container.encodeIfPresent(summary.abortedAtPath?.description, forKey: .abortedAtPath)
        try container.encode(summary.durationMs, forKey: .durationMs)
        if let expectations = summary.expectations {
            try encode(expectations, to: container.superEncoder(forKey: .expectations))
        }
    }

    private func encode(_ summary: HeistReport.Expectations, to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PublicHeistExpectationSummaryCodingKey.self)
        try container.encode(summary.checked, forKey: .checked)
        try container.encode(summary.met, forKey: .met)
        try container.encode(summary.allMet, forKey: .allMet)
    }

    private func encode(_ node: HeistReport.Node, to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PublicHeistReportNodeCodingKey.self)
        try container.encode(node.path.description, forKey: .path)
        try container.encode(node.kind.rawValue, forKey: .kind)
        try container.encodeIfPresent(node.capability?.description, forKey: .capability)
        try container.encode(node.status.rawValue, forKey: .status)
        try container.encodeIfPresent(node.message, forKey: .message)
        if let evidence = node.evidence {
            try evidence.encode(to: container.superEncoder(forKey: .evidence), profile: profile)
        }
        if let failure = node.failure {
            try encode(failure, to: container.superEncoder(forKey: .failure))
        }
        try container.encodeIfPresent(node.abortedAtChildPath?.description, forKey: .abortedAtChildPath)
        try container.encodeIfPresent(
            node.expectation.map { ExpectationProjection(result: $0) },
            forKey: .expectation
        )
        try container.encodeIfPresent(node.expectationGap?.publicCode, forKey: .expectationGap)
        var children = container.nestedUnkeyedContainer(forKey: .children)
        for child in node.children {
            try encode(child, to: children.superEncoder())
        }
    }

    private func encode(_ failure: HeistReport.Failure, to encoder: Encoder) throws {
        let diagnostic = failure.diagnosticFailure
        var container = encoder.container(keyedBy: PublicHeistReportFailureCodingKey.self)
        try container.encode(failure.detail.category, forKey: .category)
        try container.encode(failure.detail.contract, forKey: .contract)
        try container.encode(failure.detail.observed, forKey: .observed)
        try container.encodeIfPresent(failure.detail.expected, forKey: .expected)
        try container.encode(diagnostic.details.errorCode, forKey: .code)
        try container.encode(diagnostic.details.code.kind.rawValue, forKey: .kind)
        try container.encode(diagnostic.details.phase.rawValue, forKey: .phase)
        try container.encode(diagnostic.details.retryable, forKey: .retryable)
        try container.encodeIfPresent(diagnostic.details.hint, forKey: .hint)
    }

    private func encodeDiagnostics(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PublicHeistReportDiagnosticsCodingKey.self)
        try container.encodeIfPresent(
            report.diagnostics.failureScreenshotSummary,
            forKey: .failureScreenshotSummary
        )
        try container.encodeIfPresent(
            report.diagnostics.failureScreenshotFailureKind?.rawValue,
            forKey: .failureScreenshotFailureKind
        )
        if let interface = report.diagnostics.failureInterface {
            let failureElementLimit = profile.limits.failureInterfaceElements
            try container.encode(
                InterfaceProjection(
                    interface: interface,
                    detail: .summary,
                    visibleElementBudget: failureElementLimit,
                    totalNodeBudget: min(profile.limits.totalNodeBudget, failureElementLimit)
                ),
                forKey: .failureInterface
            )
        }
    }
}

private extension Observation.Gap {
    var publicCode: String {
        switch self {
        case .notificationIngress:
            "notification_ingress"
        case .captureUnavailable:
            "capture_unavailable"
        case .historyUnavailable:
            "history_unavailable"
        }
    }
}

struct PublicHeistElementEditOmissions: Encodable {
    let added: Int?
    let removed: Int?
    let updated: Int?
    let addedKeys: [String]?
    let removedKeys: [String]?
    let updatedKeys: [String]?

    init(
        added: Int?,
        removed: Int?,
        updated: Int?,
        addedKeys: [String]?,
        removedKeys: [String]?,
        updatedKeys: [String]?
    ) {
        self.added = added
        self.removed = removed
        self.updated = updated
        self.addedKeys = addedKeys
        self.removedKeys = removedKeys
        self.updatedKeys = updatedKeys
    }

    var isEmpty: Bool {
        added == nil
            && removed == nil
            && updated == nil
            && addedKeys == nil
            && removedKeys == nil
            && updatedKeys == nil
    }
}

struct PublicHeistScreenProjection: Encodable {
    let screenDescription: String
    let screenId: String?
    let elementCount: Int
    let elements: [PublicElement]?
    let omittedElementCount: Int?

    init(projection: DeltaScreenProjection) {
        self.screenDescription = projection.screenDescription
        self.screenId = projection.screenId
        self.elementCount = projection.elementCount
        self.elements = projection.elements.isEmpty
            ? nil
            : projection.elements.map { PublicElement(element: $0, detail: .summary) }
        self.omittedElementCount = projection.omittedElementCount
    }
}
