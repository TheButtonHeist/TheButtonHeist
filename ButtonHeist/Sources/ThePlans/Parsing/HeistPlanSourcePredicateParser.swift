import Foundation

extension HeistPlanSourceParser {
    mutating func parseAccessibilityPredicateExpr() throws -> AccessibilityPredicate {
        let name = try parseDotCallName()
        switch name {
        case "screenChanged":
            return try parseScreenChanged()
        case "elementsChanged":
            return try parseElementsChanged()
        case "notification":
            return try parseNotificationPredicate()
        case "exists", "missing":
            let target = try parseCurrentTreeTarget()
            return name == "exists" ? .exists(target) : .missing(target)
        default:
            throw error(previous, "unsupported accessibility predicate '.\(name)'")
        }
    }

    mutating func parseNotificationPredicate() throws -> AccessibilityPredicate {
        guard consumeSymbol("(") else { return .notification }
        if consumeSymbol(")") {
            throw error(previous, "empty notification predicate must use .notification")
        }

        if consumeLabel("text") {
            let text = try parseStringMatchFieldValue(field: "notification text")
            let element: ElementPredicate?
            if consumeSymbol(",") {
                try expectIdentifier("element")
                try expectSymbol(":")
                element = try parseElementPredicate()
            } else {
                element = nil
            }
            try expectSymbol(")")
            return .notification(text: text, element: element)
        }
        if consumeLabel("element") {
            let element = try parseElementPredicate()
            try expectSymbol(")")
            return .notification(element: element)
        }

        let expression = try parseStringMatchCallArgument(field: "notification")
        try expectSymbol(")")
        return .notification(expression)
    }

    mutating func parseScreenChanged() throws -> AccessibilityPredicate {
        // `.screenChanged` asks only that a boundary was crossed;
        // `.screenChanged("Name")` asks which screen it arrived at. Elements are
        // never named here — those are element assertions, answered by the
        // snapshots either side.
        guard consumeSymbol("(") else { return .screenChanged }
        if consumeSymbol(")") { return .screenChanged }
        if currentToken.isSymbol("[") {
            throw error(
                currentToken,
                "screen predicates name the arrived-at screen, not elements: "
                    + "use .screenChanged or .screenChanged(\"Name\"), "
                    + "and .elementsChanged([...]) for element assertions"
            )
        }
        let expression = try parseStringMatchCallArgument(field: "screenChanged")
        try expectSymbol(")")
        return .screenChanged(ScreenPredicate(match: expression))
    }

    mutating func parseElementsChanged() throws -> AccessibilityPredicate {
        guard consumeSymbol("(") else { return .elementsChanged }
        var assertions: [ElementAssertion] = []
        if !consumeSymbol(")") {
            try expectSymbol("[")
            repeat {
                assertions.append(try parseElementsAssertion())
            } while consumeSymbol(",")
            try expectSymbol("]")
            try expectSymbol(")")
        }
        return .elementsChanged(assertions)
    }

    mutating func parseCurrentTreeTarget() throws -> AccessibilityTarget {
        try expectSymbol("(")
        let target = try parseTargetExpr()
        try expectSymbol(")")
        return target
    }

    mutating func parsePresenceCondition() throws -> PresenceCondition {
        let name = try parseDotCallName()
        guard name == "exists" || name == "missing" else {
            throw error(previous, "branch conditions accept only .exists and .missing")
        }
        let target = try parseCurrentTreeTarget()
        return name == "exists" ? .exists(target) : .missing(target)
    }

    mutating func parseElementsAssertion() throws -> ElementAssertion {
        let name = try parseDotCallName()
        switch name {
        case "exists", "missing":
            let target = try parseCurrentTreeTarget()
            return name == "exists" ? .exists(target) : .missing(target)
        case "appeared":
            return .appeared(try parseCurrentTreeTarget())
        case "disappeared":
            return .disappeared(try parseCurrentTreeTarget())
        case "updated":
            return try parseUpdatedAssertion()
        default:
            throw error(
                previous,
                "unsupported elements assertion '.\(name)'. Valid: exists, missing, appeared, disappeared, updated"
            )
        }
    }

