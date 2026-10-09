import Foundation

extension HeistPlanSourceParser {
    mutating func parseProgram() throws -> HeistPlan {
        guard startsRootHeistPlan else {
            try rejectForbiddenStatementSyntax()
            throw error(currentToken, "ButtonHeist source must be a canonical root plan: `HeistPlan { ... }`")
        }

        let name = try parseCalleeName()
        guard name == ["HeistPlan"] else {
            throw error(previous, "expected `HeistPlan { ... }`")
        }
        let root = try parseHeistPlanAfterCallee(allowDefinitions: true)
        try expect(.eof)
        var validator = HeistPlanRuntimeSafetyValidator(limits: .standard)
        try validator.validate(root)
        return root
    }

    private mutating func parseHeistBody(
        untilRightBrace: Bool,
        allowDefinitions: Bool
    ) throws -> (definitions: [HeistPlan], steps: [HeistStep]) {
        var definitions: [HeistPlan] = []
        var steps: [HeistStep] = []
        var seenStep = false
        while true {
            skipSemicolons()
            if atEnd { break }
            if consumeSymbol("}") {
                if untilRightBrace {
                    return (definitions, steps)
                }
                throw error(previous, "unexpected '}'")
            }
            if allowDefinitions, startsDefinition {
                guard !seenStep else {
                    throw error(currentToken, "canonical HeistDef definitions must appear before actions in their block")
                }
                definitions.append(try parseDefinition())
                continue
            }
            try rejectForbiddenStatementSyntax()
            steps.append(contentsOf: try parseStatement())
            seenStep = true
        }
        if untilRightBrace {
            throw error(currentToken, "expected '}' to close ButtonHeist source block")
        }
        return (definitions, steps)
    }

    private mutating func parseDefinition() throws -> HeistPlan {
        let callee = try parseCalleeName()
        switch callee {
        case ["HeistDef"]:
            return try parseHeistDef(parameterKind: try parseHeistDefGeneric())
        case ["Namespace"]:
            return try parseNamespaceDefinition()
        default:
            throw error(previous, "heist definitions must use `HeistDef<...>(\"Name\") { ... }` or `Namespace(\"Name\") { ... }`")
        }
    }

    private mutating func parseNamespaceDefinition() throws -> HeistPlan {
        try expectSymbol("(")
        let nameToken = currentToken
        let name = try parseStringLiteral()
        try expectSymbol(")")
        let body = try parseHeistClosureBody(parameter: .none, allowDefinitions: true)
        guard body.steps.isEmpty else {
            throw error(previous, "Namespace blocks may contain HeistDef or Namespace declarations only")
        }
        return HeistPlan(
            structuralVersion: HeistPlan.currentVersion,
            name: try parsePlanName(name, token: nameToken),
            parameter: .none,
            definitions: HeistPlan.mergeDefinitions(body.definitions, duplicatePolicy: .preserve),
            body: []
        )
    }

    private mutating func parseHeistDefGeneric() throws -> HeistParameterKind {
        try expectSymbol("<")
        let type = try parseIdentifier()
        try expectSymbol(">")
        switch type {
        case "Void":
            return .none
        case "String":
            return .string
        case "AccessibilityTarget":
            return .accessibilityTarget
        default:
            throw error(previous, "unsupported HeistDef parameter type '\(type)'")
        }
    }

    private mutating func parseHeistDef(
        parameterKind: HeistParameterKind
    ) throws -> HeistPlan {
        try expectSymbol("(")
        let pathToken = currentToken
        let path = try parseStringLiteral()
        var parameter = HeistParameter.none
        if consumeSymbol(",") {
            try expectIdentifier("parameter")
            try expectSymbol(":")
            let parameterName = try parseReferenceNameLiteral(role: "parameter")
            switch parameterKind {
            case .none:
                throw error(previous, "HeistDef<Void> must not declare parameter:")
            case .string:
                parameter = .string(name: parameterName)
            case .accessibilityTarget:
                parameter = .accessibilityTarget(name: parameterName)
            }
        }
        try expectSymbol(")")

        switch (parameterKind, parameter) {
        case (.none, .none), (.string, .string), (.accessibilityTarget, .accessibilityTarget):
            break
        case (.string, .none):
            throw error(previous, "HeistDef<String> must declare `parameter: \"name\"`")
        case (.accessibilityTarget, .none):
            throw error(previous, "HeistDef<AccessibilityTarget> must declare `parameter: \"name\"`")
        default:
            throw error(previous, "HeistDef parameter type does not match its parameter declaration")
        }
        let definitionPath: HeistDefinitionPath
        do {
            definitionPath = try HeistDefinitionPath(validating: path)
        } catch {
            throw HeistPlanBuildError(diagnostic: .invalidDefinitionPath(
                path,
                error: error,
                phase: .sourceCompilation,
                sourceSpan: pathToken.sourceSpan
            ))
        }
        let body = try parseHeistClosureBody(parameter: parameter, allowDefinitions: true)
        return HeistPlan.nestedDefinition(
            path: definitionPath,
            parameter: parameter,
            definitions: HeistPlan.mergeDefinitions(body.definitions, duplicatePolicy: .preserve),
            body: body.steps
        )
    }

