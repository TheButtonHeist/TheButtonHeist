import Foundation

import ThePlans
import TheScore

import AccessibilitySnapshotModel

extension FenceResponse {

    // MARK: - Human Formatting

    @_spi(ButtonHeistTooling) public func humanFormatted() -> String {
        switch self {
        case .ok(let message):
            return message
        case .error(let failure):
            return Self.diagnosticText(failure, headline: "Error")
        case .status(let connected, let deviceName):
            if connected, let name = deviceName {
                return "Connected to \(name)"
            }
            return "Not connected"
        case .pong(let payload):
            return Self.formatPongHuman(payload)
        case .devices(let devices):
            return formatDeviceList(devices)
        case .interface(let interface, let detail):
            return formatInterface(interface, detail: detail)
        case .notifications(let notifications):
            return formatNotifications(notifications)
        case .action(let command, let result, let expectation):
            var text = formatActionResult(command: command, result: result)
            if result.outcome.isSuccess, let expectation {
                if expectation.met {
                    text += "  [expectation met]"
                } else {
                    let tier = expectation.predicate.map(String.init(describing:)) ?? "delivery"
                    text += "  [expectation FAILED: expected \(tier), got \(expectation.actual ?? "nil")]"
                    if let hint = Self.expectationFailureHint(expectation, command: command, result: result) {
                        text += "  [hint: \(hint)]"
                    }
                }
            }
            return text
        case .screenshot(let path, let payload, let options):
            return formatScreenshot(
                summary: "✓ Screenshot saved: \(path)  (\(Int(payload.width)) × \(Int(payload.height)))",
                payload: payload,
                options: options
            )
        case .screenshotData(let payload, let options):
            return formatScreenshot(
                summary: "✓ Screenshot captured (\(Int(payload.width)) × \(Int(payload.height))) — base64 PNG follows\n\(payload.pngData)",
                payload: payload,
                options: options
            )
        case .heistExecution(_, let report):
            return humanHeistFormatted(report)
        case .heistValidation(let report):
            return formatHeistValidationHuman(report)
        case .heistCatalog(let descriptions, let detail):
            return formatHeistCatalogHuman(descriptions, detail: detail)
        case .heistDescription(let description):
            return formatHeistDescriptionHuman(description)
        case .sessionState(let payload):
            return Self.formatSessionStateHuman(payload)
        case .targets(let targets, let defaultTarget):
            return formatTargetList(targets, defaultTarget: defaultTarget)
        }
    }

    private func formatNotifications(
        _ notifications: [Observation.Notification]
    ) -> String {
        guard !notifications.isEmpty else {
            return "No accessibility notifications retained"
        }
        return notifications.enumerated().map { index, notification in
            let facts = [
                notification.text.map { "text=\"\($0)\"" },
                notification.element.map { "element=\"\($0.spokenDescription)\"" },
            ].compactMap { $0 }
            return "[\(index)] " + facts.joined(separator: " ")
        }
        .joined(separator: "\n")
    }

    private static func formatSessionStateHuman(_ payload: SessionStatePayload) -> String {
        switch payload.state {
        case .connected(let device):
            return "Session: connected to \(device.deviceName)"
        case .connecting:
            return "Session: connecting"
        case .failed(let failure):
            if let failure = sessionStateFailureSummary(failure) {
                return "Session: failed (\(failure))"
            }
            return "Session: failed"
        case .disconnected(let lastFailure):
            if let failure = sessionStateFailureSummary(lastFailure) {
                return "Session: disconnected (\(failure))"
            }
            return "Session: not connected"
        }
    }

