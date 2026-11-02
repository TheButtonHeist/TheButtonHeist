import BumperBowlingCore
import SwiftSyntax

/// Require explicit isolation on callback contracts.
public enum CallbackIsolationRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.callback_isolation",
        summary: "Optional function slots and onFoo callbacks declare actor or Sendable isolation."
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
                let isolated = type.attributes.contains { attribute in
                    if ["Sendable", "MainActor", "Swift.MainActor", "ButtonHeistActor", "ButtonHeist.ButtonHeistActor", "convention"]
                        .contains(attribute.attributeName.trimmedDescription) { return true }
                    guard case .resolved(let actor) = declaration.file.resolveType(attribute.attributeName) else { return false }
                    return actor.isGlobalActor
                }
                return isolated ? nil : declaration.file.failure(
                    at: binding,
                    message: "callback without explicit isolation: \(name). Declare a known global actor or @Sendable."
                )
            }
        }
    }
}
