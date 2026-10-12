import Foundation
import Testing
@_spi(ButtonHeistInternals) import ThePlans
@testable import TheScore

@Test
func runtimeSafetyRejectsInvalidHeistDefinitionsAndInvocations() throws {
    let itemReference: HeistReferenceName = "item"
    let definition = try HeistPlan(
        name: "addToCart",
        parameter: .string(name: "item"),
        body: [.action(ActionStep(command: .activate(.predicate(
            ElementPredicate(label: .exact(itemReference))
        ))))]
    )
    let cases: [(() throws -> HeistPlan, String)] = [
        (
            {
                try HeistSourceParser.parse("""
                HeistPlan {
                    HeistDef<Void>("duplicate") { Warn("a") }
                    HeistDef<Void>("duplicate") { Warn("b") }
                    Warn("body")
                }
                """)
            },
            "duplicate heist definition names are not allowed"
        ),
        (
            {
                try HeistPlan(definitions: [definition], body: [
                    .invoke(HeistInvocationStep(
                        path: "missing",
                        argument: .string("Milk")
                    )),
                ])
            },
            "heist run path must resolve"
        ),
        (
            {
                try HeistPlan(definitions: [definition], body: [
                    .invoke(HeistInvocationStep(path: "addToCart", argument: .none)),
                ])
            },
            "heist run argument type must match"
        ),
    ]

    for (operation, expectedContract) in cases {
        let diagnostics = runtimeSafetyDiagnostics(operation)
        #expect(diagnostics.contains {
            $0.message.contains(expectedContract)
        }, "\(expectedContract): \(diagnostics)")
    }
}

@Test
func decodedHeistArgumentsRejectStringArrayShape() throws {
    let payloads = [
        #"{"type":"string","values":["Milk","Bread"]}"#,
        #"{"type":"string","values":["Milk"]}"#,
        #"{"type":"strings","values":["Milk"]}"#,
    ]

    for payload in payloads {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(HeistArgument.self, from: Data(payload.utf8))
        }
    }
}

@Test
func admissionDecodingRejectsEmptyPredicates() throws {
    let json = """
    {
      "version": \(HeistPlan.currentVersion),
      "body": [
        {
          "type": "for_each_element",
          "for_each_element": {
            "matching": {},
            "limit": 1,
            "parameter": "target",
            "body": [
              { "type": "warn", "warn": { "message": "body" } }
            ]
          }
        }
      ]
    }
    """

    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(HeistPlan.self, from: Data(json.utf8))
    }
}

@Test
func admissionDecodingRejectsUnsupportedAndInvalidCommands() throws {
    let unsupportedCommand = """
    {
      "version": \(HeistPlan.currentVersion),
      "body": [
        {
          "type": "action",
          "action": {
            "command": {
              "type": "teleport",
              "payload": {}
            }
          }
        }
      ]
    }
    """
    let missingPayload = """
    {
      "version": \(HeistPlan.currentVersion),
      "body": [
        {
          "type": "action",
          "action": {
            "command": {
              "type": "activate"
            }
          }
        }
      ]
    }
    """

    let cases = [
        (unsupportedCommand, "is not a heist action command"),
        (missingPayload, "Missing payload for heist action command type activate"),
    ]

    for (payload, expected) in cases {
        do {
            _ = try JSONDecoder().decode(HeistPlan.self, from: Data(payload.utf8))
            Issue.record("Expected admission decoding to fail")
        } catch {
            #expect("\(error)".contains(expected), "\(error)")
        }
    }
}

@Test
func runtimeSafetyRejectsDefinitionSelfInvocationOutsideLocalScope() throws {
    let recursiveName: HeistPlanName = "repeatHeist"
    let recursivePath: HeistInvocationPath = "repeatHeist"
    let diagnostics = runtimeSafetyDiagnostics {
        try HeistPlan(definitions: [
            HeistPlan(name: recursiveName, body: [
                .invoke(HeistInvocationStep(path: recursivePath)),
            ]),
        ], body: [
            .invoke(HeistInvocationStep(path: recursivePath)),
        ])
    }

    #expect(diagnostics.contains {
        $0.message.contains("heist run path must resolve to a local capability")
    })
}

@Test
func runtimeSafetyAcceptsSingularAccessibilityTargetCapability() throws {
    // `target` is singular by type — a predicate for exactly one element.
    // Multiple targets are unrepresentable; a capability run with one target is
    // runtime-valid.
    let definition = try HeistPlan(
        name: "deleteItem",
        parameter: .accessibilityTarget(name: "target"),
        body: [.action(ActionStep(command: .activate(.ref("target"))))]
    )
    _ = try HeistPlan(definitions: [definition], body: [
        .invoke(HeistInvocationStep(
            path: "deleteItem",
            argument: .accessibilityTarget(.predicate(.label("Row 1")))
        )),
    ])
}

