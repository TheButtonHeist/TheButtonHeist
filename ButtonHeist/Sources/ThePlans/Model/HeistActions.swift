public struct Action {
    let command: HeistActionCommand
    let expectation: AuthoredActionExpectation

    init(
        command: HeistActionCommand,
        expectation: AuthoredActionExpectation = .default
    ) {
        self.command = command
        self.expectation = expectation
    }

    var heistContent: HeistContent {
        guard expectation.diagnostics.isEmpty else {
            return HeistContent(diagnostics: expectation.diagnostics.map {
                $0.withPath(command.wireType.rawValue)
            })
        }
        return HeistContent([.action(ActionStep(
            command: command,
            expectationPolicy: expectation.policy
        ))])
    }

    public func expect(
        _ predicate: AccessibilityPredicate,
        timeout: WaitTimeout? = nil
    ) -> Action {
        return Action(
            command: command,
            expectation: expectation.appending(predicate, timeout: timeout)
        )
    }

    public func withoutExpectation(_ waiver: ActionExpectationWaiver) -> Action {
        Action(
            command: command,
            expectation: .waived(waiver)
        )
    }

    public func until(
        _ predicate: AccessibilityPredicate,
        timeout: WaitTimeout = defaultWaitTimeout
    ) -> Repeated {
        repeated(until: predicate, timeout: timeout)
    }

    func repeated(
        until predicate: AccessibilityPredicate,
        timeout: WaitTimeout
    ) -> Repeated {
        Repeated(
            command: command,
            expectation: expectation,
            predicate: predicate,
            timeout: timeout
        )
    }

    public struct Repeated {
        let command: HeistActionCommand
        let expectation: AuthoredActionExpectation
        let predicate: AccessibilityPredicate
        let timeout: WaitTimeout

        var heistContent: HeistContent {
            guard expectation.diagnostics.isEmpty else {
                return HeistContent(diagnostics: expectation.diagnostics.map {
                    $0.withPath(command.wireType.rawValue)
                })
            }
            return HeistContent([.repeatUntil(RepeatUntilStep(
                predicate: predicate,
                timeout: timeout,
                firstBodyStep: .action(ActionStep(command: command, expectationPolicy: expectation.policy))
            ))])
        }
    }
}

enum AuthoredActionExpectation: Sendable, Equatable {
    case `default`
    case expect(
        ActionExpectation,
        diagnostics: [HeistBuildDiagnostic]
    )
    case waived(ActionExpectationWaiver)

    var diagnostics: [HeistBuildDiagnostic] {
        guard case .expect(_, let diagnostics) = self else { return [] }
        return diagnostics
    }

    var policy: ActionExpectationPolicy {
        switch self {
        case .default:
            return .default
        case .expect(let expectation, _):
            return .expect(expectation)
        case .waived(let waiver):
            return .waived(waiver)
        }
    }

    func appending(
        _ nextPredicate: AccessibilityPredicate,
        timeout nextExplicitTimeout: WaitTimeout?
    ) -> Self {
        guard case .expect(let existingExpectation, var diagnostics) = self else {
            return .expect(
                ActionExpectation(
                    predicate: nextPredicate,
                    timeout: nextExplicitTimeout
                ),
                diagnostics: []
            )
        }

        // An expectation holds one predicate, so two cannot be composed here.
        // They are siblings in authored order — a list — and that is a change
        // to `ActionExpectation`, not something to fake by folding one
        // predicate inside another.
        let predicate = existingExpectation.predicate
        diagnostics.append(.dslBuild(
            code: .dslInvalidActionExpectation,
            message: "unsupported expectation composition: \(predicate) + \(nextPredicate)",
            hint: "Use one predicate per expectation, or follow the action with a WaitFor."
        ))

        if case .explicit(let existingTimeout) = existingExpectation.timeout,
           let nextExplicitTimeout,
           existingTimeout != nextExplicitTimeout {
            diagnostics.append(.dslBuild(
                code: .dslInvalidActionExpectation,
                message: "multiple explicit expectation timeouts in one chain: \(existingTimeout) and \(nextExplicitTimeout)",
                hint: "Use one explicit timeout for the composed expectation."
            ))
        }

        let expectation: ActionExpectation
        if case .sessionDefault = existingExpectation.timeout,
           let nextExplicitTimeout {
            expectation = ActionExpectation(
                predicate: predicate,
                timeout: nextExplicitTimeout
            )
        } else {
            expectation = existingExpectation
        }

        return .expect(
            expectation,
            diagnostics: diagnostics
        )
    }
}

public func Activate(_ target: AccessibilityTarget) -> Action {
    Action(command: .activate(target))
}

public func Increment(_ target: AccessibilityTarget) -> Action {
    Action(command: .increment(target))
}

public func Decrement(_ target: AccessibilityTarget) -> Action {
    Action(command: .decrement(target))
}

public func TypeText(
    _ text: TextInputText,
    into target: AccessibilityTarget? = nil
) -> Action {
    Action(command: .typeText(
        text: text,
        target: target
    ))
}

@_disfavoredOverload
public func TypeText(
    _ reference: HeistReferenceName,
    into target: AccessibilityTarget? = nil,
    mode: TextInputText.Mode = .append
) -> Action {
    Action(command: .typeText(
        reference: reference,
        target: target,
        mode: mode
    ))
}

public func ClearText(_ target: AccessibilityTarget) -> Action {
    Action(command: .typeText(
        text: .replacing(""),
        target: target
    ))
}

