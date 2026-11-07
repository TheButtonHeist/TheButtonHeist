import Foundation

extension HeistPlanSourceParser {
    mutating func parseElementTargetAction(
        _ actionName: String,
        makeCommand: (AccessibilityTarget) -> HeistActionCommand
    ) throws -> HeistActionCommand {
        try expectSymbol("(")
        let target = try parseTargetExpr()
        try rejectActionLevelOrdinalIfPresent(actionName: actionName, target: target)
        try expectSymbol(")")
        return makeCommand(target)
    }

    mutating func rejectActionLevelOrdinalIfPresent(
        actionName: String,
        target: AccessibilityTarget
    ) throws {
        guard consumeSymbol(",") else { return }
        let token = currentToken
        if consumeIdentifier("ordinal") != nil {
            try expectSymbol(":")
            _ = try parseInteger()
            throw error(
                token,
                "Ordinal belongs to the target. Use \(actionName)("
                    + "\(try HeistCanonicalSwiftDSLRenderer().renderCorrection(target: target, addingOrdinal: 0)))."
            )
        }
        throw error(token, "\(actionName)(...) accepts a single AccessibilityTarget")
    }

    mutating func parseTypeTextAction() throws -> HeistActionCommand {
        try expectSymbol("(")
        let textToken = currentToken
        var source: TextInputSource
        if consumeSymbol(".") {
            try expectIdentifier("replacing")
            try expectSymbol("(")
            source = .text(.replacing(try parseStringLiteral()))
            try expectSymbol(")")
        } else {
            switch try parseStringExpr() {
            case .literal(let text):
                do {
                    source = .text(try TextInputText(validating: text))
                } catch let validationError {
                    throw error(textToken, String(describing: validationError))
                }
            case .ref(let reference):
                source = .reference(reference, mode: .append)
            }
        }
        var target: AccessibilityTarget?
        if consumeSymbol(",") {
            let token = currentToken
            if consumeLabel("into") {
                target = try parseTargetExpr()
                if consumeSymbol(",") {
                    let modeToken = currentToken
                    try expectIdentifier("mode")
                    try expectSymbol(":")
                    source = try parseTextInputMode(for: source, token: modeToken)
                }
            } else if consumeLabel("mode") {
                source = try parseTextInputMode(for: source, token: token)
            } else {
                throw error(token, "TypeText(...) accepts only the labeled arguments into: and mode:")
            }
        }
        try expectSymbol(")")
        return .typeText(TypeTextTarget(source: source, target: target))
    }

    mutating func parseTextInputMode(
        for source: TextInputSource,
        token: HeistPlanSourceToken
    ) throws -> TextInputSource {
        let mode = try parseEnumCase(TextInputText.Mode.self, role: "text input mode")
        guard case .reference(let reference, _) = source else {
            throw error(token, "mode: is only valid for referenced text; use .replacing(...) for authored text")
        }
        return .reference(reference, mode: mode)
    }

    mutating func parseClearTextAction() throws -> HeistActionCommand {
        try expectSymbol("(")
        let target = try parseTargetExpr()
        try expectSymbol(")")
        return .typeText(text: .replacing(""), target: target)
    }

    mutating func parseCustomAction() throws -> HeistActionCommand {
        try expectSymbol("(")
        let actionNameToken = currentToken
        let actionName = try parseStringLiteral()
        let admittedName: CustomActionName
        do {
            admittedName = try CustomActionName(validating: actionName)
        } catch let validationError {
            throw error(actionNameToken, String(describing: validationError))
        }
        try expectSymbol(",")
        try expectIdentifier("on")
        try expectSymbol(":")
        let target = try parseTargetExpr()
        try expectSymbol(")")
        return .customAction(name: admittedName, target: target)
    }

    mutating func parseRotorAction() throws -> HeistActionCommand {
        try expectSymbol("(")
        let rotorNameToken = currentToken
        let rotorName = try parseStringLiteral()
        let admittedName: RotorName
        do {
            admittedName = try RotorName(validating: rotorName)
        } catch let validationError {
            throw error(rotorNameToken, String(describing: validationError))
        }
        try expectSymbol(",")
        try expectIdentifier("on")
        try expectSymbol(":")
        let target = try parseTargetExpr()
        var direction = RotorDirection.next
        if consumeSymbol(",") {
            try expectIdentifier("direction")
            try expectSymbol(":")
            direction = try parseEnumCase(RotorDirection.self, role: "rotor direction")
        }
        try expectSymbol(")")
        return .rotor(selection: .named(admittedName), target: target, direction: direction)
    }

