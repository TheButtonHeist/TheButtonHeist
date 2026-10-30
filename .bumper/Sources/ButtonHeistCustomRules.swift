import BumperBowlingCore
import SwiftSyntax

let buttonHeistRules = RuleSet {
    anyBoundaryRule
    transportImportRules
    callbackIsolationRule
    heistContentOpacityRule
    planElseOwnershipRule
    exportedTupleContractRule
}

private let plansScope = RuleScope.component(ButtonHeistComponent.plans)
private let privateStoragePath: RelativeFilePath =
    "ButtonHeist/Sources/TheButtonHeist/Storage/PrivateStorage.swift"
private let commandArgumentsPath: RelativeFilePath =
    "ButtonHeist/Sources/TheButtonHeist/TheFence/TheFence+CommandArguments.swift"
private let runtimeConfigurationResolutionPath: RelativeFilePath =
    "ButtonHeist/Sources/TheInsideJob/Lifecycle/InsideJobRuntimeConfiguration+Resolution.swift"

private let anyBoundaryRule = Rules.files(
    "buttonheist.any_boundary",
    severity: .error,
    summary: "Production Any is limited to exact Foundation and Objective-C bridges."
) { file in
    SyntaxQuery<IdentifierTypeSyntax>()
        .filter { match in
            match.node.name.text == "Any"
                && !isAllowedAnyBoundary(match.node, path: file.path)
        }
        .matches(in: file)
        .map { match in
            match.failure(
                message: "Any outside a named system boundary",
                evidence: ViolationEvidence(
                    observed: match.node.bumper.lexicalContext.enclosingFunctionName
                        ?? match.node.trimmedDescription,
                    expectation: "normalize Any into a typed Button Heist value at the boundary"
                )
            )
        }
}

private let heistContentOpacityRule = Rules.files(
    "buttonheist.heist_content_opacity",
    severity: .error,
    summary: "HeistContent remains an opaque public authoring fragment."
) { file in
    SyntaxQuery<DeclSyntax>()
        .within(plansScope)
        .lexically(within: contractDeclarationScope)
        .filter { match in
            match.node.bumper.lexicalContext.enclosingNominalNames.first == "HeistContent"
                && effectiveAccess(of: match.node).isPublic
        }
        .matches(in: file)
        .map { match in
            match.failure(
                message: "HeistContent exposes a public member.",
                evidence: ViolationEvidence(
                    observed: match.node.trimmedDescription,
                    expectation: "keep the opaque authoring fragment's members below public access"
                )
            )
        }
}

private let planElseOwnershipRule = Rules.files(
    "buttonheist.plan_else_ownership",
    severity: .error,
    summary: "Only wait and conditional DSL fragments expose an else branch."
) { file in
    functions()
        .within(plansScope)
        .filter { match in
            functionName(match.node) == "else"
                && effectiveAccess(of: match.node).isPublic
                && !isAllowedPlanElseOwner(match.node)
        }
        .matches(in: file)
        .map { match in
            match.failure(
                message: "unsupported DSL else branch",
                evidence: ViolationEvidence(
                    observed: match.node.bumper.lexicalContext.enclosingNominalNames.first
                        ?? match.node.trimmedDescription,
                    expectation: "only WaitFor and IfContent expose func `else`"
                )
            )
        }
}

private let exportedTupleContractRule = Rules.files(
    "buttonheist.exported_tuple_contract",
    severity: .error,
    summary: "Exported declarations use named contract types, not multi-value tuples."
) { file in
    declarationContracts(in: file).compactMap { contract in
        guard contract.effectiveAccess.isExported,
              let observed = contract.observedTupleContract else {
            return nil
        }
        return file.failure(
            at: contract.node,
            message: "exported \(contract.kind.rawValue) contains a tuple contract",
            evidence: ViolationEvidence(
                observed: observed,
                expectation: "use named Swift types for public, open, or package API"
            )
        )
    }
}

private struct DeclarationContract {
    let node: Syntax
    let kind: Kind
    let effectiveAccess: ContractAccess
    let types: [TypeSyntax]

    enum Kind: String {
        case function
        case property
        case subscriptDeclaration = "subscript"
        case initializer
        case typeAlias = "typealias"
        case enumCase = "enum case"
        case associatedType = "associatedtype"
    }

    var observedTupleContract: String? {
        let tuples = types.flatMap { type in
            type.descendants(of: TupleTypeSyntax.self).filter { tuple in
                tuple.elements.count > 1
            }
        }
        guard !tuples.isEmpty else {
            return nil
        }
        return tuples.map(\.trimmedDescription).joined(separator: ", ")
    }
}

private enum ContractAccess: Int, Comparable {
    case `private`
    case `fileprivate`
    case `internal`
    case `package`
    case `public`
    case open

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var isExported: Bool {
        self >= .package
    }

    var isPublic: Bool {
        self >= .public
    }
}

private let contractDeclarationScope = SyntaxScope.fileScope.union(.typeMembers)