public func CustomAction(_ name: CustomActionName, on target: AccessibilityTarget) -> Action {
    Action(command: .customAction(name: name, target: target))
}

public func Rotor(
    _ name: RotorName,
    on target: AccessibilityTarget,
    direction: RotorDirection = .next
) -> Action {
    Action(command: .rotor(selection: .named(name), target: target, direction: direction))
}

public func SetPasteboard(_ text: PasteboardText) -> Action {
    Action(command: .setPasteboard(SetPasteboardTarget(text: text)))
}

public func TakeScreenshot() -> Action {
    Action(command: .takeScreenshot)
}

public func Edit(_ editAction: EditAction) -> Action {
    Action(command: .editAction(EditActionTarget(action: editAction)))
}

public func dismissKeyboard() -> Action {
    Action(command: .dismissKeyboard)
}

public enum ScreenActions {
    public static func Dismiss() -> Action {
        Action(command: .dismiss)
    }

    public static func MagicTap() -> Action {
        Action(command: .magicTap)
    }
}

@_disfavoredOverload
public func oneFingerTap(_ target: AccessibilityTarget) -> Action {
    Action(command: .oneFingerTap(TapTarget(selection: .element(target))))
}

public func oneFingerTap(_ point: ScreenPoint) -> Action {
    Action(command: .oneFingerTap(TapTarget(selection: .coordinate(point))))
}

public func oneFingerTap(_ target: AccessibilityTarget, at point: UnitPoint) -> Action {
    Action(command: .oneFingerTap(TapTarget(selection: .elementUnitPoint(target, point))))
}

public func longPress(
    _ target: AccessibilityTarget,
    duration: GestureDuration = .longPressDefault
) -> Action {
    Action(command: .longPress(LongPressTarget(selection: .element(target), duration: duration)))
}

public func longPress(
    _ point: ScreenPoint,
    duration: GestureDuration = .longPressDefault
) -> Action {
    Action(command: .longPress(LongPressTarget(selection: .coordinate(point), duration: duration)))
}

public func longPress(
    _ target: AccessibilityTarget,
    at point: UnitPoint,
    duration: GestureDuration = .longPressDefault
) -> Action {
    Action(command: .longPress(LongPressTarget(selection: .elementUnitPoint(target, point), duration: duration)))
}

public func swipe(_ target: AccessibilityTarget, _ direction: SwipeDirection) -> Action {
    Action(command: .swipe(SwipeTarget(selection: .elementDirection(target, direction))))
}

public func swipe(
    _ target: AccessibilityTarget,
    _ direction: SwipeDirection,
    duration: GestureDuration
) -> Action {
    Action(command: .swipe(SwipeTarget(selection: .elementDirection(target, direction), duration: duration)))
}

public func swipe(
    _ target: AccessibilityTarget,
    from start: UnitPoint,
    to end: UnitPoint
) -> Action {
    Action(command: .swipe(SwipeTarget(selection: .unitElement(target, start: start, end: end))))
}

public func swipe(
    _ target: AccessibilityTarget,
    from start: UnitPoint,
    to end: UnitPoint,
    duration: GestureDuration
) -> Action {
    Action(command: .swipe(SwipeTarget(selection: .unitElement(target, start: start, end: end), duration: duration)))
}

public func swipe(from start: ScreenPoint, to end: ScreenPoint) -> Action {
    Action(command: .swipe(SwipeTarget(selection: .pointToPoint(start: start, end: end))))
}

public func swipe(from start: ScreenPoint, to end: ScreenPoint, duration: GestureDuration) -> Action {
    Action(command: .swipe(SwipeTarget(selection: .pointToPoint(start: start, end: end), duration: duration)))
}

public func swipe(from start: ScreenPoint, _ direction: SwipeDirection) -> Action {
    Action(command: .swipe(SwipeTarget(selection: .pointDirection(start: start, direction: direction))))
}

public func swipe(from start: ScreenPoint, _ direction: SwipeDirection, duration: GestureDuration) -> Action {
    Action(command: .swipe(SwipeTarget(selection: .pointDirection(start: start, direction: direction), duration: duration)))
}

public func drag(_ target: AccessibilityTarget, to end: ScreenPoint) -> Action {
    Action(command: .drag(DragTarget(start: .element(target), end: end)))
}

public func drag(_ target: AccessibilityTarget, to end: ScreenPoint, duration: GestureDuration) -> Action {
    Action(command: .drag(DragTarget(start: .element(target), end: end, duration: duration)))
}

public func drag(
    _ target: AccessibilityTarget,
    from start: UnitPoint,
    to end: ScreenPoint
) -> Action {
    Action(command: .drag(DragTarget(start: .elementUnitPoint(target, start), end: end)))
}

public func drag(
    _ target: AccessibilityTarget,
    from start: UnitPoint,
    to end: ScreenPoint,
    duration: GestureDuration
) -> Action {
    Action(command: .drag(DragTarget(start: .elementUnitPoint(target, start), end: end, duration: duration)))
}

public func drag(from start: ScreenPoint, to end: ScreenPoint) -> Action {
    Action(command: .drag(DragTarget(start: .coordinate(start), end: end)))
}

public func drag(from start: ScreenPoint, to end: ScreenPoint, duration: GestureDuration) -> Action {
    Action(command: .drag(DragTarget(start: .coordinate(start), end: end, duration: duration)))
}