    private func humanHeistFormatted(_ report: HeistReport) -> String {
        var text = "Heist: \(report.summary.executedTopLevelStepCount) top-level step(s) executed in \(report.summary.durationMs)ms"
        if let abortedAtPath = report.summary.abortedAtPath {
            text += " (stopped at \(abortedAtPath))"
        }
        if let expectations = report.summary.expectations {
            text += " [expectations: \(expectations.met)/\(expectations.checked) met]"
        }
        if let failedNode = report.failedNode,
           let failure = failedNode.failure {
            text += "\n" + Self.diagnosticText(
                failure.diagnosticFailure,
                headline: "Error at \(failedNode.path) "
            )
            if !failure.detail.contract.isEmpty,
               failure.detail.contract != failure.detail.observed {
                text += "\ncontract: \(failure.detail.contract)"
            }
            if let expected = failure.detail.expected, !expected.isEmpty {
                text += "\nexpected: \(expected)"
            }
        }
        if let screenshot = report.diagnostics.failureScreenshotSummary {
            text += "\n\(screenshot)"
        }
        if let interface = report.diagnostics.failureInterfaceDump(
            elementLimit: HeistFailureDiagnostics.defaultElementLimit
        ) {
            text += "\n\(interface)"
        }
        return text
    }

    private static func formatPongHuman(_ payload: PongPayload) -> String {
        var parts = [
            payload.appName.isEmpty ? "App" : payload.appName,
            "bundle: \(payload.bundleIdentifier)",
            "ButtonHeist: \(payload.buttonHeistVersion)",
        ]
        if let version = payload.appVersion, !version.isEmpty {
            parts.append("version: \(version)")
        }
        if let build = payload.appBuild, !build.isEmpty {
            parts.append("build: \(build)")
        }
        if let identifier = payload.serverInstanceIdentifier {
            parts.append("server: \(identifier)")
        }
        if let timestamp = payload.serverTimestampMs {
            parts.append("serverTimestampMs: \(timestamp)")
        }
        return "Pong: " + parts.joined(separator: ", ")
    }

    private static func sessionStateFailureSummary(_ failure: SessionFailurePayload?) -> String? {
        guard let failure else { return nil }
        if let hint = failure.hint {
            return "\(failure.code): \(hint)"
        }
        if let message = failure.message {
            return "\(failure.code): \(message)"
        }
        return failure.code
    }

