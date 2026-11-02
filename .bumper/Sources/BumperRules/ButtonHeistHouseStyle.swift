import BumperBowlingCore
import SwiftSyntax

/// Repository ownership and allowed internal import direction.
enum ButtonHeistComponent: String, CaseIterable, Sendable {
    case plans, score, embeddedRuntime, client, support, testing, cli, mcp, demo

    var paths: [String] {
        switch self {
        case .plans: ["ButtonHeist/Sources/ThePlans"]
        case .score: ["ButtonHeist/Sources/TheScore"]
        case .embeddedRuntime: ["ButtonHeist/Sources/TheInsideJob", "ButtonHeist/Sources/ThePlant"]
        case .client: ["ButtonHeist/Sources/TheButtonHeist"]
        case .support: ["ButtonHeist/Sources/ButtonHeistSupport"]
        case .testing: ["ButtonHeist/Sources/ButtonHeistTesting"]
        case .cli: ["ButtonHeistCLI/Sources"]
        case .mcp: ["ButtonHeistMCP/Sources"]
        case .demo: ["TestApp/Sources"]
        }
    }

    var scope: RuleScope {
        paths.dropFirst().reduce(.under(paths[0])) { $0.union(.under($1)) }
    }

    var modules: Set<String> {
        switch self {
        case .plans: ["ThePlans"]
        case .score: ["TheScore"]
        case .embeddedRuntime: ["TheInsideJob", "ThePlant"]
        case .client: ["ButtonHeist"]
        case .support: ["ButtonHeistSupport"]
        case .testing: ["ButtonHeistTesting"]
        case .cli: ["ButtonHeistCLIExe"]
        case .mcp: ["ButtonHeistMCP"]
        case .demo: []
        }
    }

    var dependencies: Set<Self> {
        switch self {
        case .plans, .support: []
        case .score: [.plans]
        case .embeddedRuntime, .client: [.support, .plans, .score]
        case .testing: [.embeddedRuntime, .plans]
        case .cli: [.client, .plans, .score]
        case .mcp: [.client, .score]
        case .demo: [.plans, .score, .embeddedRuntime]
        }
    }

    static func owners(of path: String) -> [Self] {
        allCases.filter { component in
            component.paths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }
}

public enum SourceOwnershipRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.source_ownership",
        summary: "Every included Swift file has exactly one component owner."
    )
    public static var body: SyntaxCheck {
        Rules.sourceOwnership(ButtonHeistComponent.allCases.map(\.scope))
    }
}

public enum ComponentBoundaryRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.component_boundary",
        summary: "Internal imports follow the declared component dependencies."
    )
    public static var body: SyntaxCheck {
        for owner in ButtonHeistComponent.allCases {
            let forbiddenModules = ButtonHeistComponent.allCases
                .filter { $0 != owner && !owner.dependencies.contains($0) }
                .reduce(into: Set<String>()) { $0.formUnion($1.modules) }
            Rules.forbiddenImports(forbiddenModules, scope: owner.scope)
        }
    }
}

public enum PlatformImportRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.platform_import",
        summary: "UI, persistence, test, and SPI imports stay at their declared boundaries."
    )
    public static var body: SyntaxCheck {
        let runtime = ButtonHeistComponent.embeddedRuntime.scope
        let demo = ButtonHeistComponent.demo.scope
        let portable = ButtonHeistComponent.plans.scope.union(ButtonHeistComponent.score.scope)
        Rules.importOwnership(["UIKit", "SwiftUI"], allowed: runtime.union(demo))
        Rules.importOwnership(
            ["ObjectiveC", "AccessibilitySnapshotCore", "AccessibilitySnapshotParser", "AccessibilitySnapshotPreviews"],
            allowed: runtime
        )
        Rules.forbiddenImports(["CoreData", "SwiftData", "XCTest", "Testing"], scope: portable)
        Rules.forbiddenImports(["ArgumentParser", "MCP"], scope: ButtonHeistComponent.plans.scope)
    }
}

public enum CheckedConcurrencyRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.checked_concurrency",
        summary: "Production code uses checked actor isolation and Sendability."
    )
    public static var body: SyntaxCheck {
        Rules.forbid(SyntaxQuery<AttributeSyntax>().filter { $0.node.attributeName.trimmedDescription == "preconcurrency" }) { _ in
            "@preconcurrency suppresses checking. Declare checked isolation instead."
        }
        Rules.forbid(
            SyntaxQuery<DeclModifierSyntax>().filter {
                $0.node.name.text == "nonisolated" && $0.node.detail?.detail.text == "unsafe"
            }
        ) { _ in
            "nonisolated(unsafe) suppresses checking. Model the state with checked concurrency."
        }
    }
}

extension SyntaxProtocol {
    var enclosingFunctionName: String? {
        ancestors.compactMap { $0.as(FunctionDeclSyntax.self)?.name.text }.first
    }
}
