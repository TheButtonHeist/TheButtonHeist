import BumperBowlingCore
import SwiftSyntax

private let reviewedUncheckedDeclarations: [String: Set<String>] = [
    "ButtonHeist/Sources/TheInsideJob/TheTripwire/AccessibilityNotificationObserver.swift": ["PendingAccessibilityNotificationCallback"],
    "ButtonHeist/Sources/TheInsideJob/Server/NetworkBoundary/SocketConnectionAdmission.swift": ["ConnectionAdmission"],
    "ButtonHeist/Sources/TheInsideJob/Server/NetworkBoundary/SocketListenerRuntime.swift": [
        "NetworkSocketListener", "PendingSocketConnections.OwnedConnection",
    ],
]
private let identifierResearchFiles: Set<String> = [
    "TestApp/Sources/ScrollSPIHarnessView.swift",
    "TestApp/Sources/TraitValidationView.swift",
    "TestApp/Sources/TraitProbeView.swift",
]

private func isReviewedUncheckedDeclaration(_ node: InheritedTypeSyntax, in file: SourceFileContext) -> Bool {
    guard let owner = node.ancestors.first(where: { $0.isProtocol(DeclGroupSyntax.self) }),
        !owner.ancestors.contains(where: {
            $0.is(CodeBlockSyntax.self) || $0.is(ClosureExprSyntax.self) || $0.is(AccessorBlockSyntax.self)
        }),
        let name = owner.asProtocol(NamedDeclSyntax.self)?.name.text ?? owner.as(ExtensionDeclSyntax.self)?.extendedType.trimmedDescription
    else { return false }
    let qualifiedName = (Array(owner.enclosingNominalNames.reversed()) + [name])
        .map { $0.filter { $0 != "`" } }.joined(separator: ".")
    return reviewedUncheckedDeclarations[file.path]?.contains(qualifiedName) == true
}

/// New unchecked conformances need a reviewed boundary exception.
public enum UncheckedSendableBoundaryRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.unchecked_sendable_boundary",
        summary: "Unchecked Sendable conformances belong to reviewed boundary declarations."
    )

    public static var body: SyntaxCheck {
        Rules.forbid(SyntaxQuery<InheritedTypeSyntax>().filter { match in
            match.node.type.as(AttributedTypeSyntax.self)?.attributes.contains {
                $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "unchecked"
            } == true && !isReviewedUncheckedDeclaration(match.node, in: match.file)
        }) { _ in
            "Unchecked Sendable conformance is outside the reviewed boundary declarations. "
                + "Use checked Sendable or review and register this exact declaration's safety argument."
        }
    }
}

/// Demo navigation uses user-facing accessibility properties.
public enum DemoAccessibilityIdentifierRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.demo_accessibility_identifier",
        summary: "Accessibility identifiers are reserved for the named research harnesses."
    )

    public static var body: SyntaxCheck {
        let scope = RuleScope.under("TestApp/Sources").excluding(.files(identifierResearchFiles))
        let repair = "Demo screens must use user-facing accessibility properties. "
            + "Replace accessibilityIdentifier with labels, values, traits, hints, or actions; research exceptions require an exact harness path."
        Rules.forbid(
            SyntaxQuery<DeclReferenceExprSyntax>()
                .filter { $0.node.baseName.text.filter { $0 != "`" } == "accessibilityIdentifier" },
            scope: scope
        ) { _ in repair }
        Rules.forbid(variables().filter { match in
            match.node.modifiers.contains { $0.name.text == "override" }
                && match.node.bindings.contains {
                    $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text.filter { $0 != "`" } == "accessibilityIdentifier"
                }
        }, scope: scope) { _ in repair }
    }
}
