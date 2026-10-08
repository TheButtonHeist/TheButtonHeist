import Foundation
import ThePlans
import TheScore

private struct HeistJUnitXML {
    private let heistName: String
    private let app: String
    private let report: HeistReport

    init(
        heistName: String,
        app: String,
        report: HeistReport
    ) {
        self.heistName = heistName
        self.app = app
        self.report = report
    }
}

extension HeistJUnitXML {
    /// Generate a JUnit XML report string.
    ///
    /// The structure follows the JUnit XML schema consumed by CI systems
    /// (GitHub Actions, Jenkins, CircleCI, etc.):
    /// ```
    /// <testsuites> → <testsuite> → <testcase> [→ <failure>]
    /// ```
    /// Each heist is one `<testcase>`. A failed heist includes a `<failure>`
    /// element with step-level diagnostics in the body.
    func render() -> String {
        let totalTime = String(format: "%.3f", Double(report.summary.durationMs) / 1000)
        let failedNode = report.failedNode
        let failed = failedNode == nil ? "0" : "1"

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += JUnitXML.startElement("testsuites", attributes: [
            JUnitXML.Attribute("name", "heist"),
            JUnitXML.Attribute("tests", "1"),
            JUnitXML.Attribute("failures", failed),
            JUnitXML.Attribute("time", totalTime),
        ])
        xml += JUnitXML.startElement("testsuite", attributes: [
            JUnitXML.Attribute("name", heistName),
            JUnitXML.Attribute("tests", "1"),
            JUnitXML.Attribute("failures", failed),
            JUnitXML.Attribute("time", totalTime),
        ], indentation: "  ")

        let testcaseAttributes = [
            JUnitXML.Attribute("name", heistName),
            JUnitXML.Attribute("classname", app),
            JUnitXML.Attribute("time", totalTime),
        ]

        if let failedNode,
           let index = report.outputNodes.firstIndex(where: { $0.path == failedNode.path }) {
            xml += JUnitXML.startElement("testcase", attributes: testcaseAttributes, indentation: "    ")
            let message = Self.failureMessage(for: failedNode, report: report)
            xml += JUnitXML.textElement(
                "failure",
                attributes: [
                    JUnitXML.Attribute("message", message),
                    JUnitXML.Attribute("type", Self.failureType(for: failedNode) ?? "heistFailure"),
                ],
                text: failureBody(failedNode, index: index, message: message),
                indentation: "      "
            )
            xml += "    </testcase>\n"
        } else {
            xml += JUnitXML.selfClosingElement(
                "testcase",
                attributes: testcaseAttributes,
                indentation: "    "
            )
        }

        xml += "  </testsuite>\n"
        xml += "</testsuites>\n"
        return xml
    }

    // MARK: - Private Helpers

    private func failureBody(_ node: HeistReport.Node, index: Int, message: String) -> String {
        let passedCount = report.outputNodes.count(where: { $0.status == .passed })
        var body = "Completed \(passedCount)/\(report.outputNodes.count) result node(s) before failure.\n"
        body += "step: [\(index)] \(node.command?.rawValue ?? node.kind.rawValue)\n"
        if let target = node.target {
            var parts: [String] = []
            if case .predicate(let template, _) = target,
               let predicate = try? template.resolve(in: .empty) {
                parts = predicate.checks.compactMap(CanonicalValueDescription.predicateCheckField)
            }
            if !parts.isEmpty {
                body += "target: \(parts.joined(separator: ", "))\n"
            }
        }
        body += "error: \(message)"
        return body
    }

    private static func failureMessage(
        for node: HeistReport.Node,
        report: HeistReport
    ) -> String {
        let message = node.failure?.diagnosticMessage ?? node.message ?? "heist failed"
        let diagnostic = node.failure?.diagnosticFailure
        var lines = [message]
        if let diagnostic {
            lines.append("code: \(diagnostic.details.errorCode)")
            lines.append("kind: \(diagnostic.details.code.kind.rawValue)")
            lines.append("phase: \(diagnostic.details.phase.rawValue)")
            lines.append("retryable: \(diagnostic.details.retryable)")
            if let hint = diagnostic.details.hint {
                lines.append("hint: \(hint)")
            }
        }
        if node.path == report.summary.abortedAtPath {
            if let screenshot = report.diagnostics.failureScreenshotSummary {
                lines.append(screenshot)
            }
            if let interfaceDump = report.diagnostics.failureInterfaceDump(
                elementLimit: HeistFailureDiagnostics.defaultElementLimit
            ) {
                lines.append(interfaceDump)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func failureType(for node: HeistReport.Node) -> String? {
        if let failureKind = node.failure?.actionKind {
            return failureKind.rawValue
        }
        switch node.failure?.detail.category {
        case .internalInvariant,
             .validation,
             .runtimeUnavailable,
             .targetResolution,
             .invocation,
             .loop,
             .explicitFailure:
            return "commandError"
        case .timeout:
            return ActionFailure.Kind.timeout.rawValue
        case .action, .expectation, .wait, .none:
            return nil
        }
    }
}

extension TheFence {
    /// Render a finished heist report as the JUnit XML consumed by
    /// `run_heist --junit`.
    public func junitXML(
        for report: HeistReport,
        heistName: String
    ) -> String {
        HeistJUnitXML(
            heistName: heistName,
            app: handoff.connectionLifecycle.serverInfo?.bundleIdentifier.description ?? "unknown",
            report: report
        ).render()
    }
}

private enum JUnitXML {
    struct Attribute {
        let name: String
        let value: String

        init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    static func startElement(
        _ name: String,
        attributes: [Attribute],
        indentation: String = ""
    ) -> String {
        "\(indentation)<\(name)\(renderedAttributes(attributes))>\n"
    }

    static func selfClosingElement(
        _ name: String,
        attributes: [Attribute],
        indentation: String = ""
    ) -> String {
        "\(indentation)<\(name)\(renderedAttributes(attributes))/>\n"
    }

    static func textElement(
        _ name: String,
        attributes: [Attribute],
        text: String,
        indentation: String = ""
    ) -> String {
        "\(indentation)<\(name)\(renderedAttributes(attributes))>\(escape(text))</\(name)>\n"
    }

    private static func renderedAttributes(_ attributes: [Attribute]) -> String {
        attributes.map { attribute in
            " \(attribute.name)=\"\(escape(attribute.value))\""
        }.joined()
    }

    /// Escape special XML characters in text content and attribute values.
    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