    mutating func parseSetPasteboardAction() throws -> HeistActionCommand {
        try expectSymbol("(")
        let textToken = currentToken
        let text = try parseStringLiteral()
        try expectSymbol(")")
        do {
            return .setPasteboard(SetPasteboardTarget(text: try PasteboardText(validating: text)))
        } catch let validationError {
            throw error(textToken, String(describing: validationError))
        }
    }

    mutating func parseTakeScreenshotAction() throws -> HeistActionCommand {
        try expectSymbol("(")
        try expectSymbol(")")
        return .takeScreenshot
    }

    mutating func parseDismissAction() throws -> HeistActionCommand {
        try expectSymbol("(")
        try expectSymbol(")")
        return .dismiss
    }

    mutating func parseMagicTapAction() throws -> HeistActionCommand {
        try expectSymbol("(")
        try expectSymbol(")")
        return .magicTap
    }

    mutating func parseEditAction() throws -> HeistActionCommand {
        try expectSymbol("(")
        let action = try parseEnumCase(EditAction.self, role: "edit action")
        try expectSymbol(")")
        return .editAction(EditActionTarget(action: action))
    }

    mutating func parseDismissKeyboardAction() throws -> HeistActionCommand {
        try expectSymbol("(")
        try expectSymbol(")")
        return .dismissKeyboard
    }

    mutating func parseOneFingerTap() throws -> HeistActionCommand {
        try expectSymbol("(")
        let selection: GesturePointSelection
        if currentToken.kind == .identifier("ScreenPoint") {
            selection = .coordinate(try parseScreenPoint())
        } else {
            let target = try parseTargetExpr()
            if consumeSymbol(",") {
                try expectIdentifier("at")
                try expectSymbol(":")
                selection = .elementUnitPoint(target, try parseUnitPoint())
            } else {
                selection = .element(target)
            }
        }
        try expectSymbol(")")
        return .oneFingerTap(TapTarget(selection: selection))
    }

    mutating func parseLongPress() throws -> HeistActionCommand {
        try expectSymbol("(")
        let selection: GesturePointSelection
        if currentToken.kind == .identifier("ScreenPoint") {
            selection = .coordinate(try parseScreenPoint())
        } else {
            let target = try parseTargetExpr()
            if currentToken.isSymbol(","), nextToken.kind == .identifier("at") {
                try expectSymbol(",")
                try expectIdentifier("at")
                try expectSymbol(":")
                selection = .elementUnitPoint(target, try parseUnitPoint())
            } else {
                selection = .element(target)
            }
        }
        let duration = try parseOptionalGestureDurationArgument() ?? .longPressDefault
        try expectSymbol(")")
        return .longPress(LongPressTarget(selection: selection, duration: duration))
    }

    mutating func parseSwipe() throws -> HeistActionCommand {
        try expectSymbol("(")
        let selection: SwipeGestureSelection
        if consumeLabel("from") {
            let start = try parseScreenPoint()
            try expectSymbol(",")
            if consumeLabel("to") {
                selection = .pointToPoint(start: start, end: try parseScreenPoint())
            } else {
                let direction = try parseEnumCase(SwipeDirection.self, role: "swipe direction")
                selection = .pointDirection(start: start, direction: direction)
            }
        } else {
            let target = try parseTargetExpr()
            try expectSymbol(",")
            if consumeLabel("from") {
                let start = try parseUnitPoint()
                try expectSymbol(",")
                try expectIdentifier("to")
                try expectSymbol(":")
                selection = .unitElement(target, start: start, end: try parseUnitPoint())
            } else {
                selection = .elementDirection(target, try parseEnumCase(SwipeDirection.self, role: "swipe direction"))
            }
        }
        let duration = try parseOptionalGestureDurationArgument()
        try expectSymbol(")")
        return .swipe(SwipeTarget(selection: selection, duration: duration))
    }

