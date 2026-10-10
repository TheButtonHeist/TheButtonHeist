import Foundation

import TheScore

extension FenceResponse {

    // MARK: - Compact Text Format

    /// Token-efficient tree output for LLM agents. Omits geometry.
    @_spi(ButtonHeistTooling) public func compactFormatted() -> String {
        compactFormatted(profile: .summary)
    }

    @_spi(ButtonHeistTooling) public func compactFormatted(profile: ProjectionProfile) -> String {
        switch self {
        case .ok(let message):
            return message
        case .error(let failure):
            return Self.diagnosticText(failure)
        case .status(let connected, let deviceName):
            if connected, let name = deviceName { return "connected: \(name)" }
            return "not connected"
        case .pong(let payload):
            let name = payload.appName.isEmpty ? "App" : payload.appName
            return "pong: \(name) \(payload.bundleIdentifier) [ButtonHeist \(payload.buttonHeistVersion)]"
        case .devices(let devices):
            if devices.isEmpty { return "no devices" }
            return devices.map {
                let name = $0.deviceName.isEmpty ? $0.appName : "\($0.appName) (\($0.deviceName))"
                return "\(name) [\($0.connectionType.rawValue)]"
            }
                .joined(separator: "\n")
        case .interface(let interface, let detail):
            let projectionProfile = ProjectionProfile(
                kind: detail == .full ? .full : profile.kind,
                limits: profile.limits
            )
            let projection = InterfaceProjection(interface: interface, profile: projectionProfile)
            return Self.compactInterface(projection)
        case .notifications(let notifications):
            return Self.compactNotifications(notifications)
        case .action(let result, let expectation):
            return compactActionResult(result, expectation: expectation, profile: profile)
        case .screenshot(let path, let payload, let options):
            return Self.compactScreenshot(
                summary: "screenshot: \(path) (\(Int(payload.width))x\(Int(payload.height)))",
                payload: payload,
                options: options,
                profile: profile
            )
        case .screenshotData(let payload, let options):
            return Self.compactScreenshot(
                summary: "screenshot: \(Int(payload.width))x\(Int(payload.height))",
                payload: payload,
                options: options,
                profile: profile
            )
        case .heistExecution(_, let report):
            return compactHeistFormatted(
                report,
                profile: profile
            )
        case .heistValidation(let report):
            return compactHeistValidation(report)
        case .heistCatalog(let descriptions, let detail):
            return compactHeistCatalog(descriptions, detail: detail)
        case .heistDescription(let description):
            return compactHeistDescription(description)
        case .sessionState(let payload):
            return Self.compactSessionState(payload)
        case .targets(let targets, let defaultTarget):
            if targets.isEmpty { return "no targets configured" }
            return targets.sorted(by: { $0.key.rawValue < $1.key.rawValue }).map { name, target in
                let isDefault = name == defaultTarget ? " *" : ""
                return "\(name.rawValue): \(target.device)\(isDefault)"
            }.joined(separator: "\n")
        }
    }

    static func diagnosticText(
        _ failure: DiagnosticFailure,
        headline: String = "error"
    ) -> String {
        diagnosticLines(failure, headline: headline).joined(separator: "\n")
    }

    static func diagnosticLines(
        _ failure: DiagnosticFailure,
        headline: String = "error"
    ) -> [String] {
        let details = failure.details
        let message = failure.message
        var lines = ["\(headline)[\(details.errorCode) \(details.phase.rawValue) retryable=\(details.retryable)]: \(message)"]
        if let hint = details.hint {
            lines.append("hint: \(hint)")
        }
        lines.append(contentsOf: failure.buildDiagnostics.map { diagnostic in
            "diagnostic[\(diagnostic.code.rawValue) \(diagnostic.phase.rawValue) \(diagnostic.kind.rawValue)]: " +
                diagnostic.message
        })
        return lines
    }

    private static func compactScreenshot(
        summary: String,
        payload: ScreenPayload,
        options: ScreenshotResponseOptions,
        profile: ProjectionProfile
    ) -> String {
        guard options.includeInterface else { return summary }
        var lines = [summary]
        if let interface = payload.interface {
            let projection = InterfaceProjection(
                interface: interface,
                profile: ProjectionProfile(kind: .full, limits: profile.limits)
            )
            lines.append(compactInterface(projection))
        } else {
            lines.append("interface: unavailable")
        }
        return lines.joined(separator: "\n")
    }

    private static func compactNotifications(
        _ notifications: [Observation.Notification]
    ) -> String {
        guard !notifications.isEmpty else {
            return "notifications: none"
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

}