    private mutating func parseStatement() throws -> [HeistStep] {
        let name = try parseCalleeName()

        switch name {
        case ["Activate"]:
            return [try parseActionStep(command: parseElementTargetAction("Activate", makeCommand: HeistActionCommand.activate))]
        case ["Increment"]:
            return [try parseActionStep(command: parseElementTargetAction("Increment", makeCommand: HeistActionCommand.increment))]
        case ["Decrement"]:
            return [try parseActionStep(command: parseElementTargetAction("Decrement", makeCommand: HeistActionCommand.decrement))]
        case ["TypeText"]:
            return [try parseActionStep(command: parseTypeTextAction())]
        case ["ClearText"]:
            return [try parseActionStep(command: parseClearTextAction())]
        case ["CustomAction"]:
            return [try parseActionStep(command: parseCustomAction())]
        case ["Rotor"]:
            return [try parseActionStep(command: parseRotorAction())]
        case ["SetPasteboard"]:
            return [try parseActionStep(command: parseSetPasteboardAction())]
        case ["TakeScreenshot"]:
            return [try parseActionStep(command: parseTakeScreenshotAction())]
        case ["ScreenActions", "Dismiss"]:
            return [try parseActionStep(command: parseDismissAction())]
        case ["ScreenActions", "MagicTap"]:
            return [try parseActionStep(command: parseMagicTapAction())]
        case ["Edit"]:
            return [try parseActionStep(command: parseEditAction())]
        case ["dismissKeyboard"]:
            return [try parseActionStep(command: parseDismissKeyboardAction())]
        case ["oneFingerTap"]:
            return [try parseActionStep(command: parseOneFingerTap())]
        case ["longPress"]:
            return [try parseActionStep(command: parseLongPress())]
        case ["swipe"]:
            return [try parseActionStep(command: parseSwipe())]
        case ["drag"]:
            return [try parseActionStep(command: parseDrag())]
        case ["WaitFor"]:
            return [try parseWaitFor()]
        case ["If"]:
            return [try parseIf()]
        case ["ForEach"]:
            return [try parseForEach()]
        case ["RepeatUntil"]:
            return [try parseRepeatUntil()]
        case ["HeistPlan"]:
            let plan = try parseHeistPlanAfterCallee(allowDefinitions: false)
            return [.heist(plan)]
        case ["RunHeist"]:
            return [try parseRunHeist()]
        case ["Warn"]:
            return [try parseWarn()]
        case ["Fail"]:
            return [try parseFail()]
        default:
            throw error(previous, "unsupported ButtonHeist source statement '\(name.joined(separator: "."))'")
        }
    }

    private mutating func parseHeistPlanAfterCallee(allowDefinitions: Bool) throws -> HeistPlan {
        var name: HeistPlanName?
        var parameter = HeistParameter.none
        if consumeSymbol("(") {
            if currentToken.isSymbol(")") {
                throw error(currentToken, "empty HeistPlan parentheses are not canonical; use `HeistPlan { ... }`")
            }

            if currentToken.kind == .identifier("parameter") || currentToken.kind == .identifier("targetParameter") {
                parameter = try parseRootHeistParameter()
            } else {
                let nameToken = currentToken
                name = try parsePlanName(parseStringLiteral(), token: nameToken)
                if consumeSymbol(",") {
                    parameter = try parseRootHeistParameter()
                }
            }
            try expectSymbol(")")
        }

        let body = try parseHeistClosureBody(parameter: parameter, allowDefinitions: allowDefinitions)
        let definitions = HeistPlan.mergeDefinitions(body.definitions, duplicatePolicy: .preserve)
        return HeistPlan(
            structuralVersion: HeistPlan.currentVersion,
            name: name,
            parameter: parameter,
            definitions: definitions,
            body: body.steps
        )
    }

