#if canImport(UIKit)
#if DEBUG
import UIKit
import ButtonHeistSupport
import TheScore
import ThePlans

@MainActor
final class SafecrackerTouchInjection {

    fileprivate struct ActiveTouch {
        var touch: TheSafecracker.SyntheticTouch
        let window: UIWindow
    }

    fileprivate enum Completion {
        case tap
        case stationary(GestureDuration)
        case path([CGPoint])
    }

    private let fingerprints: TheFingerprints
    private let touchEnded: @MainActor () -> Void

    init(fingerprints: TheFingerprints, touchEnded: @escaping @MainActor () -> Void) {
        self.fingerprints = fingerprints
        self.touchEnded = touchEnded
    }

    func tap(at point: CGPoint) async -> Bool {
        await perform(at: point, field: "tap point", completion: .tap)
    }

    func longPress(
        at point: CGPoint,
        duration: GestureDuration = .longPressDefault
    ) async -> Bool {
        await perform(at: point, field: "long press point", completion: .stationary(duration))
    }

    func swipe(
        from start: CGPoint,
        to end: CGPoint,
        duration: GestureDuration = .swipeDefault
    ) async -> Bool {
        await performLineGesture(
            from: start,
            to: end,
            duration: duration,
            minimumSteps: 3,
            field: "swipe point"
        )
    }

    func drag(
        from start: CGPoint,
        to end: CGPoint,
        duration: GestureDuration = .dragDefault
    ) async -> Bool {
        await performLineGesture(
            from: start,
            to: end,
            duration: duration,
            minimumSteps: 5,
            field: "drag point"
        )
    }

    private func perform(at point: CGPoint, field: String, completion: Completion) async -> Bool {
        guard Self.geometryIsValid([point], field: field),
              !Task.isCancelled,
              var touchState = beginTouch(at: point) else { return false }

        switch completion {
        case .tap:
            guard await Task.cancellableSleep(for: TheSafecracker.gestureYieldDelay) else {
                _ = terminate(&touchState.touch, phase: .cancelled)
                return false
            }
        case .stationary(let duration):
            var elapsed: TimeInterval = 0
            while elapsed < duration.seconds {
                guard !Task.isCancelled else {
                    _ = terminate(&touchState.touch, phase: .cancelled)
                    return false
                }
                guard await Task.cancellableSleep(
                    nanoseconds: UInt64(TheSafecracker.touchGestureStepDelay * 1_000_000_000)
                ) else {
                    _ = terminate(&touchState.touch, phase: .cancelled)
                    return false
                }
                elapsed += TheSafecracker.touchGestureStepDelay
                guard sendStationary(&touchState.touch) else {
                    _ = terminate(&touchState.touch, phase: .cancelled)
                    return false
                }
            }
        case .path(let waypoints):
            for point in waypoints {
                guard !Task.isCancelled,
                      moveTouch(&touchState.touch, in: touchState.window, to: point) else {
                    _ = terminate(&touchState.touch, phase: .cancelled)
                    return false
                }
                guard await Task.cancellableSleep(
                    nanoseconds: UInt64(TheSafecracker.touchGestureStepDelay * 1_000_000_000)
                ) else {
                    _ = terminate(&touchState.touch, phase: .cancelled)
                    return false
                }
            }
        }
        guard !Task.isCancelled else {
            _ = terminate(&touchState.touch, phase: .cancelled)
            return false
        }
        return terminate(&touchState.touch, phase: .ended)
    }

    private func performLineGesture(
        from start: CGPoint,
        to end: CGPoint,
        duration: GestureDuration,
        minimumSteps: Int,
        field: String
    ) async -> Bool {
        guard Self.geometryIsValid([start, end], field: field) else { return false }
        let steps = max(Int(duration.seconds / TheSafecracker.touchGestureStepDelay), minimumSteps)
        return await perform(
            at: start,
            field: field,
            completion: .path(Self.linearPath(from: start, to: end, steps: steps))
        )
    }

    private func beginTouch(at point: CGPoint) -> ActiveTouch? {
        guard Self.geometryIsValid([point], field: "touch point") else { return nil }
        guard let window = windowForPoint(point) else {
            insideJobLogger.error("No window found for point \(String(describing: point))")
            return nil
        }

        let target = TheSafecracker.TouchTarget.resolve(at: point, in: window)
        guard let touch = target.makeTouch(phase: .began) else {
            insideJobLogger.error("Failed to create touch")
            return nil
        }

        guard TheSafecracker.TouchEvent.dispatch(touches: [touch]) else {
            insideJobLogger.error("Failed to create began event")
            return nil
        }

        fingerprints.beginTracking(at: [point])
        return ActiveTouch(touch: touch, window: window)
    }

    @discardableResult
    private func moveTouch(_ touch: inout TheSafecracker.SyntheticTouch, in window: UIWindow, to point: CGPoint) -> Bool {
        guard Self.geometryIsValid([point], field: "touch move point") else { return false }

        let windowPoint = window.convert(point, from: nil)
        touch.update(phase: .moved, location: windowPoint)

        guard TheSafecracker.TouchEvent.dispatch(touches: [touch]) else { return false }
        fingerprints.updateTracking(to: [point])
        return true
    }

    @discardableResult
    private func sendStationary(_ touch: inout TheSafecracker.SyntheticTouch) -> Bool {
        touch.update(phase: .stationary)

        return TheSafecracker.TouchEvent.dispatch(touches: [touch])
    }

    private func terminate(
        _ touch: inout TheSafecracker.SyntheticTouch,
        phase: UITouch.Phase
    ) -> Bool {
        defer { fingerprints.endTracking() }
        touch.update(phase: phase)

        guard TheSafecracker.TouchEvent.dispatch(touches: [touch]) else {
            insideJobLogger.error("Failed to create terminal touch event")
            return false
        }

        if phase == .ended {
            touchEnded()
        }
        return true
    }

    static func geometryIsValid(_ points: [CGPoint], field: String) -> Bool {
        if let reason = GeometryValidation.validateScreenPoints(points, field: field) {
            insideJobLogger.error("Rejected synthetic touch geometry: \(reason, privacy: .public)")
            return false
        }
        return true
    }

    static func linearPath(from start: CGPoint, to end: CGPoint, steps: Int) -> [CGPoint] {
        (1...steps).map { step in
            let progress = Double(step) / Double(steps)
            return CGPoint(
                x: start.x + progress * (end.x - start.x),
                y: start.y + progress * (end.y - start.y)
            )
        }
    }

    private func windowForPoint(_ point: CGPoint) -> UIWindow? {
        guard GeometryValidation.validateScreenPoint(point) == nil else { return nil }
        for window in TheTripwire.orderedVisibleWindows() {
            let windowPoint = window.convert(point, from: nil)
            if window.hitTest(windowPoint, with: nil) != nil {
                return window
            }
        }
        return nil
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
