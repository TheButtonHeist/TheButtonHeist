#if canImport(UIKit)
#if DEBUG

import TheScore

enum FailureEvidencePolicy: String, Equatable, Sendable {
    case hierarchy
    case screenshot
    case accessibilitySnapshot

    var captureMode: ScreenCaptureMode? {
        switch self {
        case .hierarchy: nil
        case .screenshot: .raw
        case .accessibilitySnapshot: .accessibility
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
