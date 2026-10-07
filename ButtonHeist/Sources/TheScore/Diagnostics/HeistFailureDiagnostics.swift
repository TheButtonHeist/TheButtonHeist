import Foundation
import ThePlans

public enum HeistFailureDiagnostics {
    public static let defaultElementLimit = 20

    public static func screenshotSummary(
        _ screenshot: ScreenPayload
    ) -> String {
        var parts = [
            "failure screenshot: \(Int(screenshot.width))x\(Int(screenshot.height))",
        ]
        if let interface = screenshot.interface {
            parts.append("interface=\(interface.projectedElements.count) elements")
        } else {
            parts.append("interface=unavailable")
        }
        return parts.joined(separator: " ")
    }

    public static func unavailableScreenshotSummary(
        message: String?
    ) -> String {
        var parts = ["failure screenshot: unavailable"]
        if let message, !message.isEmpty {
            parts.append("message=\(ElementDiagnosticSummary.RenderProfile.failureInterface().renderString(message))")
        }
        return parts.joined(separator: " ")
    }

    public static func interfaceDump(
        _ interface: Interface,
        elementLimit: Int = defaultElementLimit
    ) -> String {
        let elements = interface.projectedElements
        let limit = max(0, elementLimit)
        var lines = ["failure interface: \(elements.count) elements"]
        if elements.isEmpty {
            lines.append("  (no elements)")
        } else {
            lines.append(contentsOf: elements.prefix(limit).enumerated().map { index, element in
                "  " + elementLine(element, displayIndex: index, includeGeometry: true)
            })
            let omitted = elements.count - min(elements.count, limit)
            if omitted > 0 {
                lines.append("  ... and \(omitted) more")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func elementLine(
        _ element: HeistElement,
        displayIndex: Int? = nil,
        includeGeometry: Bool = false
    ) -> String {
        ElementDiagnosticSummary(
            element: element,
            actions: meaningfulActions(element)
        ).rendered(using: .failureInterface(
            displayIndex: displayIndex,
            includeGeometry: includeGeometry
        ))
    }

    private static func meaningfulActions(_ element: HeistElement) -> [ElementAction] {
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
}

public extension HeistResult {
    package var failureScreenshotPayload: ScreenPayload? {
        failureCapture?.payload
    }

    package var observedInterfaceAtFailure: Interface? {
        firstFailedStep?.observedInterfaceAtStep
    }

    /// Failure evidence for diagnostic rendering, not current semantic interface state.
    package var failureDiagnosticInterface: Interface? {
        let interface = failureScreenshotPayload?.interface ?? observedInterfaceAtFailure
        return interface?.projectedElements.isEmpty == false ? interface : nil
    }

    var failureScreenshotSummary: String? {
        guard let failureCapture else { return nil }
        if let screenshot = failureCapture.payload {
            return HeistFailureDiagnostics.screenshotSummary(screenshot)
        }
        return HeistFailureDiagnostics.unavailableScreenshotSummary(
            message: failureCapture.message
        )
    }

    func failureInterfaceDump(
        elementLimit: Int = HeistFailureDiagnostics.defaultElementLimit
    ) -> String? {
        failureDiagnosticInterface.map {
            HeistFailureDiagnostics.interfaceDump($0, elementLimit: elementLimit)
        }
    }
}

public extension HeistExecutionStepResult {
    package var observedInterfaceAtStep: Interface? {
        (actionEvidence?.result?.observationEvidence ?? waitEvidence?.observation)?.current?.interface
    }
}