    mutating func parseUpdatedAssertion() throws -> ElementAssertion {
        try expectSymbol("(")
        let targetToken = currentToken
        let parsedTarget = try parseTargetExpr()
        let target: AccessibilityElementTarget
        do {
            target = try AccessibilityElementTarget(admitting: parsedTarget)
        } catch let grammarError as AccessibilityTargetGrammarError {
            throw error(targetToken, grammarError.diagnosticDescription)
        }
        try expectSymbol(",")
        let change = try parsePropertyChangeExpr()
        try expectSymbol(")")
        return .updated(target, change)
    }
    mutating func parsePropertyChangeExpr() throws -> ElementPropertyChange {
        let name = try parseDotCallName()
        try expectSymbol("(")
        let change: ElementPropertyChange
        switch name {
        case "value":
            var before: StringMatch?
            var after: StringMatch?
            try parsePropertyChangeFields(
                property: name,
                allowsUnlabeledAfter: true
            ) { parser, isBefore, isLabeled, role in
                let value = try isLabeled
                    ? parser.parseStringPropertyUpdateFieldValue(field: role)
                    : parser.parseStringMatchCallArgument(field: role)
                if isBefore { before = value } else { after = value }
            }
            change = .value(before: before, after: after)
        case "hint":
            var before: StringMatch?
            var after: StringMatch?
            try parsePropertyChangeFields(property: name) { parser, isBefore, _, role in
                let value = try parser.parseStringPropertyUpdateFieldValue(field: role)
                if isBefore { before = value } else { after = value }
            }
            change = .hint(before: before, after: after)
        case "actions":
            var before: ActionSetMatch?
            var after: ActionSetMatch?
            try parsePropertyChangeFields(property: name) { parser, isBefore, _, role in
                let value = try parser.parseActionSetMatch(role: role)
                if isBefore { before = value } else { after = value }
            }
            change = .actions(before: before, after: after)
        case "customContent":
            var before: CustomContentMatch?
            var after: CustomContentMatch?
            try parsePropertyChangeFields(property: name) { parser, isBefore, _, role in
                let value = try parser.parseCustomContentMatch(role: role)
                if isBefore { before = value } else { after = value }
            }
            change = .customContent(before: before, after: after)
        case "rotors":
            var before: RotorSetMatch?
            var after: RotorSetMatch?
            try parsePropertyChangeFields(property: name) { parser, isBefore, _, role in
                let value = try parser.parseRotorSetMatch(role: role)
                if isBefore { before = value } else { after = value }
            }
            change = .rotors(before: before, after: after)
        case "traits":
            var before: TraitSetMatch?
            var after: TraitSetMatch?
            try parsePropertyChangeFields(property: name) { parser, isBefore, _, role in
                let value = try parser.parseTraitSetMatch(role: role)
                if isBefore { before = value } else { after = value }
            }
            change = .traits(before: before, after: after)
        default:
            throw error(previous, "unsupported element update property '.\(name)'. Valid: \(Self.validElementProperties)")
        }
        try expectSymbol(")")
        return change
    }

    private mutating func parsePropertyChangeFields(
        property: String,
        allowsUnlabeledAfter: Bool = false,
        parse: (inout HeistPlanSourceParser, Bool, Bool, String) throws -> Void
    ) throws {
        guard !currentToken.isSymbol(")") else { return }
        let startsFieldLabel: Bool
        if case .identifier = currentToken.kind {
            startsFieldLabel = nextToken.isSymbol(":")
        } else {
            startsFieldLabel = false
        }
        if allowsUnlabeledAfter, !startsFieldLabel {
            try parse(&self, false, false, "\(property) after")
            return
        }
        var parsedBefore = false
        var parsedAfter = false
        while true {
            let isBefore: Bool
            if consumeLabel("before") {
                guard !parsedBefore else {
                    throw error(previous, "\(property) update predicate accepts before only once")
                }
                parsedBefore = true
                isBefore = true
            } else if consumeLabel("after") {
                guard !parsedAfter else {
                    throw error(previous, "\(property) update predicate accepts after only once")
                }
                parsedAfter = true
                isBefore = false
            } else {
                throw error(currentToken, "\(property) update predicate accepts before and after")
            }
            try parse(&self, isBefore, true, "\(property) \(isBefore ? "before" : "after")")
            guard consumeSymbol(",") else { break }
        }
        if parsedBefore, !parsedAfter {
            throw error(currentToken, "\(property) update predicate requires after when before is set")
        }
    }

    mutating func parseTraitSetMatch(role: String) throws -> TraitSetMatch {
        try expectContextualInitializer(role: "trait set match")
        var include: [HeistTrait] = []
        var exclude: [HeistTrait] = []
        try parseIncludeExclude(role: role) { parser, isInclude, fieldRole in
            let traits = try parser.parseTraitArray(role: fieldRole)
            if isInclude { include = traits } else { exclude = traits }
        }
        try expectSymbol(")")
        return TraitSetMatch(include: include, exclude: exclude)
    }

