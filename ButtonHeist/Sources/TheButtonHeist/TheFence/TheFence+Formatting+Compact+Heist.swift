import Foundation

import TheScore

extension FenceResponse {

    func compactHeistFormatted(
        _ report: HeistReport,
        profile: ProjectionProfile
    ) -> String {
        let profile = profile.heistReport
        var text = "heist: \(report.summary.executedTopLevelStepCount) top-level steps in \(report.summary.durationMs)ms"
        if let abortedAtPath = report.summary.abortedAtPath {
            text += " (stopped at \(abortedAtPath))"
        }
        if let expectations = report.summary.expectations {
            text += " [expectations: \(expectations.met)/\(expectations.checked)]"
        }
        if let lastScreenId = report.summary.finalScreenId {
            text = "\(lastScreenId) | \(text)"
        }
        for (index, step) in report.outputNodes.enumerated() {
            var line = "  [\(index)] \(Self.compactHeistStepName(step))"
            var detailLines: [String] = []
            let delta = step.evidence?.observationDelta(profile: profile)
            if let failure = step.failure {
                let diagnosticLines = Self.diagnosticLines(failure.diagnosticFailure)
                line += " -> \(diagnosticLines[0])"
                detailLines.append(contentsOf: diagnosticLines.dropFirst().map { "    \($0)" })
                if !failure.detail.contract.isEmpty,
                   failure.detail.contract != failure.diagnosticMessage {
                    detailLines.append("    contract: \(failure.detail.contract)")
                }
                if let expected = failure.detail.expected, !expected.isEmpty {
                    detailLines.append("    expected: \(expected)")
                }
                detailLines = Self.compactHeistFailureDeltaLines(delta)
                    + detailLines
                if let timing = step.evidence?.expectationTiming {
                    detailLines.append("    expectation: \(Self.compactExpectationTiming(timing))")
                }
                if let activationTrace = step.activationTrace {
                    detailLines.append("    activation: \(Self.compactActivationTrace(activationTrace))")
                }
            } else if step.status == .skipped {
                line += " -> skipped"
            } else if let warning = step.warning {
                line += " -> warning: \(warning.message)"
            } else if let delta {
                line += " -> \(Self.compactDeltaRendering(delta).summary)"
            }
            if let expectation = step.expectation {
                line += expectation.met ? " ✓" : " ✗"
            } else if step.expectationGap != nil {
                line += " ?"
            }
            text += "\n\(line)"
            if !detailLines.isEmpty {
                text += "\n" + detailLines.joined(separator: "\n")
            }
        }
        if let screenshot = report.diagnostics.failureScreenshotSummary {
            text += "\n\(screenshot)"
        }
        if let interface = report.diagnostics.failureInterfaceDump(
            elementLimit: profile.limits.failureInterfaceElements
        ) {
            text += "\n\(interface)"
        }
        return text
    }

    private static func compactHeistFailureDeltaLines(
        _ delta: DeltaProjection?
    ) -> [String] {
        guard let delta else { return [] }
        let rendering = Self.compactDeltaRendering(delta)
        return ["    evidence: \(rendering.summary)"]
            + rendering.detailLines.map { "    \($0)" }
    }

    private static func compactHeistStepName(_ step: HeistReport.Node) -> String {
        step.invocationDisplayName ?? step.command?.rawValue ?? step.kind.rawValue
    }

    private static func compactExpectationTiming(
        _ timing: HeistExpectationTiming
    ) -> String {
        var text = "budget=\(timing.budgetMs)ms elapsed=\(timing.elapsedMs)ms"
        if let lastTreeChangeElapsedMs = timing.lastTreeChangeElapsedMs {
            text += " lastTreeChange=\(lastTreeChangeElapsedMs)ms"
        }
        return text
    }

}

private extension HeistReport.Evidence {
    func observationDelta(profile: ProjectionProfile) -> DeltaProjection? {
        observation.flatMap {
            DeltaProjection(
                evidence: $0,
                profile: profile,
                includeScreenInterface: true
            )
        }
    }

    var expectationTiming: HeistExpectationTiming? {
        expectationEvidence?.timing
    }
}
