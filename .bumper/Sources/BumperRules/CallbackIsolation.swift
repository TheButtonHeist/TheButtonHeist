import BumperBowlingCore
import SwiftSyntax

private func isIsolatedCallback(_ type: LexicalType, in file: SourceFileContext) -> Bool {
    type.attributes.contains { attribute in
        if ["Sendable", "MainActor", "Swift.MainActor", "ButtonHeistActor", "ButtonHeist.ButtonHeistActor", "convention"]
            .contains(attribute.attributeName.trimmedDescription) { return true }
        guard case .resolved(let actor) = file.resolveType(attribute.attributeName) else { return false }
        return actor.isGlobalActor
    }
}

/// Require explicit isolation on callback contracts.
public enum CallbackIsolationRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.callback_isolation",
        summary: "Optional function slots, onFoo callbacks, and exported callback aliases declare isolation."
    )

    public static var body: SyntaxCheck {
        Rules.each(variables().filter { $0.node.lexicalPlacement != .local }) { declaration in
            declaration.node.bindings.compactMap { binding in
                guard let syntax = binding.typeAnnotation?.type,
                    case .resolved(let type) = declaration.file.resolveType(syntax), type.function != nil
                else { return nil }
                let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text ?? ""
                let callbackName = name.hasPrefix("on") && name.dropFirst(2).first?.isUppercase == true
                guard type.isOptional || callbackName else { return nil }
                let isolated = isIsolatedCallback(type, in: declaration.file)
                return isolated ? nil : declaration.file.failure(
                    at: binding,
                    message: "callback without explicit isolation: \(name). Declare a known global actor or @Sendable."
                )
            }
        }
        Rules.each(SyntaxQuery<TypeAliasDeclSyntax>().filter {
            $0.node.lexicalPlacement != .local && contractAccessIntent($0.node) >= .package
        }) { declaration in
            guard case .resolved(let type) = declaration.file.resolveType(declaration.node.initializer.value),
                type.function != nil else { return [] }
            let name = declaration.node.name.text.filter { $0 != "`" }
            let callbackName = ["Callback", "Handler", "Completion"].contains { name.hasSuffix($0) }
            guard type.isOptional || callbackName, !isIsolatedCallback(type, in: declaration.file) else { return [] }
            return [declaration.file.failure(
                at: declaration.node.name,
                message: "callback alias without explicit isolation: \(name). Declare a known global actor or @Sendable."
            )]
        }
    }
}
