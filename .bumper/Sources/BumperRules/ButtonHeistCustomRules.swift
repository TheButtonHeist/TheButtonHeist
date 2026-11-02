import BumperBowlingCore
import SwiftSyntax
import SwiftLintFramework

private let plansScope = RuleScope.under("ButtonHeist/Sources/ThePlans")
private let privateStoragePath: String =
    "ButtonHeist/Sources/TheButtonHeist/Storage/PrivateStorage.swift"
private let commandArgumentsPath: String =
    "ButtonHeist/Sources/TheButtonHeist/TheFence/TheFence+CommandArguments.swift"
private let runtimeConfigurationResolutionPath: String =
    "ButtonHeist/Sources/TheInsideJob/Lifecycle/InsideJobRuntimeConfiguration+Resolution.swift"

public enum AnyBoundaryRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.any_boundary",
        summary: "Production Any is limited to exact Foundation and Objective-C bridges."
    )

    public static var body: SyntaxCheck {
        Rules.files { file in
            SyntaxQuery<IdentifierTypeSyntax>()
                .filter { match in
                    match.node.name.text == "Any"
                        && !isAllowedAnyBoundary(match.node, path: file.path)
                }
                .matches(in: file)
                .map { match in
                    match.failure(
                        message: "Any outside a named system boundary. Normalize it into a typed value at the boundary."
                    )
                }
        }
    }
}

public enum HeistContentOpacityRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.heist_content_opacity",
        summary: "HeistContent remains an opaque public authoring fragment."
    )

    public static var body: SyntaxCheck {
        Rules.files { file in
            SyntaxQuery<DeclSyntax>()
                .within(plansScope)
                .filter { $0.node.lexicalPlacement != .local }
                .filter { match in
                    match.node.enclosingNominalNames.first == "HeistContent"
                        && contractAccessIntent(match.node) >= .public
                }
                .matches(in: file)
                .map { match in
                    match.failure(
                        message: "HeistContent exposes a public member. Keep opaque fragment members below public access."
                    )
                }
        }
    }
}

public enum PlanElseOwnershipRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.plan_else_ownership",
        summary: "Only wait and conditional DSL fragments expose an else branch."
    )

    public static var body: SyntaxCheck {
        Rules.files { file in
            functions()
                .within(plansScope)
                .filter { match in
                    functionName(match.node) == "else"
                        && contractAccessIntent(match.node) >= .public
                        && !isAllowedPlanElseOwner(match.node)
                }
                .matches(in: file)
                .map { match in
                    match.failure(
                        message: "unsupported DSL else branch. Only WaitFor and IfContent expose func `else`."
                    )
                }
        }
    }
}

public enum ExportedTupleContractRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.exported_tuple_contract",
        summary: "Exported declarations use named contract types, not multi-value tuples."
    )

    public static var body: SyntaxCheck {
        Rules.each(SyntaxQuery<DeclSyntax>().filter { $0.node.lexicalPlacement != .local }) { declaration in
            let tuples = declaration.node.contractTypes.flatMap { $0.descendants(of: TupleTypeSyntax.self) }
                .filter { $0.elements.count > 1 }
            guard !tuples.isEmpty else { return [] }
            switch declaration.node.effectiveAccess {
            case .resolved(let access) where access >= .package:
                let observed = tuples.map(\.trimmedDescription).joined(separator: ", ")
                return [declaration.failure(message: "exported declaration contains a tuple contract: \(observed). Use a named Swift type.")]
            case .unresolved where contractAccessIntent(declaration.node) >= .package:
                return [declaration.failure(message: "Tuple contract access is unresolved. Use a named Swift type or keep the target declaration in this file.")]
            default:
                return []
            }
        }
    }
}

// For unresolved targets, enforce written export intent without claiming compiler visibility.
private func contractAccessIntent(_ node: some DeclSyntaxProtocol) -> AccessControlLevel {
    switch node.effectiveAccess {
    case .resolved(let access): return access
    case .unresolved:
        let owner = node.ancestors.first { $0.isProtocol(DeclGroupSyntax.self) }?.as(DeclSyntax.self)
        return node.explicitAccess ?? owner?.explicitAccess ?? .internal
    }
}

private func isAllowedAnyBoundary(
    _ node: IdentifierTypeSyntax,
    path: String
) -> Bool {
    if path == privateStoragePath,
        node.ancestors.contains(where: { ancestor in
            ancestor.as(TypeAliasDeclSyntax.self)?.name.text == "FoundationFileAttributeDictionary"
        })
    {
        return true
    }

    let context = node
    if path == commandArgumentsPath,
        context.enclosingFunctionName == "expectedDescription",
        node.parent?.as(MetatypeTypeSyntax.self)?.metatypeSpecifier.text == "Type"
    {
        return context.enclosingNominalNames.contains("HeistValuePayloadDecoder")
    }
    return path == runtimeConfigurationResolutionPath
        && context.enclosingFunctionName == "decodeFoundationInfoPlistValue"
}

private func functionName(_ node: FunctionDeclSyntax) -> String {
    let name = node.name.text
    if name.first == "`", name.last == "`" {
        return String(name.dropFirst().dropLast())
    }
    return name
}

private func isAllowedPlanElseOwner(_ node: FunctionDeclSyntax) -> Bool {
    let owners = node.enclosingNominalNames
    return owners == ["WaitFor"] || owners == ["IfContent"]
}
