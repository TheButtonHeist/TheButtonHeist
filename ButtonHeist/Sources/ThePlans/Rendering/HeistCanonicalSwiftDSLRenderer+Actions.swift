import Foundation

extension HeistCanonicalSwiftDSLRenderer {
    func render(
        action: ActionStep,
        indent: Int,
        environment: RenderEnvironment
    ) throws -> String {
        var text = try line(render(command: action.command, environment: environment), indent)
        if let expectation = action.expectationPolicy.expectedExpectation {
            let predicate = try render(predicate: expectation.predicate, environment: environment)
            let timeout = renderExpectationTimeout(expectation.timeout)
            text += "\n" + line(".expect(\(predicate)\(timeout))", indent + 1)
        }
        if let waiver = action.expectationPolicy.waiver?.reason {
            text += "\n" + line(".withoutExpectation(\(quote(waiver)))", indent + 1)
        }
        return text
    }

    func renderExpectationTimeout(_ timeout: ActionExpectation.Timeout) -> String {
        switch timeout {
        case .sessionDefault:
            return ""
        case .explicit(let timeout):
            return ", timeout: \(decimal(timeout.seconds))"
        }
    }

    func render(
        command: HeistActionCommand,
        environment: RenderEnvironment
    ) throws -> String {
        if let failure = command.durableHeistActionFailure {
            throw HeistCanonicalSwiftDSLError.unsupportedAction(failure)
        }
        switch command {
        case .activate(let target):
            return "Activate(\(try render(target: target, environment: environment)))"
        case .increment(let target):
            return "Increment(\(try render(target: target, environment: environment)))"
        case .decrement(let target):
            return "Decrement(\(try render(target: target, environment: environment)))"
        case .customAction(let name, let target):
            return "CustomAction(\(quote(name.rawValue)), on: \(try render(target: target, environment: environment)))"
        case .rotor(let selection, let target, let direction):
            guard case .named(let name) = selection else {
                throw HeistCanonicalSwiftDSLError.unsupportedAction(command.durableHeistActionFailure ?? "rotor selection \(selection)")
            }
            return "Rotor(\(quote(name.rawValue)), on: \(try render(target: target, environment: environment)), direction: .\(direction.rawValue))"
        case .typeText(let payload):
            return try render(typeText: payload, environment: environment)
        case .oneFingerTap(let target):
            return try renderOneFingerTap(target, environment: environment)
        case .longPress(let target):
            return try renderLongPress(target, environment: environment)
        case .swipe(let target):
            return try renderSwipe(target, environment: environment)
        case .drag(let target):
            return try renderDrag(target, environment: environment)
        case .scroll, .scrollToVisible, .scrollToEdge:
            throw HeistCanonicalSwiftDSLError.unsupportedAction(
                command.durableHeistActionFailure ?? "direct client command is not a durable heist action"
            )
        case .editAction(let target):
            return "Edit(.\(target.action.rawValue))"
        case .setPasteboard(let target):
            return "SetPasteboard(\(quote(target.text.rawText)))"
        case .takeScreenshot:
            return "TakeScreenshot()"
        case .dismiss:
            return "ScreenActions.Dismiss()"
        case .magicTap:
            return "ScreenActions.MagicTap()"
        case .dismissKeyboard:
            return "dismissKeyboard()"
        }
    }

    private func render(
        typeText payload: TypeTextTarget,
        environment: RenderEnvironment
    ) throws -> String {
        let source: String
        let modeSuffix: String
        switch payload.source {
        case .text(let text):
            if text.mode == .replace, text.rawText.isEmpty, let target = payload.target {
                return "ClearText(\(try render(target: target, environment: environment)))"
            }
            source = text.mode == .replace
                ? ".replacing(\(quote(text.rawText)))"
                : quote(text.rawText)
            modeSuffix = ""
        case .reference(let reference, let mode):
            source = try render(string: .ref(reference), environment: environment)
            modeSuffix = mode == .replace ? ", mode: .replace" : ""
        }
        let target = try payload.target.map {
            ", into: \(try render(target: $0, environment: environment))"
        } ?? ""
        return "TypeText(\(source)\(target)\(modeSuffix))"
    }

    func renderOneFingerTap(_ target: TapTarget, environment: RenderEnvironment) throws -> String {
        switch target.selection {
        case .element(let target):
            return "oneFingerTap(\(try render(target: target, environment: environment)))"
        case .elementUnitPoint(let target, let point):
            return "oneFingerTap(\(try render(target: target, environment: environment)), at: \(render(unitPoint: point)))"
        case .coordinate(let point):
            return "oneFingerTap(\(render(point: point)))"
        }
    }

    func renderLongPress(
        _ request: LongPressTarget,
        environment: RenderEnvironment
    ) throws -> String {
        switch request.selection {
        case .element(let target):
            if request.duration == .longPressDefault {
                return "longPress(\(try render(target: target, environment: environment)))"
            }
            return "longPress(\(try render(target: target, environment: environment)), duration: \(render(duration: request.duration)))"
        case .elementUnitPoint(let target, let point):
            if request.duration == .longPressDefault {
                return "longPress(\(try render(target: target, environment: environment)), at: \(render(unitPoint: point)))"
            }
            let target = try render(target: target, environment: environment)
            let point = render(unitPoint: point)
            return "longPress(\(target), at: \(point), duration: \(render(duration: request.duration)))"
        case .coordinate(let point):
            if request.duration == .longPressDefault {
                return "longPress(\(render(point: point)))"
            }
            return "longPress(\(render(point: point)), duration: \(render(duration: request.duration)))"
        }
    }

    func renderSwipe(_ request: SwipeTarget, environment: RenderEnvironment) throws -> String {
        let duration = renderDurationArgument(request.duration)
        switch request.selection {
        case .unitElement(let target, let start, let end):
            let target = try render(target: target, environment: environment)
            return "swipe(\(target), from: \(render(unitPoint: start)), to: \(render(unitPoint: end))\(duration))"
        case .elementDirection(let target, let direction):
            return "swipe(\(try render(target: target, environment: environment)), .\(direction.rawValue)\(duration))"
        case .pointToPoint(let start, let end):
            return "swipe(from: \(render(point: start)), to: \(render(point: end))\(duration))"
        case .pointDirection(let start, let direction):
            return "swipe(from: \(render(point: start)), .\(direction.rawValue)\(duration))"
        }
    }

    func renderDrag(_ request: DragTarget, environment: RenderEnvironment) throws -> String {
        let duration = renderDurationArgument(request.duration)
        switch request.selection {
        case .elementToPoint(let target, let start, let end):
            let target = try render(target: target, environment: environment)
            if let start {
                return "drag(\(target), from: \(render(unitPoint: start)), to: \(render(point: end))\(duration))"
            }
            return "drag(\(target), to: \(render(point: end))\(duration))"
        case .pointToPoint(let start, let end):
            return "drag(from: \(render(point: start)), to: \(render(point: end))\(duration))"
        }
    }

    /// An explicit swipe or drag duration renders even when it equals the
    /// default, so parsing the source restores the same optional payload.
    private func renderDurationArgument(_ duration: GestureDuration?) -> String {
        duration.map { ", duration: \(render(duration: $0))" } ?? ""
    }
}
