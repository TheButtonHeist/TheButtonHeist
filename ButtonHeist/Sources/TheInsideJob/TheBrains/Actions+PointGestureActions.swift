#if canImport(UIKit)
#if DEBUG
import UIKit

import TheScore
import ThePlans

extension Actions {

    func performPointAction(
        selection: ResolvedGesturePointSelection,
        payload: ActionResult.Payload,
        deadline: SemanticObservationDeadline,
        dispatch: (CGPoint) async -> Bool
    ) async -> TheSafecracker.ActionDispatchResult {
        switch await resolveGesturePoint(
            selection: selection,
            payload: payload,
            deadline: deadline
        ) {
        case .failure(let result):
            return result
        case .success(let resolvedPoint):
            switch admitGesturePoint(for: resolvedPoint, payload: payload) {
            case .failure(let result):
                return result
            case .success(let point):
                let success = await dispatch(point)
                return gestureDispatchResult(
                    payload: payload,
                    diagnosticPoint: point,
                    success: success
                ).withSubjectEvidence(resolvedPoint.subjectEvidence)
            }
        }
    }

    func executeTap(
        _ target: ResolvedTapTarget,
        deadline: SemanticObservationDeadline
    ) async -> TheSafecracker.ActionDispatchResult {
        return await performPointAction(
            selection: target.selection,
            payload: .oneFingerTap,
            deadline: deadline,
            dispatch: safecracker.tap
        )
    }

    func executeLongPress(
        _ target: ResolvedLongPressTarget,
        deadline: SemanticObservationDeadline
    ) async -> TheSafecracker.ActionDispatchResult {
        return await performPointAction(
            selection: target.selection,
            payload: .longPress,
            deadline: deadline,
            dispatch: { point in
                await self.safecracker.longPress(at: point, duration: target.duration)
            }
        )
    }

    func executeSwipe(
        _ request: ResolvedSwipeTarget,
        deadline: SemanticObservationDeadline
    ) async -> TheSafecracker.ActionDispatchResult {
        let duration = request.duration ?? SwipeTarget.defaultDuration
        switch request.selection {
        case .unitElement(let target, let start, let end):
            return await performElementFrameSwipe(
                target: target,
                start: start,
                end: end,
                duration: duration,
                deadline: deadline
            )
        case .elementDirection(let target, let direction):
            return await performElementFrameSwipe(
                target: target,
                start: direction.defaultStart,
                end: direction.defaultEnd,
                duration: duration,
                deadline: deadline
            )
        case .pointToPoint(let start, let end):
            return await performPointSwipe(start: start, duration: duration) { _ in end.cgPoint }
        case .pointDirection(let start, let direction):
            return await performPointSwipe(start: start, duration: duration) { startPoint in
                self.swipeEndPoint(from: startPoint, direction: direction)
            }
        }
    }

    private func performPointSwipe(
        start: ScreenPoint,
        duration: GestureDuration,
        resolveEndPoint: (CGPoint) -> CGPoint
    ) async -> TheSafecracker.ActionDispatchResult {
        switch resolveGesturePoint(
            from: nil,
            selection: .coordinate(start),
            payload: .swipe
        ) {
        case .failure(let result):
            return result
        case .success(let resolvedPoint):
            switch admitGesturePoint(for: resolvedPoint, payload: .swipe) {
            case .failure(let result):
                return result
            case .success(let startPoint):
                let endPoint = resolveEndPoint(startPoint)
                if let failure = geometryFailure(
                    payload: .swipe,
                    field: "swipe point",
                    points: [startPoint, endPoint]
                ) {
                    return failure
                }
                let success = await safecracker.swipe(
                    from: startPoint,
                    to: endPoint,
                    duration: duration
                )
                return gestureDispatchResult(
                    payload: .swipe,
                    diagnosticPoint: startPoint,
                    success: success
                ).withSubjectEvidence(resolvedPoint.subjectEvidence)
            }
        }
    }

