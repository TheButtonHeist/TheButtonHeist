#if canImport(UIKit)
import UIKit
@testable import AccessibilitySnapshotParser
import ThePlans
@testable import TheInsideJob
@testable import TheScore

/// Shared `AccessibilityElement` construction helpers for tests.
///
/// Subsumes the per-file `makeElement` / `element` / `dummyElement` helpers
/// that used to live in every test file. Defaults match the most common
/// fixture shape — empty description, no traits, zero frame, default
/// activation point, `respondsToUserInteraction: true` — and individual
/// parameters can be overridden as needed.
///
/// Use `.make(label:traits:...)` for the common case and
/// `.make(label:heistTraits:...)` when traits should be expressed as
/// `[HeistTrait]` (mapped through TheInsideJob's UIKit bridge).
extension AccessibilityElement {
    typealias Shape = AccessibilityShape

    static func make(
        description: String? = nil,
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        hint: String? = nil,
        traits: UIAccessibilityTraits = .none,
        shape: Shape = .frame(.zero),
        activationPoint: CGPoint? = nil,
        usesDefaultActivationPoint: Bool? = nil,
        customActions: [CustomAction] = [],
        customContent: [CustomContent] = [],
        customRotors: [CustomRotor] = [],
        respondsToUserInteraction: Bool = true,
        visibility: AccessibilityVisibility = .onscreen
    ) -> AccessibilityElement {
        let hasExplicitActivationPoint = activationPoint != nil
        let resolvedActivationPoint = activationPoint ?? shape.defaultActivationPoint
        return AccessibilityElement(
            description: description ?? label ?? "",
            label: label,
            value: value,
            traits: AccessibilityTraits(traits),
            identifier: identifier,
            hint: hint,
            userInputLabels: nil,
            shape: shape,
            activationPoint: AccessibilityPoint(resolvedActivationPoint),
            usesDefaultActivationPoint: usesDefaultActivationPoint ?? !hasExplicitActivationPoint,
            customActions: customActions,
            customContent: customContent,
            customRotors: customRotors,
            accessibilityLanguage: nil,
            respondsToUserInteraction: respondsToUserInteraction,
            visibility: visibility
        )
    }

    /// Convenience that takes `[HeistTrait]` and maps via TheInsideJob's
    /// UIKit bridge. Useful in trait-policy and id-assignment tests that drive
    /// traits from the wire enum.
    static func make(
        description: String? = nil,
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        heistTraits: [HeistTrait],
        shape: Shape = .frame(.zero),
        activationPoint: CGPoint? = nil,
        usesDefaultActivationPoint: Bool? = nil,
        customActions: [CustomAction] = [],
        customContent: [CustomContent] = [],
        customRotors: [CustomRotor] = [],
        respondsToUserInteraction: Bool = true
    ) -> AccessibilityElement {
        make(
            description: description,
            label: label,
            value: value,
            identifier: identifier,
            traits: UIAccessibilityTraits.fromNames(heistTraits.map(\.rawValue)),
            shape: shape,
            activationPoint: activationPoint,
            usesDefaultActivationPoint: usesDefaultActivationPoint,
            customActions: customActions,
            customContent: customContent,
            customRotors: customRotors,
            respondsToUserInteraction: respondsToUserInteraction
        )
    }

    /// Convenience for the common pattern of building an element with a
    /// frame and an activation point at the frame's center.
    static func make(
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        traits: UIAccessibilityTraits = .none,
        frame: CGRect,
        respondsToUserInteraction: Bool = true
    ) -> AccessibilityElement {
        make(
            label: label,
            value: value,
            identifier: identifier,
            traits: traits,
            shape: .frame(AccessibilityRect(frame)),
            activationPoint: CGPoint(x: frame.midX, y: frame.midY),
            respondsToUserInteraction: respondsToUserInteraction
        )
    }
}

private extension AccessibilityShape {
    var defaultActivationPoint: CGPoint {
        switch self {
        case .frame(let rect):
            return CGPoint(x: rect.origin.x + rect.size.width / 2, y: rect.origin.y + rect.size.height / 2)
        case .path(let elements):
            let path = CGMutablePath()
            for element in elements {
                switch element {
                case .move(let point):
                    path.move(to: point.cgPoint)
                case .line(let point):
                    path.addLine(to: point.cgPoint)
                case .quadCurve(let point, let control):
                    path.addQuadCurve(to: point.cgPoint, control: control.cgPoint)
                case .curve(let point, let control1, let control2):
                    path.addCurve(to: point.cgPoint, control1: control1.cgPoint, control2: control2.cgPoint)
                case .closeSubpath:
                    path.closeSubpath()
                }
            }
            let bounds = path.boundingBoxOfPath
            guard !bounds.isNull else { return .zero }
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}

#endif
