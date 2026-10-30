import BumperBowlingCore

enum ButtonHeistComponent: String, ComponentKey {
    case plans
    case score
    case embeddedRuntime
    case client
    case support
    case testing
    case cli
    case mcp
    case demo
}

extension ComponentShape {
    static let buttonHeistCheckedConcurrency = ComponentShape {
        DoesNot(
            ContainSyntaxNode(
                SyntaxNodeMatcher(kind: .attribute, spelling: .exact("preconcurrency")),
                SyntaxNodeMatcher(kind: .declModifier, spelling: .contains("nonisolated(unsafe)"))
            ),
            severity: .error
        )
    }

    static let buttonHeistNoUIImports = ComponentShape {
        DoesNotUse(.uiKit, .swiftUI, severity: .error)
    }

    static let buttonHeistNoObjectiveCImports = ComponentShape {
        DoesNotUse("ObjectiveC", "ObjectiveC.runtime", severity: .error)
    }

    static let buttonHeistNoAccessibilityParserImports = ComponentShape {
        DoesNotUse(
            "AccessibilitySnapshotCore",
            "AccessibilitySnapshotParser",
            "AccessibilitySnapshotPreviews",
            severity: .error
        )
    }

    static let buttonHeistPlansBoundary = ComponentShape {
        DoesNotUse(.persistence, .testing, severity: .error)
        DoesNotUse("ArgumentParser", "MCP", severity: .error)
    }

    static let buttonHeistScoreBoundary = ComponentShape {
        DoesNotUse(.persistence, .testing, severity: .error)
    }
}
