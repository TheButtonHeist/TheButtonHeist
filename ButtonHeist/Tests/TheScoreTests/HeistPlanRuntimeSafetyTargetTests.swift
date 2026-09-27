import Foundation
import Testing
@_spi(ButtonHeistInternals) import ThePlans
@testable import TheScore

private let nonDurableHeistActionRepairHint =
    "Use a direct client command for debug/session actions, or replace " +
    "this with a canonical durable DSL action."

private func expectNonDurableHeistActionFailure(
    _ diagnostics: [HeistBuildDiagnostic],
    observed: String,
    path: String = "$.body[0].action.command"
) {
    #expect(diagnostics.contains {
        $0.path == path
            && $0.message == "durable heist action; observed \(observed)"
            && $0.hint == nonDurableHeistActionRepairHint
    }, "\(diagnostics)")
}

@Test
func runtimeSafetyRejectsInvalidRefs() throws {
    let tooLong = String(repeating: "a", count: HeistPlanRuntimeSafetyLimits.standard.maxParameterBytes + 1)
    let cases: [(String, () throws -> HeistPlan, String)] = [
        (
            "unknown target ref",
            { try HeistPlan(body: [.action(ActionStep(command: .activate(.ref("target"))))]) },
            "target ref must resolve"
        ),
        (
            "unknown text ref",
            { try HeistPlan(body: [.action(ActionStep(command: .typeText(
                reference: "item",
                target: .predicate(.label("Search"))
            )))]) },
            "text_ref must resolve"
        ),
        (
            "long target ref",
            {
                try HeistPlan(body: [.action(ActionStep(command: .activate(.ref(
                    HeistReferenceName(validating: tooLong)
                ))))])
            },
            "max parameter/ref length"
        ),
    ]

    for (label, operation, expected) in cases {
        let diagnostics = runtimeSafetyDiagnostics(operation)
        #expect(diagnostics.contains { $0.message.contains(expected) }, "\(label): \(diagnostics)")
    }
}

@Test
func heistPlanConstructionRejectsNonDurableActions() throws {
    let command = HeistActionCommand.rotor(
        selection: .index(0),
        target: .predicate(.label("Article")),
        direction: .next
    )
    let expectedFailure = try #require(command.durableHeistActionFailure)

    do {
        _ = try HeistPlan(body: [.action(ActionStep(command: command))])
        Issue.record("Expected non-durable action to fail plan construction")
    } catch let error as HeistPlanBuildError {
        expectNonDurableHeistActionFailure(error.diagnostics, observed: expectedFailure)
    } catch {
        Issue.record("Expected plan build error, got \(error)")
    }
}

@Test
func heistPlanJSONDecodeRejectsNonDurableActions() throws {
    let expectedFailure = try #require(
        HeistActionCommand
            .scroll(ScrollTarget(selection: .container("scrollable_0_0_40_50"), direction: .down))
            .durableHeistActionFailure
    )
    let json = """
    {
      "version": \(HeistPlan.currentVersion),
      "body": [
        {
          "type": "action",
          "action": {
            "command": {
              "type": "scroll",
              "payload": {
                "containerName": "scrollable_0_0_40_50",
                "direction": "down"
              }
            }
          }
        }
      ]
    }
    """

    do {
        _ = try JSONDecoder().decode(HeistPlan.self, from: Data(json.utf8))
        Issue.record("Expected non-durable JSON action to fail plan decode")
    } catch let error as HeistPlanBuildError {
        expectNonDurableHeistActionFailure(error.diagnostics, observed: expectedFailure)
    } catch {
        Issue.record("Expected plan build error, got \(error)")
    }
}

