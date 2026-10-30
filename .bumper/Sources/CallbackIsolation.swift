import BumperBowlingCore
import SwiftSyntax

let callbackIsolationRule = Rules.files(
    "buttonheist.callback_isolation",
    severity: .error,
    summary: "Optional function slots and onFoo callbacks declare actor or Sendable isolation."
) { file in
    let declarations = SyntaxQuery<DeclSyntax>()
        .lexically(within: SyntaxScope.fileScope.union(.typeMembers)).matches(in: file)
    let aliases = declarations.compactMap { $0.node.as(TypeAliasDeclSyntax.self) }
    let nominalPaths = Set(declarations.compactMap { match -> [String]? in
        guard match.node.asProtocol(DeclGroupSyntax.self) != nil,
              let name = match.node.asProtocol(NamedDeclSyntax.self)?.name.text else { return nil }
        return lexicalTypePath(match.node) + [name]
    })
    let declaredActors = declarations.flatMap { match -> [String] in
        guard let declaration = match.node.asProtocol(DeclGroupSyntax.self),
              declaration.attributes.contains(where: {
                  $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "globalActor"
              }), let name = match.node.asProtocol(NamedDeclSyntax.self)?.name.text else { return [] }
        return [name, (lexicalTypePath(match.node) + [name]).joined(separator: ".")]
    }
    let actors = Set(["MainActor", "Swift.MainActor", "ButtonHeistActor", "ButtonHeist.ButtonHeistActor"] + declaredActors)
    return variables()
        .lexically(within: SyntaxScope.fileScope.union(.typeMembers))
        .matches(in: file)
        .flatMap { match in
            match.node.bindings.compactMap { binding -> RuleFailure? in
                guard let type = binding.typeAnnotation?.type,
                      let callback = resolveCallbackType(
                          type, scope: lexicalTypePath(binding), aliases: aliases, nominalPaths: nominalPaths
                      ),
                      callback.isOptional || isCallbackName(binding.bumper.identifierName),
                      callback.attributes.isDisjoint(with: actors.union(["Sendable", "convention"])) else {
                    return nil
                }
                return file.failure(
                    at: binding,
                    message: "callback without explicit isolation: \(binding.bumper.identifierName ?? "binding")",
                    evidence: ViolationEvidence(
                        observed: binding.trimmedDescription,
                        expectation: "callback slots declare a known global actor or @Sendable"
                    )
                )
            }
        }
}

private func lexicalTypePath(_ node: some SyntaxProtocol) -> [String] {
    node.bumper.lexicalContext.enclosingNominalNames.reversed().flatMap { $0.split(separator: ".").map(String.init) }
}

private struct CallbackType {
    var attributes: Set<String>
    var isOptional: Bool = false
}

private func isCallbackName(_ name: String?) -> Bool {
    guard let name else { return false }
    return name.hasPrefix("on") && name.dropFirst(2).first?.isUppercase == true
}

// shortcut: resolve explicit aliases in this file only, replace with Bumper's lexical facts when available (#55).
private func resolveCallbackType(
    _ type: TypeSyntax,
    scope: [String],
    aliases: [TypeAliasDeclSyntax],
    nominalPaths: Set<[String]>,
    visited: Set<SyntaxIdentifier> = []
) -> CallbackType? {
    if type.is(FunctionTypeSyntax.self) { return CallbackType(attributes: []) }
    if let attributed = type.as(AttributedTypeSyntax.self) {
        return resolveCallbackType(attributed.baseType, scope: scope, aliases: aliases, nominalPaths: nominalPaths, visited: visited).map {
            var result = $0
            result.attributes.formUnion(attributed.attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription })
            return result
        }
    }
    if let optional = type.as(OptionalTypeSyntax.self) {
        return resolveCallbackType(optional.wrappedType, scope: scope, aliases: aliases, nominalPaths: nominalPaths, visited: visited).map {
            var result = $0
            result.isOptional = true
            return result
        }
    }
    if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        return resolveCallbackType(optional.wrappedType, scope: scope, aliases: aliases, nominalPaths: nominalPaths, visited: visited).map {
            var result = $0
            result.isOptional = true
            return result
        }
    }
    if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1, let element = tuple.elements.first {
        return resolveCallbackType(element.type, scope: scope, aliases: aliases, nominalPaths: nominalPaths, visited: visited)
    }
    let name: String
    if let identifier = type.as(IdentifierTypeSyntax.self) {
        if identifier.name.text == "Optional", let argument = identifier.genericArgumentClause?.arguments.first,
           case .type(let wrapped) = argument.argument {
            return resolveCallbackType(wrapped, scope: scope, aliases: aliases, nominalPaths: nominalPaths, visited: visited).map {
                var result = $0
                result.isOptional = true
                return result
            }
        }
        name = identifier.name.text
    } else if let member = type.as(MemberTypeSyntax.self) {
        if member.baseType.trimmedDescription == "Swift", member.name.text == "Optional",
           let argument = member.genericArgumentClause?.arguments.first, case .type(let wrapped) = argument.argument {
            return resolveCallbackType(wrapped, scope: scope, aliases: aliases, nominalPaths: nominalPaths, visited: visited).map {
                var result = $0
                result.isOptional = true
                return result
            }
        }
        name = member.baseType.trimmedDescription + "." + member.name.text
    } else {
        return nil
    }
    let reference = name.split(separator: ".").map(String.init)
    if type.ancestors.contains(where: { ancestor in
        ancestor.asProtocol(WithGenericParametersSyntax.self)?.genericParameterClause?.parameters.contains {
            $0.name.text == reference.first
        } == true
    }) { return nil }
    for depth in stride(from: scope.count, through: 0, by: -1) {
        let path = Array(scope.prefix(depth)) + reference
        if nominalPaths.contains(path) { return nil }
        guard let alias = aliases.first(where: { lexicalTypePath($0) + [$0.name.text] == path }) else { continue }
        guard !visited.contains(alias.id) else { return nil }
        return resolveCallbackType(alias.initializer.value, scope: lexicalTypePath(alias), aliases: aliases, nominalPaths: nominalPaths,
                                  visited: visited.union([alias.id]))
    }
    return nil
}
