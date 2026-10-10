import Foundation

extension HeistPlanSourceParser {
    mutating func rejectForbiddenStatementSyntax() throws {
        guard case .identifier(let name) = currentToken.kind else { return }
        switch name {
        case "import":
            throw error(currentToken, "import declarations are not supported in ButtonHeist source")
        case "let", "var":
            throw error(
                currentToken,
                "\(name) declarations are not supported inside ButtonHeist DSL bodies; wrap the heist in Swift and pass values through parameters or RunHeist"
            )
        case "func":
            throw error(currentToken, "function declarations are not supported in ButtonHeist source")
        case "class", "struct", "protocol", "extension", "actor":
            throw error(currentToken, "type declarations are not supported in ButtonHeist source")
        case "enum":
            throw error(currentToken, "enum declarations are Swift wrapper code, not ButtonHeist DSL body syntax")
        case "if":
            throw error(currentToken, "native Swift if/else is not supported inside ButtonHeist DSL bodies. Use If { Case(...) { ... } Else { ... } }")
        case "repeat":
            throw error(currentToken, "native Swift repeat/while is not supported; use RepeatUntil for bounded repeated actions")
        case "for", "while", "switch":
            throw error(
                currentToken,
                "native Swift \(name) statements are not supported; use ButtonHeist constructs such as If, WaitFor, ForEach, and RepeatUntil"
            )
        case "try":
            if let correction = runHeistCorrectionAfterTryPrefix(startingAt: index + 1) {
                throw error(
                    currentToken,
                    "`try` is only allowed in Swift wrapper code, not inside ButtonHeist DSL bodies. Use \(correction)."
                )
            }
            throw error(currentToken, "`try` is only allowed in Swift wrapper code, not inside ButtonHeist DSL bodies")
        case "await":
            throw error(currentToken, "`await` is not supported in ButtonHeist source")
        default:
            return
        }
    }

    func runHeistCorrectionAfterTryPrefix(startingAt startIndex: Int) -> String? {
        guard tokens.indices.contains(startIndex),
              case .identifier(let first) = tokens[startIndex].kind else {
            return nil
        }
        var names = [first]
        var cursor = startIndex + 1
        while tokens.indices.contains(cursor), tokens[cursor].isSymbol(".") {
            let nameIndex = cursor + 1
            guard tokens.indices.contains(nameIndex),
                  case .identifier(let name) = tokens[nameIndex].kind else {
                return nil
            }
            names.append(name)
            cursor = nameIndex + 1
        }
        guard names.count > 1,
              tokens.indices.contains(cursor),
              tokens[cursor].isSymbol("(") else {
            return nil
        }
        return "RunHeist(\(CanonicalValueDescription.quoted(names.joined(separator: "."))))"
    }

    func error(
        _ token: HeistPlanSourceToken,
        _ message: String
    ) -> HeistPlanBuildError {
        HeistPlanBuildError.sourceCompilation(
            message: message,
            sourceSpan: token.sourceSpan
        )
    }

    mutating func bindScopedParameter(_ parameter: HeistParameter, localName: String) {
        guard let parameterName = parameter.name else { return }
        switch parameter {
        case .string:
            scope.bindString(localName: localName, referenceName: parameterName)
        case .accessibilityTarget:
            scope.bindTarget(localName: localName, referenceName: parameterName)
        case .none:
            break
        }
    }

    mutating func bindScopedReference(
        _ binding: HeistPlanSourceBinding,
        localName: String,
        referenceName: HeistReferenceName
    ) {
        switch binding {
        case .string:
            scope.bindString(localName: localName, referenceName: referenceName)
        case .target:
            scope.bindTarget(localName: localName, referenceName: referenceName)
        }
    }
}

struct HeistPlanSourceScope: Equatable {
    var stringRefs: [String: HeistReferenceName] = [:]
    var targetRefs: [String: HeistReferenceName] = [:]

    mutating func bindString(localName: String, referenceName: HeistReferenceName) {
        stringRefs[localName] = referenceName
    }

    mutating func bindTarget(localName: String, referenceName: HeistReferenceName) {
        targetRefs[localName] = referenceName
    }

    func stringReference(for localName: String) -> HeistReferenceName? {
        stringRefs[localName]
    }

    func targetReference(for localName: String) -> HeistReferenceName? {
        targetRefs[localName]
    }
}

enum HeistPlanSourceBinding {
    case string
    case target
}