    private func performElementFrameSwipe(
        target: ResolvedAccessibilityTarget,
        start: UnitPoint,
        end: UnitPoint,
        duration: GestureDuration,
        deadline: SemanticObservationDeadline
    ) async -> TheSafecracker.ActionDispatchResult {
        let inflatedTarget: ElementInflation.InflatedElementTarget
        switch await navigation.elementInflation.inflate(
            for: target,
            method: .swipe,
            deadline: deadline
        ) {
        case .inflated(let target):
            inflatedTarget = target
        case .failed(let failure):
            return failure.actionDispatchResult(payload: .swipe)
        }
        let preparation = vault.dispatchOnFreshLiveActionTarget(
            inflatedTarget.liveTarget,
        ) { liveTarget in
            let frame = liveTarget.frame
            if let message = GeometryValidation.validateRect(frame, field: "frame") {
                return GestureResolution<(CGPoint, CGPoint)>.failure(.failure(
                        .swipe,
                        message: "swipe failed: \(message)",
                        failureKind: .validationError
                    ))
            }
            let startPoint = CGPoint(
                x: frame.origin.x + start.x * frame.width,
                y: frame.origin.y + start.y * frame.height
            )
            let endPoint = CGPoint(
                x: frame.origin.x + end.x * frame.width,
                y: frame.origin.y + end.y * frame.height
            )
            if let failure = self.geometryFailure(
                payload: .swipe,
                field: "swipe point",
                points: [startPoint, endPoint]
            ) {
                return .failure(failure)
            }
            return .success((startPoint, endPoint))
        }
        switch preparation {
        case .failure(let staleness):
            return staleLiveTargetFailure(staleness, payload: .swipe)
        case .success(.failure(let result)):
            return result
        case .success(.success(let points)):
            let success = await safecracker.swipe(
                from: points.0,
                to: points.1,
                duration: duration
            )
            return gestureDispatchResult(
                payload: .swipe,
                diagnosticPoint: points.0,
                success: success
            ).withSubjectEvidence(inflatedTarget.subjectEvidence(source: .elementGestureTarget))
        }
    }

    func executeDrag(
        _ target: ResolvedDragTarget,
        deadline: SemanticObservationDeadline
    ) async -> TheSafecracker.ActionDispatchResult {
        let selection: ResolvedGesturePointSelection
        let end: ScreenPoint
        switch target.selection {
        case .elementToPoint(let target, let start, let endPoint):
            if let start {
                selection = .elementUnitPoint(target, start)
            } else {
                selection = .element(target)
            }
            end = endPoint
        case .pointToPoint(let startPoint, let endPoint):
            selection = .coordinate(startPoint)
            end = endPoint
        }
        let endPoint = end.cgPoint
        if let failure = geometryFailure(payload: .drag, field: "endPoint", point: endPoint) {
            return failure
        }
        return await performPointAction(
            selection: selection,
            payload: .drag,
            deadline: deadline,
            dispatch: { startPoint in
                await self.safecracker.drag(
                    from: startPoint,
                    to: endPoint,
                    duration: target.duration ?? DragTarget.defaultDuration
                )
            }
        )
    }

    private func swipeEndPoint(
        from startPoint: CGPoint,
        direction: SwipeDirection
    ) -> CGPoint {
        let distance = Self.defaultSwipeDistance
        switch direction {
        case .up: return CGPoint(x: startPoint.x, y: startPoint.y - distance)
        case .down: return CGPoint(x: startPoint.x, y: startPoint.y + distance)
        case .left: return CGPoint(x: startPoint.x - distance, y: startPoint.y)
        case .right: return CGPoint(x: startPoint.x + distance, y: startPoint.y)
        }
    }

    private func gestureDispatchResult(
        payload: ActionResult.Payload,
        diagnosticPoint: CGPoint,
        success: Bool
    ) -> TheSafecracker.ActionDispatchResult {
        guard !success else {
            return .success(payload: payload)
        }
        return .failure(
            payload,
            message: ActionCapabilityDiagnostic.gestureDispatchFailed(
                method: payload.method,
                point: diagnosticPoint,
                receiver: safecracker.tapReceiverDiagnostic(at: diagnosticPoint)
            )
        )
    }

}

#endif // DEBUG
#endif // canImport(UIKit)
