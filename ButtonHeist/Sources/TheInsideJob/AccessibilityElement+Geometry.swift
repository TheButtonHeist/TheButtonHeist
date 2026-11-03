#if canImport(UIKit)
#if DEBUG
import AccessibilitySnapshotParser
import CoreGraphics
import TheScore

extension AccessibilityElement {
    var bhFrame: CGRect {
        shape.frame
    }

    var bhResolvedActivationPoint: CGPoint {
        let frame = bhFrame
        if usesDefaultActivationPoint {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        return activationPoint.cgPoint
    }

    /// Replace a non-finite activation point with the midpoint of the element's shape.
    ///
    /// UIKit can report a NaN or infinite `accessibilityActivationPoint` (a SwiftUI `Menu` on
    /// iOS 27 does) while the shape the parser reports is finite. The midpoint is where UIKit's
    /// default activation point puts a tap, so the element is marked as using the default.
    /// An element whose shape has no admissible bounds either is returned unchanged: there is
    /// no geometry to derive a point from, and `InterfaceGeometryAdmission` rejects it.
    func normalizingNonFiniteActivationPoint() -> AccessibilityElement {
        guard !activationPoint.isFinite,
              let bounds = ScreenFrameEvidence(shape).rect
        else { return self }
        return AccessibilityElement(
            description: description,
            label: label,
            value: value,
            traits: traits,
            identifier: identifier,
            hint: hint,
            userInputLabels: userInputLabels,
            shape: shape,
            activationPoint: AccessibilityPoint(x: bounds.midX, y: bounds.midY),
            usesDefaultActivationPoint: true,
            customActions: customActions,
            customContent: customContent,
            customRotors: customRotors,
            accessibilityLanguage: accessibilityLanguage,
            respondsToUserInteraction: respondsToUserInteraction,
            visibility: visibility
        )
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