@Test
func runtimeSafetyAcceptsParameterizedRootAndScratchRootCaller() throws {
    let parameterizedRoot = try HeistPlan(
        name: "search",
        parameter: .string(name: "query"),
        body: [.action(ActionStep(command: .typeText(
            reference: "query",
            target: .predicate(.label("Search"))
        )))]
    )
    _ = parameterizedRoot

    let scratchRoot = try HeistPlan(
        definitions: [
            HeistPlan(name: "search", parameter: .string(name: "query"), body: [
                .action(ActionStep(command: .typeText(
                    reference: "query",
                    target: .predicate(.label("Search"))
                ))),
            ]),
        ],
        body: [.invoke(HeistInvocationStep(path: "search", argument: .string("Milk")))]
    )
    _ = scratchRoot
}

@Test
func runtimeSafetyUsesInvokedDefinitionScopeForHelperDependencies() throws {
    let itemReference: HeistReferenceName = "item"
    _ = try HeistPlan(definitions: [
        HeistPlan(
            name: "addToCart",
            parameter: .string(name: "item"),
            definitions: [
                HeistPlan(name: "tapAddButton", body: [
                    .action(ActionStep(command: .activate(.predicate(ElementPredicate(label: "Add to Cart"))))),
                ]),
            ],
            body: [
                .action(ActionStep(command: .activate(.predicate(
                    ElementPredicate(label: .exact(itemReference))
                )))),
                .invoke(HeistInvocationStep(path: "tapAddButton")),
            ]
        ),
    ], body: [
        .invoke(HeistInvocationStep(
            path: "addToCart",
            argument: .string("Milk")
        )),
    ])

}

@Test
func runtimeSafetyAllowsSameLeafDefinitionNamesInDifferentScopes() throws {
    _ = try HeistPlan(definitions: [
        HeistPlan(
            name: "setup",
            definitions: [
                HeistPlan(name: "setup", body: [
                    .warn(WarnStep(message: "Nested setup")),
                ]),
            ],
            body: [
                .invoke(HeistInvocationStep(path: "setup")),
            ]
        ),
    ], body: [
        .invoke(HeistInvocationStep(path: "setup")),
    ])

}

@Test
func runtimeSafetyValidatesInvokedBodiesWithBoundArguments() throws {
    let diagnostics = runtimeSafetyDiagnostics {
        try HeistPlan(definitions: [
        HeistPlan(
            name: "typeSearch",
            parameter: .string(name: "query"),
            body: [
                .action(ActionStep(command: .typeText(
                    reference: "query",
                    target: .predicate(.label("Search"))
                ))),
            ]
        ),
    ], body: [
        .invoke(HeistInvocationStep(
            path: "typeSearch",
            argument: .string("")
        )),
        ])
    }

    #expect(diagnostics.contains { $0.message.contains("action command must be admissible") })
    #expect(diagnostics.contains { $0.message.contains("text to append must be non-empty") })
}

@Test
func runtimeSafetyAcceptsRepresentativeCanonicalPlan() throws {
    let itemReference: HeistReferenceName = "item"
    let plan = try HeistPlan(body: [
        .action(ActionStep(
            command: .activate(.predicate(.label("Sign In"))),
            expectationPolicy: .expect(ActionExpectation(predicate: .exists(.label("Home")), timeout: 5)))),
        .wait(WaitStep(predicate: .missing(.label("Loading")), timeout: 1)),
        .conditional(try ConditionalStep(cases: [
            PredicateCase(predicate: .exists(.label("Home")), body: [.warn(WarnStep(message: "home"))]),
        ])),
        .wait(WaitStep(
            predicate: .exists(.label("Done")),
            timeout: 2,
            elseBody: [.fail(FailStep(message: "timeout"))]
        )),
        .warn(WarnStep(message: "done")),
        .forEachElement(try ForEachElementStep(
            matching: .label("Delete"),
            limit: 20,
            parameter: "target",
            body: [
                .action(ActionStep(
                    command: .activate(.ref("target")),
                    expectationPolicy: .expect(ActionExpectation(predicate: .missing(.ref("target")), timeout: 2)))),
            ]
        )),
        .forEachString(try ForEachStringStep(
            values: ["Milk", "Eggs"],
            parameter: "item",
            body: [
                .action(ActionStep(
                    command: .typeText(reference: itemReference, target: .predicate(.label("Add item"))),
                    expectationPolicy: .expect(ActionExpectation(
                        predicate: .exists(.predicate(ElementPredicate(label: .exact(itemReference)))),
                        timeout: 2
                    )))),
            ]
        )),
        .action(ActionStep(command: .setPasteboard(SetPasteboardTarget(text: "milk")))),
        .action(ActionStep(command: .editAction(EditActionTarget(action: .paste)))),
        .action(ActionStep(command: .dismissKeyboard)),
        .warn(WarnStep(message: "done")),
        .fail(FailStep(message: "stop")),
    ])

    _ = plan
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
