#if canImport(UIKit)
#if DEBUG
import UIKit
import TheScore
import ThePlans

/// Drives UIKit and reads UIKit's own state back.
///
/// The tripwire is the only source of time, and this type holds the only waiver:
/// wall-clock waits are correct here and nowhere else. Input has to be
/// synthesized at real timestamps, because UIKit derives gesture velocity and
/// key repeat from them, and display-linking would make input speed depend on
/// the refresh rate. State like the keyboard's is UIKit's own answer rather than
/// part of the interface we observe, so no tick ever means "the keyboard
/// arrived" and asking again after a wait is the only way to hear it change.
@MainActor
final class TheSafecracker {

    private let keyboardInput: SafecrackerKeyboardInput
    private let fingerprints: TheFingerprints
    private let touchInjection: SafecrackerTouchInjection

    init(
        fingerprintsEnabled: Bool = true,
        keyboardInput: SafecrackerKeyboardInput = SafecrackerKeyboardInput()
    ) {
        let fingerprints = TheFingerprints(isEnabled: fingerprintsEnabled)
        self.keyboardInput = keyboardInput
        self.fingerprints = fingerprints
        self.touchInjection = SafecrackerTouchInjection(fingerprints: fingerprints)
    }

    func startKeyboardObservation() {
        keyboardInput.startObservation()
    }

    func stopKeyboardObservation() {
        keyboardInput.stopObservation()
    }

    var isKeyboardVisible: Bool {
        keyboardInput.isKeyboardVisible
    }

    var hasActiveTextInput: Bool {
        keyboardInput.hasActiveTextInput
    }

    func waitForActiveTextInput() async -> Bool {
        if hasActiveTextInput { return true }
        for _ in 0..<Self.keyboardPollMaxAttempts {
            guard await Task.cancellableSleep(for: Self.keyboardPollInterval) else { return false }
            if hasActiveTextInput { return true }
        }
        return false
    }

    func typeText(
        _ text: String,
        interKeyDelay: UInt64 = TheSafecracker.defaultInterKeyDelay
    ) async -> KeyboardTextInjectionOutcome {
        await keyboardInput.typeText(text, interKeyDelay: interKeyDelay)
    }

    func clearText(
        existingValue: String?,
        interKeyDelay: UInt64 = TheSafecracker.defaultInterKeyDelay
    ) async -> KeyboardTextInjectionOutcome {
        await keyboardInput.clearText(existingValue: existingValue, interKeyDelay: interKeyDelay)
    }

    func performEditAction(_ action: EditAction, on object: NSObject) -> Bool {
        UIApplication.shared.sendAction(action.selector, to: object, from: nil, for: nil)
    }

    /// Resign first responder, dismissing the keyboard if visible.
    /// Routes through the responder chain — no view hierarchy walk needed.
    func dismissKeyboard() -> Bool {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Focus a responder directly when accessibility activation declines.
    ///
    /// Heists try `accessibilityActivate()` first to mirror a VoiceOver
    /// double-tap. Some text fields return `false` even though they can become
    /// first responder, so this fallback calls `becomeFirstResponder()`.
    func focusFirstResponder(_ object: NSObject) -> Bool {
        guard let responder = object as? UIResponder,
              responder.canBecomeFirstResponder else { return false }
        return responder.becomeFirstResponder()
    }

    func dismissKeyboard(_ object: NSObject) -> Bool {
        guard let responder = object as? UIResponder else { return false }
        return responder.resignFirstResponder()
    }

    func showFingerprint(at point: CGPoint) {
        guard GeometryValidation.validateScreenPoint(point) == nil else { return }
        fingerprints.show(at: point)
    }

    func tap(at point: CGPoint) async -> Bool {
        await touchInjection.tap(at: point)
    }

    func longPress(
        at point: CGPoint,
        duration: GestureDuration = .longPressDefault
    ) async -> Bool {
        await touchInjection.longPress(at: point, duration: duration)
    }

    func swipe(
        from start: CGPoint,
        to end: CGPoint,
        duration: GestureDuration = .swipeDefault
    ) async -> Bool {
        await touchInjection.swipe(from: start, to: end, duration: duration)
    }

    func drag(
        from start: CGPoint,
        to end: CGPoint,
        duration: GestureDuration = .dragDefault
    ) async -> Bool {
        await touchInjection.drag(from: start, to: end, duration: duration)
    }
}

private extension EditAction {
    var selector: Selector {
        switch self {
        case .copy: #selector(UIResponderStandardEditActions.copy(_:))
        case .paste: #selector(UIResponderStandardEditActions.paste(_:))
        case .cut: #selector(UIResponderStandardEditActions.cut(_:))
        case .select: #selector(UIResponderStandardEditActions.select(_:))
        case .selectAll: #selector(UIResponderStandardEditActions.selectAll(_:))
        case .delete: #selector(UIResponderStandardEditActions.delete(_:))
        }
    }
}

nonisolated extension TheSafecracker {

    static let defaultInterKeyDelay: UInt64 = 30_000_000

    static let gestureYieldDelay: Duration = .milliseconds(50)

    static let touchGestureStepDelay: TimeInterval = 0.01

    static let keyboardPollInterval: Duration = .milliseconds(100)

    static let keyboardPollMaxAttempts: Int = 20
}

#endif // DEBUG
#endif // canImport(UIKit)