    mutating func parseDrag() throws -> HeistActionCommand {
        try expectSymbol("(")
        let selection: DragGestureSelection
        if consumeLabel("from") {
            let start = try parseScreenPoint()
            try expectSymbol(",")
            try expectIdentifier("to")
            try expectSymbol(":")
            selection = .pointToPoint(start: start, end: try parseScreenPoint())
        } else {
            let target = try parseTargetExpr()
            try expectSymbol(",")
            let start: UnitPoint?
            if consumeLabel("from") {
                start = try parseUnitPoint()
                try expectSymbol(",")
            } else {
                start = nil
            }
            try expectIdentifier("to")
            try expectSymbol(":")
            selection = .elementToPoint(target, start: start, end: try parseScreenPoint())
        }
        let duration = try parseOptionalGestureDurationArgument()
        try expectSymbol(")")
        return .drag(DragTarget(selection: selection, duration: duration))
    }

    mutating func parseFiniteCoordinate() throws -> FiniteCoordinate {
        let coordinateToken = currentToken
        let value = try parseNumber()
        do {
            return try FiniteCoordinate(validating: value)
        } catch let validationError {
            throw error(coordinateToken, String(describing: validationError))
        }
    }

    mutating func parseScreenPoint() throws -> ScreenPoint {
        try expectIdentifier("ScreenPoint")
        try expectSymbol("(")
        try expectIdentifier("x")
        try expectSymbol(":")
        let x = try parseFiniteCoordinate()
        try expectSymbol(",")
        try expectIdentifier("y")
        try expectSymbol(":")
        let y = try parseFiniteCoordinate()
        try expectSymbol(")")
        return ScreenPoint(x: x, y: y)
    }

    mutating func parseUnitPoint() throws -> UnitPoint {
        try expectIdentifier("UnitPoint")
        try expectSymbol("(")
        try expectIdentifier("x")
        try expectSymbol(":")
        let x = try parseFiniteCoordinate()
        try expectSymbol(",")
        try expectIdentifier("y")
        try expectSymbol(":")
        let y = try parseFiniteCoordinate()
        try expectSymbol(")")
        return UnitPoint(x: x, y: y)
    }

    mutating func parseGestureDuration() throws -> GestureDuration {
        let durationToken = currentToken
        let seconds = try parseNumber()
        do {
            return try GestureDuration(validatingSeconds: seconds)
        } catch let validationError {
            throw error(durationToken, String(describing: validationError))
        }
    }

    mutating func parseOptionalGestureDurationArgument() throws -> GestureDuration? {
        guard consumeSymbol(",") else { return nil }
        try expectIdentifier("duration")
        try expectSymbol(":")
        return try parseGestureDuration()
    }

    mutating func parseActionStep(
        command: HeistActionCommand
    ) throws -> HeistStep {
        var content = Action(command: command)
        var repeatedContent: Action.Repeated?
        while consumeSymbol(".") {
            let chainToken = currentToken
            let chain = try parseIdentifier()
            guard repeatedContent == nil else {
                throw error(chainToken, "unsupported action chain after '.until'")
            }
            switch chain {
            case "expect":
                try expectSymbol("(")
                let predicate: AccessibilityPredicate
                let timeout: WaitTimeout?
                if currentToken.isSymbol(")") {
                    throw error(currentToken, ".expect(...) requires a canonical predicate")
                } else {
                    predicate = try parseAccessibilityPredicateExpr()
                    timeout = try parseTrailingTimeout(defaultValue: nil)
                }
                try expectSymbol(")")
                content = content.expect(predicate, timeout: timeout)
            case "withoutExpectation":
                try expectSymbol("(")
                let reason = try parseStringLiteral()
                try expectSymbol(")")
                content = content.withoutExpectation(try ActionExpectationWaiver(validating: reason))
            case "until":
                try expectSymbol("(")
                let predicate = try parseAccessibilityPredicateExpr()
                let timeout = try parseTrailingTimeout(defaultValue: defaultWaitTimeout) ?? defaultWaitTimeout
                try expectSymbol(")")
                repeatedContent = content.repeated(until: predicate, timeout: timeout)
            default:
                throw error(chainToken, "unsupported action chain '.\(chain)'")
            }
        }
        if let repeatedContent {
            if let diagnostic = repeatedContent.heistContent.diagnostics.first {
                throw error(previous, diagnostic.message)
            }
            let steps = repeatedContent.heistContent.steps
            guard let step = steps.first, steps.count == 1 else {
                throw error(previous, "action .until statement did not produce exactly one step")
            }
            return step
        }
        if let diagnostic = content.heistContent.diagnostics.first {
            throw error(previous, diagnostic.message)
        }
        let steps = content.heistContent.steps
        guard let step = steps.first, steps.count == 1 else {
            throw error(previous, "action statement did not produce exactly one step")
        }
        return step
    }

}