@Test
func runtimeSafetyRejectsRefsOutsideTheirLoopScope() throws {
    let diagnostics = runtimeSafetyDiagnostics {
        try HeistPlan(body: [
            .forEachString(try ForEachStringStep(
                values: ["Milk"],
                parameter: "item",
                body: [.warn(WarnStep(message: "inside string loop"))]
            )),
            .action(ActionStep(command: .typeText(
                reference: "item",
                target: .predicate(.label("Search"))
            ))),
            .forEachElement(try ForEachElementStep(
                matching: .label("Delete"),
                limit: 1,
                parameter: "target",
                body: [.warn(WarnStep(message: "inside element loop"))]
            )),
            .action(ActionStep(command: .activate(.ref("target")))),
        ])
    }

    #expect(diagnostics.contains {
        $0.path == "$.body[1].action.command.payload.text_ref"
            && $0.message.contains("text_ref must resolve in the current heist scope")
    })
    #expect(diagnostics.contains {
        $0.path == "$.body[3].action.command.payload.target"
            && $0.message.contains("target ref must resolve in the current heist scope")
    })
}

@Test
func runtimeSafetyRejectsStringRefThatLowersToInvalidCommandPayload() throws {
    let diagnostics = runtimeSafetyDiagnostics {
        try HeistPlan(body: [
            .forEachString(try ForEachStringStep(
                values: [""],
                parameter: "item",
                body: [
                    .action(ActionStep(command: .typeText(
                        reference: "item",
                        target: .predicate(.label("Search"))
                    ))),
                ]
            )),
        ])
    }

    #expect(diagnostics.contains { $0.message.contains("admissible action command") })
    #expect(diagnostics.contains { $0.message.contains("text to append must be non-empty") })
}

@Test
func runtimeSafetyRejectsEmptyBroadConcreteAccessibilityTargets() throws {
    let targets: [(String, AccessibilityTarget)] = [
        ("label exact", .label("")),
        ("label contains", .label(.contains(""))),
        ("label prefix", .label(.prefix(""))),
        ("label suffix", .label(.suffix(""))),
        ("identifier exact", .identifier("")),
        ("identifier contains", .identifier(.contains(""))),
        ("identifier prefix", .identifier(.prefix(""))),
        ("identifier suffix", .identifier(.suffix(""))),
        ("value exact", .value("")),
        ("value contains", .value(.contains(""))),
        ("value prefix", .value(.prefix(""))),
        ("value suffix", .value(.suffix(""))),
        ("hint exact", .hint("")),
        ("traits empty", .traits([])),
        ("actions empty", .actions([])),
        ("custom content empty", .customContent(CustomContentMatch())),
        ("rotors empty", .rotors([])),
    ]

    for (label, target) in targets {
        let diagnostics = runtimeSafetyDiagnostics {
            try HeistPlan(body: [.action(ActionStep(command: .activate(target)))])
        }

        #expect(
            diagnostics.contains { $0.message.contains("element predicate") },
            "\(label): \(diagnostics)"
        )
    }
}

@Test
func runtimeSafetyRejectsNegativeOrdinalsBeforeRuntimeUse() throws {
    let diagnostics = runtimeSafetyDiagnostics {
        try HeistPlan(body: [
            .action(ActionStep(command: .activate(.predicate(.label("Save"), ordinal: -1)))),
        ])
    }

    #expect(diagnostics.contains {
        $0.message.contains("ordinal must be non-negative")
            && $0.message.contains("observed -1")
    }, "\(diagnostics)")
}

@Test
func runtimeSafetyRejectsEmptyElementPredicatesBeforeRuntimeUse() throws {
    let diagnostics = runtimeSafetyDiagnostics {
        try HeistPlan(body: [
            .wait(WaitStep(predicate: .exists(.predicate(ElementPredicate())))),
        ])
    }

    #expect(diagnostics.contains {
        $0.message.contains("element predicate must not be empty")
            && $0.message.contains("AccessibilityTarget predicate requires")
    }, "\(diagnostics)")
}

private func runtimeSafetyDiagnostics(
    _ operation: () throws -> HeistPlan
) -> [HeistBuildDiagnostic] {
    do {
        _ = try operation()
        return []
    } catch let error as HeistPlanBuildError {
        return error.diagnostics
    } catch {
        Issue.record("Expected plan build error, got \(error)")
        return []
    }
}
