#if canImport(UIKit)
#if DEBUG
import UIKit

import TheScore

extension TheBrains {
    enum ScreenCaptureFailure: Error, Equatable, Sendable {
        case inactiveRuntime
        case accessibilityTreeUnavailable
        case appWindowUnavailable
        case accessibilitySnapshotRenderingFailed
        case pngEncodingFailed
        case invalidScreenDimensions

        var message: String {
            switch self {
            case .inactiveRuntime:
                return TheBrains.runtimeInactiveMessage
            case .accessibilityTreeUnavailable:
                return "Could not access accessibility tree"
            case .appWindowUnavailable:
                return "Could not access app window"
            case .accessibilitySnapshotRenderingFailed:
                return "Failed to render accessibility snapshot"
            case .pngEncodingFailed:
                return "Failed to encode screen as PNG"
            case .invalidScreenDimensions:
                return "Captured screen dimensions are invalid"
            }
        }

        var actionFailureKind: ActionFailure.Kind {
            switch self {
            case .inactiveRuntime, .accessibilityTreeUnavailable:
                return .accessibilityTreeUnavailable
            case .appWindowUnavailable, .accessibilitySnapshotRenderingFailed, .pngEncodingFailed,
                 .invalidScreenDimensions:
                return .actionFailed
            }
        }
    }

    func captureScreenPayload(
        mode: ScreenCaptureMode = .raw,
        observationBoundary: SemanticObservationWaitBoundary
    ) async -> Result<ScreenPayload, ScreenCaptureFailure> {
        guard semanticObservationIsActive else {
            return .failure(.inactiveRuntime)
        }
        guard let observation = await vault.semanticObservationStream
            .admittedVisibleObservation(boundary: observationBoundary) else {
            return .failure(.accessibilityTreeUnavailable)
        }
        let interface = observation.snapshot.interface

        guard let screenCapture = vault.captureScreen() else {
            return .failure(.appWindowUnavailable)
        }

        if mode == .accessibility {
            guard let payload = renderAccessibilitySnapshotPayload(
                image: screenCapture.image,
                bounds: screenCapture.bounds,
                interface: interface
            ) else {
                return .failure(.accessibilitySnapshotRenderingFailed)
            }
            return .success(payload)
        }

        guard let pngData = screenCapture.image.pngData() else {
            return .failure(.pngEncodingFailed)
        }

        guard let payload = ScreenPayload.admit(
            pngData: pngData.base64EncodedString(),
            width: screenCapture.bounds.width,
            height: screenCapture.bounds.height,
            interface: interface
        ) else {
            return .failure(.invalidScreenDimensions)
        }
        return .success(payload)
    }

    func dispatchTakeScreenshot(
        mode: ScreenCaptureMode = .raw,
        observationBoundary: SemanticObservationWaitBoundary
    ) async -> TheSafecracker.ActionDispatchResult {
        switch await captureScreenPayload(
            mode: mode,
            observationBoundary: observationBoundary
        ) {
        case .success(let payload):
            return .success(
                payload: .screenshot(payload),
                message: "Captured screenshot \(Int(payload.width))x\(Int(payload.height))"
            )
        case .failure(let failure):
            return .failure(
                .screenshot(nil),
                message: failure.message,
                failureKind: failure.actionFailureKind
            )
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