    mutating func parseActionSetMatch(role: String) throws -> ActionSetMatch {
        try expectContextualInitializer(role: "action set match")
        var include: Set<ElementAction> = []
        var exclude: Set<ElementAction> = []
        try parseIncludeExclude(role: role) { parser, isInclude, fieldRole in
            let actions = Set(try parser.parseActionArray(role: fieldRole))
            if isInclude { include = actions } else { exclude = actions }
        }
        try expectSymbol(")")
        return ActionSetMatch(include: include, exclude: exclude)
    }

    mutating func parseActionArray(role: String) throws -> [ElementAction] {
        try expectSymbol("[")
        var actions: [ElementAction] = []
        if !consumeSymbol("]") {
            repeat {
                actions.append(try parseElementAction(role: role))
            } while consumeSymbol(",")
            try expectSymbol("]")
        }
        return actions
    }

    mutating func parseElementAction(role: String) throws -> ElementAction {
        guard consumeSymbol(".") else {
            throw error(currentToken, "\(role) actions must use enum-style syntax like [.activate]")
        }
        let token = currentToken
        let name = try parseIdentifier()
        switch name {
        case "activate":
            return .activate
        case "typeText":
            return .typeText
        case "increment":
            return .increment
        case "decrement":
            return .decrement
        case "custom":
            try expectSymbol("(")
            let customNameToken = currentToken
            let customName = try parseStringLiteral()
            let admittedName: CustomActionName
            do {
                admittedName = try CustomActionName(validating: customName)
            } catch let validationError {
                throw error(customNameToken, String(describing: validationError))
            }
            try expectSymbol(")")
            return .custom(admittedName)
        default:
            throw error(token, "unsupported action '.\(name)'. Valid: activate, typeText, increment, decrement, custom")
        }
    }

    mutating func parseSignedInteger() throws -> Int {
        let token = currentToken
        let value = try parseNumber()
        guard value.rounded(.towardZero) == value,
              value >= Double(Int.min),
              value <= Double(Int.max) else {
            throw error(token, "expected an integer")
        }
        return Int(value)
    }

    mutating func parseRotorSetMatch(role: String) throws -> RotorSetMatch {
        try expectContextualInitializer(role: "rotor set match")
        var include: [StringMatch] = []
        var exclude: [StringMatch] = []
        try parseIncludeExclude(role: role) { parser, isInclude, fieldRole in
            let matches = try parser.parseStringMatchArray(role: fieldRole)
            if isInclude { include = matches } else { exclude = matches }
        }
        try expectSymbol(")")
        return RotorSetMatch(include: include, exclude: exclude)
    }

    mutating func expectContextualInitializer(role: String) throws {
        try expectSymbol(".")
        let token = currentToken
        let name = try parseIdentifier()
        guard name == "init" else {
            throw error(token, "\(role) must use .init(...)")
        }
        try expectSymbol("(")
    }

    private mutating func parseIncludeExclude(
        role: String,
        parse: (inout HeistPlanSourceParser, Bool, String) throws -> Void
    ) throws {
        var parsedInclude = false
        var parsedExclude = false
        if !currentToken.isSymbol(")") {
            while true {
                let isInclude: Bool
                if consumeLabel("include") {
                    guard !parsedInclude else {
                        throw error(previous, "\(role) accepts include only once")
                    }
                    parsedInclude = true
                    isInclude = true
                } else if consumeLabel("exclude") {
                    guard !parsedExclude else {
                        throw error(previous, "\(role) accepts exclude only once")
                    }
                    parsedExclude = true
                    isInclude = false
                } else {
                    throw error(currentToken, "\(role) accepts include and exclude")
                }
                try parse(&self, isInclude, "\(role) \(isInclude ? "include" : "exclude")")
                guard consumeSymbol(",") else { break }
            }
        }
    }

    mutating func parseStringMatchArray(role: String) throws -> [StringMatch] {
        try expectSymbol("[")
        var matches: [StringMatch] = []
        if !consumeSymbol("]") {
            repeat {
                matches.append(try parseStringMatchFieldValue(field: role))
            } while consumeSymbol(",")
            try expectSymbol("]")
        }
        return matches
    }

    private static var validElementProperties: String {
        AssertableProperty.nameList
    }
}
