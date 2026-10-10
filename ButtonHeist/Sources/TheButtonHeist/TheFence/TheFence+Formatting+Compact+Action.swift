import Foundation

import TheScore

extension FenceResponse {

    func compactActionResult(
        _ result: ActionResult,
        expectation: ExpectationResult?,
        profile: ProjectionProfile = .summary
    ) -> String {
        let projection = ActionProjection(
            method: result.method.rawValue,
            result: result,
            expectation: expectation,
            expectationHint: expectation.flatMap {
                Self.expectationFailureHint($0, result: result)
            },
            profile: profile
        )
        return Self.compactActionResult(projection)
    }

    static func compactActionResult(_ projection: ActionProjection) -> String {
        guard projection.failure == nil else {
            return compactActionFailure(projection)
        }

        var text: String
        switch projection.payload {
        case .rotor(let rotor):
            text = Self.compactRotor(rotor)
        case .screenshot(let width, let height):
            text = "screenshot: \(Int(width))x\(Int(height))"
        case .value, .none:
            if let delta = projection.delta {
                text = Self.compactDelta(delta, method: projection.method)
            } else {
                text = "\(projection.method): ok"
            }
        }
        if let screenId = projection.screenId {
            text = "\(screenId) | \(text)"
        }
        if case .value(let value) = projection.payload {
            text += "\nvalue: \"\(value)\""
        }
        if let announcement = projection.announcement {
            text += "\nannouncement: \"\(announcement)\""
        }
        if let activationTrace = projection.activationTrace {
            text += "\nactivate: \(Self.compactActivationTrace(activationTrace))"
        }
        if let handler = projection.screenActionHandler {
            text += "\nHandler: \(handler)"
        }
        if let expectation = projection.expectation, !expectation.met {
            text += "\n[expectation FAILED: got \(expectation.actual ?? "nil")]"
            if let hint = expectation.hint {
                text += "\nhint: \(hint)"
            }
        }
        return text
    }

    /// Recovery hint for failed expectations whose observed typed facts are
    /// easy to misread without the action semantics.
    static func expectationFailureHint(
        _ expectation: ExpectationResult,
        result: ActionResult? = nil
    ) -> String? {
        guard case .unmet = expectation,
              let result,
              result.outcome.isSuccess,
              let observationEvidence = result.observationEvidence,
              let changeKind = DeltaProjection(
                  evidence: observationEvidence,
                  profile: .summary
              )?.kind
        else { return nil }

        if expectation.predicate == .screenChanged,
           changeKind == .elementsChanged {
            return ".screenChanged requires a screen-level transition; " +
                "use .elementsChanged for same-screen element updates " +
                "or wait when the UI may settle asynchronously"
        }

        guard isActivateNoChangeExpectation(expectation, result: result, changeKind: changeKind) else {
            return nil
        }
        return "activate uses accessibilityActivate() and trusts a true return; " +
            "it does not send activation-point tap dispatch after semantic activation succeeds. " +
            "If oneFingerTap changes the UI, the touch path works but the accessibility activation path is inert or mismatched."
    }

    private static func isActivateNoChangeExpectation(
        _ expectation: ExpectationResult,
        result: ActionResult,
        changeKind: DeltaProjectionKind
    ) -> Bool {
        guard changeKind == .noChange,
              result.method == .activate,
              let predicate = expectation.predicate
        else { return false }
        switch predicate.core {
        case .screenChanged, .elementsChanged: return true
        case .presence, .notification: return false
        }
    }

    static func compactActivationTrace(_ trace: ActivationTrace) -> String {
        var parts = ["axActivateReturned=\(formatBool(trace.axActivateReturned))"]
        parts.append("tapActivationDispatched=\(trace.tapActivationDispatched)")
        if let point = trace.tapActivationPoint {
            parts.append("tapActivationPoint=\(point.description)")
        }
        if let succeeded = trace.tapActivationSucceeded {
            parts.append("tapActivationSucceeded=\(succeeded)")
        }
        return parts.joined(separator: " ")
    }

    private static func formatBool(_ value: Bool?) -> String {
        value.map(String.init(describing:)) ?? "nil"
    }

    private static func compactRotor(_ search: RotorResult) -> String {
        var text = "rotor \(search.direction.rawValue): \(search.rotor)"
        if let foundElement = search.foundElement {
            let description = foundElement.semantics.assertable.label
                ?? foundElement.semantics.spokenDescription
            text += "\n  found=\(description)"
        }
        if let range = search.textRange {
            text += "\n  textRange=\(range.rangeDescription)"
            if let rangeText = range.text {
                text += " \"\(rangeText)\""
            }
        }
        return text
    }

    private static func compactActionFailure(_ projection: ActionProjection) -> String {
        guard let failure = projection.failure else {
            return "\(projection.method): ok"
        }
        var text = diagnosticText(failure, headline: "\(projection.method): error")
        if let screenId = projection.screenId {
            text = "\(screenId) | \(text)"
        }
        return text
    }

}
