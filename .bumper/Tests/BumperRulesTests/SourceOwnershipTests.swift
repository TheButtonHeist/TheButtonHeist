import BumperBowlingCore
import BumperBowlingTestSupport
import Testing

@testable import BumperRules

@Suite("Architecture boundaries")
struct SourceOwnershipTests {
    @Test
    func includedSwiftFilesRequireAnOwner() throws {
        let harness = RuleTestHarness(SourceOwnershipRule.self)
        let owned = try harness.evaluate([.swift("ButtonHeist/Sources/ThePlans/Owned.swift", source: "")])
        let unowned = try harness.evaluate([.swift("ButtonHeist/Sources/New/Unowned.swift", source: "")])
        #expect(owned.isEmpty)
        #expect(unowned.count == 1)
        #expect(unowned.first?.ruleIdentifier == "buttonheist.source_ownership")
    }

    @Test
    func componentPathsDoNotOverlapAndDependenciesStayAcyclic() {
        let components = ButtonHeistComponent.allCases
        for component in components {
            for path in component.paths {
                #expect(ButtonHeistComponent.owners(of: path) == [component])
            }
            #expect(!hasCycle(from: component, visited: []))
        }
    }

    private func hasCycle(from component: ButtonHeistComponent, visited: Set<ButtonHeistComponent>) -> Bool {
        if visited.contains(component) { return true }
        return component.dependencies.contains { hasCycle(from: $0, visited: visited.union([component])) }
    }

    @Test
    func internalImportsFollowDependencyDirection() throws {
        let allowed = try evaluateButtonHeistRules(path: "ButtonHeist/Sources/TheScore/Allowed.swift", source: "import ThePlans")
        let denied = try evaluateButtonHeistRules(path: "ButtonHeist/Sources/ThePlans/Denied.swift", source: "import TheScore")
        let sameOwner = try evaluateButtonHeistRules(path: "ButtonHeist/Sources/TheInsideJob/Local.swift", source: "import ThePlant")
        #expect(allowed.isEmpty)
        #expect(sameOwner.isEmpty)
        #expect(denied.count == 1)
        #expect(denied.first?.ruleIdentifier == "buttonheist.component_boundary")
    }

    @Test
    func platformImportsPreserveEveryComponentBoundary() throws {
        let forbiddenImports: [(ButtonHeistComponent, [String])] = [
            (
                .plans,
                [
                    "UIKit", "SwiftUI", "ObjectiveC.runtime", "AccessibilitySnapshotParser", "CoreData", "SwiftData", "XCTest", "Testing", "ArgumentParser",
                    "MCP",
                ]
            ),
            (.score, ["UIKit", "ObjectiveC", "AccessibilitySnapshotCore", "CoreData", "Testing"]),
            (.client, ["UIKit", "ObjectiveC", "AccessibilitySnapshotPreviews"]),
            (.support, ["UIKit", "ObjectiveC", "AccessibilitySnapshotParser"]),
            (.testing, ["UIKit", "ObjectiveC", "AccessibilitySnapshotParser"]),
            (.cli, ["UIKit", "ObjectiveC", "AccessibilitySnapshotParser"]),
            (.mcp, ["UIKit", "ObjectiveC", "AccessibilitySnapshotParser"]),
            (.demo, ["ObjectiveC", "AccessibilitySnapshotParser"]),
        ]
        for (component, modules) in forbiddenImports {
            for module in modules {
                let violations = try RuleTestHarness(PlatformImportRule.self).evaluate([
                    .swift(component.paths[0] + "/Boundary.swift", source: "import \(module)")
                ])
                #expect(violations.count == 1, "\(component) must reject \(module)")
            }
        }
        for (component, modules) in [
            (ButtonHeistComponent.embeddedRuntime, ["UIKit", "SwiftUI", "ObjectiveC.runtime", "AccessibilitySnapshotParser"]),
            (.demo, ["UIKit", "SwiftUI"]), (.score, ["Foundation", "AccessibilitySnapshotModel"]),
        ] {
            let violations = try RuleTestHarness(PlatformImportRule.self).evaluate([
                .swift(component.paths[0] + "/Boundary.swift", source: modules.map { "import \($0)" }.joined(separator: "\n"))
            ])
            #expect(violations.isEmpty)
        }
    }

    @Test
    func concurrencyEscapeHatchesRemainForbidden() throws {
        let harness = RuleTestHarness(CheckedConcurrencyRule.self)
        let denied = try harness.evaluate([
            .swift(
                "Sources/Unsafe.swift",
                source: """
                    @preconcurrency import Foundation
                    struct Unsafe { nonisolated(unsafe) static var state = 0 }
                    """)
        ])
        let allowed = try harness.evaluate([
            .swift(
                "Sources/Checked.swift",
                source: """
                    @MainActor struct Checked { nonisolated static let state = 0 }
                    """)
        ])
        #expect(denied.count == 2)
        #expect(allowed.isEmpty)
    }
}