    private func parsePlanName(_ value: String, token: HeistPlanSourceToken) throws -> HeistPlanName {
        do {
            return try HeistPlanName(validating: value)
        } catch {
            throw self.error(token, String(describing: error))
        }
    }

    private mutating func parseRootHeistParameter() throws -> HeistParameter {
        if consumeIdentifier("parameter") != nil {
            try expectSymbol(":")
            return .string(name: try parseReferenceNameLiteral(role: "parameter"))
        }
        if consumeIdentifier("targetParameter") != nil {
            try expectSymbol(":")
            return .accessibilityTarget(name: try parseReferenceNameLiteral(role: "targetParameter"))
        }
        throw error(currentToken, "expected parameter: or targetParameter:")
    }

    private mutating func parseHeistClosureBody(
        parameter: HeistParameter,
        allowDefinitions: Bool
    ) throws -> (definitions: [HeistPlan], steps: [HeistStep]) {
        try expectSymbol("{")
        let previousScope = scope
        defer { scope = previousScope }
        if parameter.name != nil {
            let localName = try parseIdentifier()
            try expectIdentifier("in")
            bindScopedParameter(parameter, localName: localName)
        }
        return try parseHeistBody(untilRightBrace: true, allowDefinitions: allowDefinitions)
    }

}

private extension HeistPlanSourceParser {
    mutating func parseWaitFor() throws -> HeistStep {
        try expectSymbol("(")
        let predicate = try parseAccessibilityPredicateExpr()
        let timeout = try parseTrailingTimeout(defaultValue: defaultWaitTimeout) ?? defaultWaitTimeout
        try expectSymbol(")")
        return .wait(WaitStep(
            predicate: predicate,
            timeout: timeout,
            elseBody: try parseLowercaseElseChainIfPresent(chainContext: "WaitFor")
        ))
    }

    mutating func parseIf() throws -> HeistStep {
        if consumeSymbol("(") {
            let predicate = try parsePresenceCondition()
            try expectSymbol(")")
            return .conditional(try parseSinglePredicateBranches(predicate: predicate, chainContext: "If"))
        }
        return .conditional(try parsePredicateBranches())
    }