    private func formatTargetList(_ targets: [TargetName: TargetConfig], defaultTarget: TargetName?) -> String {
        if targets.isEmpty { return "No targets configured" }
        var output = "\(targets.count) target(s):\n"
        for name in targets.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let target = targets[name] else { continue }
            let isDefault = name == defaultTarget ? " (default)" : ""
            output += "  \(name.rawValue): \(target.device)\(isDefault)\n"
        }
        return output.trimmingCharacters(in: .newlines)
    }

    private func formatDeviceList(_ devices: [DiscoveredDevice]) -> String {
        if devices.isEmpty { return "No devices found" }
        var output = "\(devices.count) device(s):\n"
        for (index, device) in devices.enumerated() {
            let id = device.shortId ?? "----"
            let typeLabel = switch device.connectionType {
            case .simulator: "sim"
            case .usb: "usb"
            case .network: "network"
            }
            let name = device.deviceName.isEmpty ? device.appName : "\(device.appName)  (\(device.deviceName))"
            output += "  [\(index)] \(id)  \(name)  [\(typeLabel)]\n"
        }
        return output.trimmingCharacters(in: .newlines)
    }

    // MARK: - Human Format Helpers

    private func formatInterface(_ interface: Interface, detail: InterfaceDetail) -> String {
        let profile = ProjectionProfile(
            kind: detail == .full ? .full : .summary,
            limits: .current()
        )
        return formatInterface(InterfaceProjection(interface: interface, profile: profile))
    }

    private func formatInterface(_ projection: InterfaceProjection) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium

        var output = "\(projection.elementCount) elements (\(formatter.string(from: projection.timestamp)))\n"
        if let discovery = projection.diagnostics?.discovery {
            output += formatDiscoveryDiagnostics(discovery).joined(separator: "\n")
            output += "\n"
        }
        output += String(repeating: "-", count: 60) + "\n"

        if projection.tree.isEmpty {
            output += "  (no elements)\n"
        } else {
            output += formatTreeLines(projection).joined(separator: "\n")
            output += "\n"
        }
        output += String(repeating: "-", count: 60)
        return output
    }

    private func formatDiscoveryDiagnostics(_ diagnostics: InterfaceDiscoveryDiagnostics) -> [String] {
        let reasonCodes = diagnostics.reasonCodes.map(\.rawValue)
        let reason = reasonCodes.isEmpty ? "" : " [\(reasonCodes.joined(separator: ", "))]"
        var lines = [
            """
            discovery: \(diagnostics.state.rawValue)\(reason), included elements: \(diagnostics.includedElementCount), \
            scroll attempts: \(diagnostics.scrollAttempts)/\(diagnostics.maxScrollsPerDiscovery), \
            explored containers: \(diagnostics.exploredScrollableContainerCount), \
            omitted containers: \(diagnostics.omittedScrollableContainerCount)
            """,
        ]
        if let nextAction = diagnostics.nextAction {
            lines.append("next: \(nextAction)")
        }
        return lines
    }

    private func formatTreeLines(_ projection: InterfaceProjection) -> [String] {
        projection.tree.flatMap { formatTreeLines($0, depth: 0, detail: projection.detail) }
    }

    private func formatTreeLines(
        _ node: InterfaceNodeProjection,
        depth: Int,
        detail: InterfaceDetail
    ) -> [String] {
        let prefix = String(repeating: "  ", count: depth)
        switch node {
        case .element(let projection):
            return [prefix + formatElement(
                projection.element,
                displayIndex: projection.order ?? 0,
                detail: detail
            )]
        case .container(let projection):
            let containerLines = formatContainerLines(
                projection.container,
                containerName: projection.containerName,
                detail: detail
            ).map { prefix + $0 }
            let childLines = projection.children.flatMap { child in
                formatTreeLines(
                    child,
                    depth: depth + 1,
                    detail: detail
                )
            }
            return containerLines + childLines
        }
    }

    private func formatElement(_ element: HeistElement, displayIndex: Int, detail: InterfaceDetail) -> String {
        let assertable = element.semantics.assertable
        var parts: [String] = [String(format: "[%2d]", displayIndex)]
        var labelValue = Self.quotedString(
            Self.nonEmpty(assertable.label) ?? element.semantics.spokenDescription
        )
        if let value = Self.nonEmpty(assertable.value) {
            labelValue += " value=\(Self.quotedString(value))"
        }
        parts.append(labelValue)

        let traits = assertable.orderedTraits.filter { $0.rawValue != "none" }
        if !traits.isEmpty {
            parts.append("traits=\(traits.map(\.rawValue).joined(separator: " | "))")
        }
        if !assertable.actions.isEmpty {
            parts.append(
                "actions=\(assertable.orderedActions.map(\.description).joined(separator: ", "))"
            )
        }
        let rotors = assertable.orderedRotors.compactMap { Self.nonEmpty($0.name) }
        if !rotors.isEmpty {
            parts.append("rotors=\(rotors.map(Self.quotedString).joined(separator: ", "))")
        }
        if let hint = Self.nonEmpty(assertable.hint) {
            parts.append("hint=\(Self.quotedString(hint))")
        }
        if let identifier = Self.nonEmpty(assertable.identifier) {
            parts.append("id=\(Self.quotedString(identifier))")
        }
        if detail == .full,
           case .onscreen(let frameEvidence, let activationPointEvidence) = element.geometry.screen {
            if let frame = frameEvidence.rect {
                parts.append(
                    "frame=(\(Self.geometryDescription(frame.x.value)),\(Self.geometryDescription(frame.y.value))," +
                        "\(Self.geometryDescription(frame.width.value)),\(Self.geometryDescription(frame.height.value)))"
                )
            }
            let explicitPoint = activationPointEvidence.point
            let x = explicitPoint?.x ?? frameEvidence.rect?.midX
            let y = explicitPoint?.y ?? frameEvidence.rect?.midY
            if let x, let y {
                parts.append(
                    "activation=(\(Self.geometryDescription(x)),\(Self.geometryDescription(y)))"
                )
            }
        }
        return parts.joined(separator: " ")
    }

    private func formatContainerLines(
        _ container: AccessibilityContainer,
        containerName: String?,
        detail: InterfaceDetail
    ) -> [String] {
        let facts = container.containerPredicateFacts
        let identifier = Self.nonEmpty(facts.identifier)
        let containerName = Self.nonEmpty(containerName)
        var parts: [String]
        switch facts.role {
        case .none:
            parts = ["container"]
        case .semanticGroup(let label, let value):
            parts = ["group"]
            if let label = Self.nonEmpty(label) { parts.append(Self.quotedString(label)) }
            if let value = Self.nonEmpty(value) { parts.append("value=\(Self.quotedString(value))") }
            if let identifier {
                parts.append("id=\(Self.quotedString(identifier))")
            }
        case .list:
            parts = ["list"]
        case .landmark:
            parts = ["landmark"]
        case .dataTable(let rowCount, let columnCount):
            parts = ["table", "rows=\(rowCount)", "columns=\(columnCount)"]
        case .tabBar:
            parts = ["tab_bar"]
        case .series:
            parts = ["series"]
        }
        if let containerName {
            parts.append("containerName: \(containerName)")
        }
        if case .semanticGroup = facts.role {
        } else if let identifier {
            parts.append("id=\(Self.quotedString(identifier))")
        }
        let actionNames = container.customActions.map(\.name).filter { !$0.isEmpty }
        if !actionNames.isEmpty {
            parts.append("actions=\(actionNames.map(Self.quotedString).joined(separator: ", "))")
        }
        if let contentSize = container.scrollableContentSize {
            let frame = container.frame
            if let viewportWidth = try? FiniteDimension(validating: frame.size.width),
               let viewportHeight = try? FiniteDimension(validating: frame.size.height),
               let contentWidth = try? FiniteDimension(validating: contentSize.width),
               let contentHeight = try? FiniteDimension(validating: contentSize.height) {
                parts.append(
                    "viewport=\(Self.geometryDescription(viewportWidth.value))x" +
                        "\(Self.geometryDescription(viewportHeight.value))"
                )
                parts.append(
                    "content=\(Self.geometryDescription(contentWidth.value))x" +
                        "\(Self.geometryDescription(contentHeight.value))"
                )
            }
        }
        if facts.isModalBoundary {
            parts.append("modal=true")
        }
        if detail == .full {
            if let frame = ScreenFrameEvidence(container.frame).rect {
                parts.append(
                    "frame=(\(Self.geometryDescription(frame.x.value)),\(Self.geometryDescription(frame.y.value))," +
                        "\(Self.geometryDescription(frame.width.value)),\(Self.geometryDescription(frame.height.value)))"
                )
            }
        }
        return [parts.joined(separator: " ")]
    }

    private func formatScreenshot(
        summary: String,
        payload: ScreenPayload,
        options: ScreenshotResponseOptions
    ) -> String {
        guard options.includeInterface else { return summary }
        var lines = [summary]
        if let interface = payload.interface {
            lines.append(formatInterface(interface, detail: .full))
        } else {
            lines.append("interface: unavailable")
        }
        return lines.joined(separator: "\n")
    }

    private func formatActionResult(command: TheFence.Command, result: ActionResult) -> String {
        let methodName = command.rawValue
        let projection = ActionProjection(method: command.rawValue, result: result, profile: .summary)
        if let failure = projection.failure {
            return Self.diagnosticText(failure, headline: "Error")
        }
        var output = "✓ \(methodName)"
        if case .value(let value) = projection.payload {
            output += "  value: \"\(value)\""
        }
        if case .rotor(let search) = projection.payload {
            output += "  rotor: \"\(search.rotor)\" \(search.direction.rawValue)"
            if let foundElement = search.foundElement {
                let description = foundElement.semantics.assertable.label
                    ?? foundElement.semantics.spokenDescription
                output += " → \(description)"
            }
            if let textRange = search.textRange {
                output += "  range: \(textRange.rangeDescription)"
                if let text = textRange.text {
                    output += " \"\(text)\""
                }
            }
        }
        if let delta = projection.delta {
            output += "  \(formatDelta(delta))"
        }
        if let announcement = projection.announcement {
            output += "  announcement: \"\(announcement)\""
        }
        if let activationTrace = projection.activationTrace {
            output += "  [activate: \(Self.compactActivationTrace(activationTrace))]"
        }
        if let handler = projection.screenActionHandler {
            output += "  Handler: \(handler)"
        }
        return output
    }

    /// Actions that aren't implied by the element's traits.
    /// `activate` is implied by `.button`; `typeText` by text-input traits;
    /// `increment`/`decrement` by `.adjustable`.
    static func meaningfulActions(_ element: HeistElement) -> [ElementAction] {
        let assertable = element.semantics.assertable
        return assertable.orderedActions.filter { action in
            switch action {
            case .activate: return !assertable.traits.contains(.button)
            case .typeText: return !AccessibilityPolicy.supportsTextEntry(assertable.traits)
            case .increment, .decrement: return !assertable.traits.contains(.adjustable)
            case .custom: return true
            }
        }
    }

    static func geometryDescription(_ value: Double) -> String {
        guard value.isFinite else { return "unavailable" }
        guard value >= Double(Int.min), value <= Double(Int.max) else { return String(value) }
        return String(Int(value))
    }

    private func formatDelta(_ projection: DeltaProjection) -> String {
        switch projection {
        case .noChange(let elementCount):
            return "[\(elementCount) elements, no change]"
        case .elementsChanged(let elementCount, let edits):
            var parts: [String] = ["\(elementCount) elements"]
            if edits.added.values.count > 0 {
                let addedCount = edits.added.values.count
                parts.append("+\(addedCount) added")
            }
            if edits.removed.values.count > 0 {
                let removedCount = edits.removed.values.count
                parts.append("-\(removedCount) removed")
            }
            if edits.updated.values.count > 0 {
                let updatedCount = edits.updated.values.count
                parts.append("~\(updatedCount) updated")
            }
            let detail = Self.compactElementEditLines(edits: edits)
            guard !detail.isEmpty else {
                return "[" + parts.joined(separator: ", ") + "]"
            }
            return "[" + parts.joined(separator: ", ") + ": " + detail.joined(separator: "; ") + "]"
        case .screenChanged(let elementCount, let screen):
            let compactInterface = screen.interface.map {
                Self.compactInterface($0)
            } ?? ""
            return "[\(elementCount) elements, screen changed]\n" + compactInterface
        }
    }

    private static func compactElementEditLines(edits: DeltaEditsProjection) -> [String] {
        var lines: [String] = []
        lines.append(contentsOf: edits.added.values.map { "+ \(compactElementLine($0))" })
        lines.append(contentsOf: edits.removed.values.map { "- \(compactElementLine($0))" })
        for update in edits.updated.values {
            let assertable = update.after.semantics.assertable
            let name = nonEmpty(assertable.label)
                ?? nonEmpty(assertable.value)
                ?? nonEmpty(assertable.identifier)
                ?? update.after.semantics.spokenDescription
            for change in update.changes where !change.property.isGeometry {
                lines.append("~ \(name): \(change.property.rawValue) \"\(display(change.oldValue))\" -> \"\(display(change.newValue))\"")
            }
        }
        return lines
    }

    private static func display(_ value: ElementPropertyValue?) -> String {
        value?.displayText ?? "nil"
    }
}