private func declarationContracts(in file: SourceFileContext) -> [DeclarationContract] {
    SyntaxQuery<DeclSyntax>()
        .lexically(within: contractDeclarationScope)
        .matches(in: file)
        .flatMap { match -> [DeclarationContract] in
            let node = match.node
            let access = effectiveAccess(of: node)
            let kind: DeclarationContract.Kind
            let types: [TypeSyntax]
            if let function = node.as(FunctionDeclSyntax.self) {
                kind = .function
                types = functionContractTypes(function)
            } else if let initializer = node.as(InitializerDeclSyntax.self) {
                kind = .initializer
                types = initializer.signature.parameterClause.parameters.map(\.type)
            } else if let property = node.as(VariableDeclSyntax.self) {
                return property.bindings.compactMap { binding in
                    binding.typeAnnotation.map { annotation in
                        DeclarationContract(node: Syntax(binding), kind: .property,
                                            effectiveAccess: access, types: [annotation.type])
                    }
                }
            } else if let declaration = node.as(SubscriptDeclSyntax.self) {
                kind = .subscriptDeclaration
                types = subscriptContractTypes(declaration)
            } else if let alias = node.as(TypeAliasDeclSyntax.self) {
                kind = .typeAlias
                types = [alias.initializer.value]
            } else if let declaration = node.as(EnumCaseDeclSyntax.self) {
                kind = .enumCase
                types = declaration.elements.flatMap { element in
                    element.parameterClause?.parameters.map(\.type) ?? []
                }
            } else if let declaration = node.as(AssociatedTypeDeclSyntax.self) {
                kind = .associatedType
                types = [declaration.initializer?.value].compactMap { $0 }
            } else {
                return []
            }
            return [DeclarationContract(node: Syntax(node), kind: kind,
                                        effectiveAccess: access, types: types)]
        }
}

private func functionContractTypes(_ node: FunctionDeclSyntax) -> [TypeSyntax] {
    let parameterTypes = node.signature.parameterClause.parameters.map(\.type)
    return parameterTypes + [node.signature.returnClause?.type].compactMap { $0 }
}

private func subscriptContractTypes(_ node: SubscriptDeclSyntax) -> [TypeSyntax] {
    node.parameterClause.parameters.map(\.type) + [node.returnClause.type]
}

private func effectiveAccess(of node: some SyntaxProtocol) -> ContractAccess {
    let modifiers = node.asProtocol(WithModifiersSyntax.self)?.modifiers ?? []
    let declared = explicitAccess(modifiers) ?? inheritedDefaultAccess(of: node) ?? .internal
    return node.ancestors.compactMap(accessCap).reduce(declared, min)
}

private func inheritedDefaultAccess(of node: some SyntaxProtocol) -> ContractAccess? {
    for ancestor in node.ancestors {
        if node.is(EnumCaseDeclSyntax.self), let declaration = ancestor.as(EnumDeclSyntax.self) {
            return effectiveAccess(of: declaration)
        }
        if let declaration = ancestor.as(ProtocolDeclSyntax.self) {
            return effectiveAccess(of: declaration)
        }
        if let declaration = ancestor.as(ExtensionDeclSyntax.self) {
            return explicitAccess(declaration.modifiers) ?? .internal
        }
        if nominalModifiers(ancestor) != nil {
            return .internal
        }
    }
    return nil
}

private func accessCap(_ ancestor: Syntax) -> ContractAccess? {
    if let declaration = ancestor.as(ExtensionDeclSyntax.self) {
        return explicitAccess(declaration.modifiers)
    }
    guard nominalModifiers(ancestor) != nil else {
        return nil
    }
    return effectiveAccess(of: ancestor)
}

private func nominalModifiers(_ node: Syntax) -> DeclModifierListSyntax? {
    node.asProtocol(DeclGroupSyntax.self)?.modifiers
}

private func explicitAccess(_ modifiers: DeclModifierListSyntax) -> ContractAccess? {
    for modifier in modifiers where modifier.detail == nil {
        switch modifier.name.text {
        case "private":
            return .private
        case "fileprivate":
            return .fileprivate
        case "internal":
            return .internal
        case "package":
            return .package
        case "public":
            return .public
        case "open":
            return .open
        default:
            continue
        }
    }
    return nil
}

private func isAllowedAnyBoundary(
    _ node: IdentifierTypeSyntax,
    path: RelativeFilePath
) -> Bool {
    if path == privateStoragePath,
       node.ancestors.contains(where: { ancestor in
           ancestor.as(TypeAliasDeclSyntax.self)?.name.text == "FoundationFileAttributeDictionary"
       }) {
        return true
    }

    let context = node.bumper.lexicalContext
    if path == commandArgumentsPath,
       context.enclosingFunctionName == "expectedDescription",
       node.parent?.as(MetatypeTypeSyntax.self)?.metatypeSpecifier.text == "Type" {
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
    let owners = node.bumper.lexicalContext.enclosingNominalNames
    return owners == ["WaitFor"] || owners == ["IfContent"]
}