    mutating func parseForEach() throws -> HeistStep {
        try expectSymbol("(")
        if consumeSymbol("[") {
            throw error(previous, #"ForEach string loops use `ForEach("a", "b")`, not array literals"#)
        }
        if case .string = currentToken.kind {
            var values: [String] = []
            repeat {
                values.append(try parseStringLiteral())
            } while consumeSymbol(",")
            try expectSymbol(")")
            return try parseScopedClosure(binding: .string) { parameter, body in
                .forEachString(try ForEachStringStep(
                    values: values,
                    parameter: parameter,
                    body: body
                ))
            }
        }
        let matching = try parseElementLoopPredicate()
        var limit = 20
        while consumeSymbol(",") {
            if consumeIdentifier("limit") != nil {
                try expectSymbol(":")
                limit = try parseInteger()
            } else {
                throw error(currentToken, "ForEach element loop accepts only limit:")
            }
        }
        try expectSymbol(")")
        return try parseScopedClosure(binding: .target) { parameter, body in
            .forEachElement(try ForEachElementStep(
                matching: matching,
                limit: limit,
                parameter: parameter,
                body: body
            ))
        }
    }

    mutating func parseRepeatUntil() throws -> HeistStep {
        try expectSymbol("(")
        let predicate = try parseAccessibilityPredicateExpr()
        guard let timeout = try parseTrailingTimeout(defaultValue: nil) else {
            throw error(currentToken, "RepeatUntil requires timeout in seconds")
        }
        try expectSymbol(")")
        let body = try parseHeistBlock()
        return .repeatUntil(try RepeatUntilStep(
            predicate: predicate,
            timeout: timeout,
            body: body
        ))
    }

    mutating func parseElementLoopPredicate() throws -> ElementPredicate {
        try expectSymbol(".")
        let name = try parseIdentifier()
        if name == "matching" {
            throw error(previous, #"ForEach element loops use direct predicates like `ForEach(.label("x"))`, not `.matching(...)`"#)
        }
        return try parseElementPredicate(named: name)
    }

    mutating func parseRunHeist() throws -> HeistStep {
        try expectSymbol("(")
        let nameToken = currentToken
        let name = try parseStringLiteral()
        let invocationPath: HeistInvocationPath
        do {
            invocationPath = try HeistInvocationPath(validating: name)
        } catch let validationError {
            throw HeistPlanBuildError(diagnostic: .invalidInvocationPath(
                name,
                error: validationError,
                phase: .sourceCompilation,
                sourceSpan: nameToken.sourceSpan
            ))
        }
        var argument = HeistArgument.none
        if consumeSymbol(",") {
            argument = try parseHeistArgument()
        }
        try expectSymbol(")")
        var expectation = AuthoredActionExpectation.default
        while consumeSymbol(".") {
            let chainToken = currentToken
            let chain = try parseIdentifier()
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
                expectation = expectation.appending(predicate, timeout: timeout)
                if let diagnostic = expectation.diagnostics.first {
                    throw error(chainToken, diagnostic.message)
                }
            default:
                throw error(chainToken, "unsupported RunHeist chain '.\(chain)'")
            }
        }
        return .invoke(HeistInvocationStep(
            path: invocationPath,
            argument: argument,
            expectation: expectation.policy.expectedExpectation
        ))
    }

    mutating func parseHeistArgument() throws -> HeistArgument {
        if let string = try parseStringExprIfPresent() {
            return HeistArgument(core: .string(string))
        }
        return .accessibilityTarget(try parseTargetExpr())
    }

    mutating func parseWarn() throws -> HeistStep {
        try expectSymbol("(")
        let messageToken = currentToken
        let message = try parseStringLiteral()
        try expectSymbol(")")
        do {
            return .warn(WarnStep(message: try HeistWarningMessage(validating: message)))
        } catch let validationError {
            throw error(messageToken, String(describing: validationError))
        }
    }

    mutating func parseFail() throws -> HeistStep {
        try expectSymbol("(")
        let messageToken = currentToken
        let message = try parseStringLiteral()
        try expectSymbol(")")
        do {
            return .fail(FailStep(message: try HeistFailureMessage(validating: message)))
        } catch let validationError {
            throw error(messageToken, String(describing: validationError))
        }
    }

    mutating func parsePredicateBranches() throws -> ConditionalStep {
        try expectSymbol("{")
        var cases: [PredicateCase] = []
        var elseBody: [HeistStep]?
        while !consumeSymbol("}") {
            try rejectForbiddenStatementSyntax()
            let token = currentToken
            let name = try parseIdentifier()
            switch name {
            case "Case":
                guard elseBody == nil else {
                    throw error(token, "Case must appear before Else")
                }
                try expectSymbol("(")
                let predicate = try parsePresenceCondition()
                try expectSymbol(")")
                cases.append(PredicateCase(
                    predicate: predicate,
                    body: try parseHeistBlock()
                ))
            case "Else":
                guard elseBody == nil else {
                    throw error(token, "a branch block accepts at most one Else")
                }
                elseBody = try parseHeistBlock()
            default:
                throw error(token, "branch blocks accept only Case(...) and Else")
            }
        }
        return try ConditionalStep(cases: cases, elseBody: elseBody)
    }

    mutating func parseSinglePredicateBranches(
        predicate: PresenceCondition,
        chainContext: String
    ) throws -> ConditionalStep {
        let body = try parseHeistBlock()
        let elseBody = try parseLowercaseElseChainIfPresent(chainContext: chainContext)
        return try ConditionalStep(
            cases: [PredicateCase(predicate: predicate, body: body)],
            elseBody: elseBody
        )
    }

    mutating func parseHeistBlock() throws -> [HeistStep] {
        try expectSymbol("{")
        return try parseHeistBody(untilRightBrace: true, allowDefinitions: false).steps
    }

    mutating func parseLowercaseElseChainIfPresent(
        chainContext: String
    ) throws -> [HeistStep]? {
        guard consumeSymbol(".") else { return nil }
        let token = currentToken
        let chain = try parseIdentifier()
        guard chain == "else" else {
            throw error(token, "unsupported \(chainContext) chain '.\(chain)'")
        }
        return try parseHeistBlock()
    }

    mutating func parseScopedClosure(
        binding: HeistPlanSourceBinding,
        project: (HeistReferenceName, [HeistStep]) throws -> HeistStep
    ) throws -> HeistStep {
        try expectSymbol("{")
        let localName = try parseIdentifier()
        try expectIdentifier("in")
        let referenceName = try HeistReferenceName(validating: localName)
        let previousScope = scope
        defer { scope = previousScope }
        bindScopedReference(binding, localName: localName, referenceName: referenceName)
        return try project(
            referenceName,
            parseHeistBody(untilRightBrace: true, allowDefinitions: false).steps
        )
    }
}
