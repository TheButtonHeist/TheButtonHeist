#if canImport(UIKit) && DEBUG
import UIKit

import ThePlans
import TheScore

extension ElementInflation {

    internal enum ElementActionTargetResolutionFailure: Error, Equatable, CustomStringConvertible {
        case containerTarget

        internal var description: String {
            switch self {
            case .containerTarget:
                return "container targets are not valid for element actions"
            }
        }
    }

    internal enum ElementInflationFailureStep: String {
        case targetResolution
        case notFound
        case ambiguous
        case noRevealPath
        case staleRefresh
        case cancelled
        case timedOut
        case geometryNotActionable
    }

    internal struct ElementInflationFailure: Error {
        internal let failedStep: ElementInflationFailureStep
        internal let failureKind: ActionFailure.Kind
        internal let message: String
        internal let targetResolutionFailure: ElementActionTargetResolutionFailure?

        internal static func targetResolution(
            _ failure: ElementActionTargetResolutionFailure
        ) -> ElementInflationFailure {
            .init(
                .targetResolution,
                failureKind: .elementNotFound,
                message: failure.description,
                targetResolutionFailure: failure
            )
        }

        internal static func notFound(_ message: String) -> ElementInflationFailure {
            .init(.notFound, failureKind: .elementNotFound, message: message)
        }

        internal static func ambiguous(_ message: String) -> ElementInflationFailure {
            .init(.ambiguous, failureKind: .elementNotFound, message: message)
        }

        internal static func noRevealPath(_ message: String) -> ElementInflationFailure {
            .init(.noRevealPath, failureKind: .actionFailed, message: message)
        }

        internal static func staleRefresh(
            _ message: String,
            failureKind: ActionFailure.Kind = .actionFailed
        ) -> ElementInflationFailure {
            .init(.staleRefresh, failureKind: failureKind, message: message)
        }

        internal static func cancelled(_ message: String) -> ElementInflationFailure {
            .init(.cancelled, failureKind: .actionFailed, message: message)
        }

        internal static func timedOut(_ message: String) -> ElementInflationFailure {
            .init(.timedOut, failureKind: .timeout, message: message)
        }

        internal static func geometryNotActionable(
            _ message: String,
            failureKind: ActionFailure.Kind = .actionFailed
        ) -> ElementInflationFailure {
            .init(.geometryNotActionable, failureKind: failureKind, message: message)
        }

        internal func actionDispatchResult(payload: ActionResult.Payload) -> TheSafecracker.ActionDispatchResult {
            .failure(payload, message: message, failureKind: failureKind)
        }

        private init(
            _ step: ElementInflationFailureStep,
            failureKind: ActionFailure.Kind,
            message: String,
            targetResolutionFailure: ElementActionTargetResolutionFailure? = nil
        ) {
            failedStep = step
            self.failureKind = failureKind
            self.targetResolutionFailure = targetResolutionFailure
            self.message = message.contains("[\(step.rawValue)]")
                ? message
                : "element inflation failed [\(step.rawValue)]: \(message)"
        }
    }

    internal func staleRefreshFailure(reason: RetryReason) -> ElementInflationFailure {
        .staleRefresh(
            "target refresh reached the action deadline after \(reason.failureDescription)",
            failureKind: .elementNotFound
        )
    }

    internal func noScrollViewFailure(
        for liveTarget: TheVault.LiveActionTarget,
        description: String,
        method: ActionMethod
    ) -> ElementInflationFailure {
        if ScreenMetrics.current.bounds.intersects(liveTarget.frame) {
            return .geometryNotActionable(
                "target \(description) has an activation point outside the screen; "
                    + Self.liveGeometrySummary(liveTarget)
            )
        }
        return .noRevealPath(
            "target \(description) has no live scrollable ancestor to make activation point actionable; "
                + Self.liveGeometrySummary(liveTarget)
        )
    }
}

extension ResolvedAccessibilityTarget {
    internal func validatedForElementAction() throws(
        ElementInflation.ElementActionTargetResolutionFailure
    ) -> ResolvedAccessibilityTarget {
        switch self {
        case .predicate:
            return self
        case .container:
            throw .containerTarget
        case .within(_, let target):
            _ = try target.validatedForElementAction()
            return self
        }
    }
}

#endif // canImport(UIKit) && DEBUG
