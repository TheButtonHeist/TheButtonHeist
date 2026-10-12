import Testing
@testable import ThePlans

@Test func `namespace block allows qualified reusable capability composition`() throws {
    let source = """
    HeistPlan("Checkout") {
        Namespace("lib") {
            HeistDef<Void>("payOpen") {
                Warn("pay opened")
            }

            HeistDef<Void>("clearCheck") {
                Warn("check cleared")
            }

            HeistDef<Void>("checkout") {
                RunHeist("lib.payOpen")
                RunHeist("lib.clearCheck")
            }
        }

        RunHeist("lib.checkout")
    }
    """

    let plan = try HeistSourceParser.parse(source)
    let lib = try #require(plan.definitions.first { $0.name == "lib" })
    let checkout = try #require(lib.definitions.first { $0.name == "checkout" })

    #expect(checkout.body == [
        .invoke(HeistInvocationStep(path: "lib.payOpen")),
        .invoke(HeistInvocationStep(path: "lib.clearCheck")),
    ])
    #expect(plan.body == [
        .invoke(HeistInvocationStep(path: "lib.checkout")),
    ])

    try assertCanonicalRoundTrip(plan)
}

@Test func `nested namespace duplicate definitions return typed admission diagnostics`() {
    let diagnostic = parseDiagnostic("""
    HeistPlan {
        Namespace("lib") {
            Namespace("checkout") {
                HeistDef<Void>("pay") {
                    Warn("first")
                }

                HeistDef<Void>("pay") {
                    Warn("second")
                }
            }
        }

        Warn("root")
    }
    """)

    #expect(diagnostic.code == .planRuntimeSafety)
    #expect(diagnostic.phase == .planValidation)
    #expect(diagnostic.path == "$.definitions[0].definitions[0].definitions[1].name")
    #expect(diagnostic.message.contains("duplicate heist definition names are not allowed in the same scope"))
    #expect(diagnostic.hint == "Rename one definition or put it in a different namespace.")
}

@Test func `qualified namespace calls fail clearly when the export is missing`() throws {
    let diagnostic = parseError("""
    HeistPlan {
        HeistDef<Void>("caller") {
            RunHeist("lib.nope")
        }

        RunHeist("caller")
    }
    """)

    expect(diagnostic, contains: "heist run path must resolve to a declared exported capability")
    expect(diagnostic, contains: "No export named 'lib.nope'")
}

@Test func `unqualified sibling call inside namespace remains local only`() throws {
    let diagnostic = parseError("""
    HeistPlan {
        Namespace("lib") {
            HeistDef<Void>("payOpen") {
                Warn("pay opened")
            }

            HeistDef<Void>("checkout") {
                RunHeist("payOpen")
            }
        }

        RunHeist("lib.checkout")
    }
    """)

    expect(diagnostic, contains: "heist run path must resolve to a local capability")
}

@Test func `exported namespace capability cycle is rejected`() throws {
    let diagnostic = parseError("""
    HeistPlan {
        Namespace("lib") {
            HeistDef<Void>("a") {
                RunHeist("lib.b")
            }

            HeistDef<Void>("b") {
                RunHeist("lib.a")
            }
        }

        RunHeist("lib.a")
    }
    """)

    expect(diagnostic, contains: "heist runs must not be recursive")
    expect(diagnostic, contains: "lib.a -> lib.b -> lib.a")
}

@Test func `exported namespace calls enforce target arity`() throws {
    let diagnostic = parseError("""
    HeistPlan {
        Namespace("lib") {
            HeistDef<String>("addItem", parameter: "dish") { dish in
                TypeText(dish, into: .label("Search"))
            }

            HeistDef<Void>("caller") {
                RunHeist("lib.addItem")
            }
        }

        RunHeist("lib.caller")
    }
    """)

    expect(diagnostic, contains: "heist run argument type must match the target parameter")
}

@Test func `parser scopes aliases through nested bodies`() throws {
    let source = """
    HeistPlan("Scoped", parameter: "rootValue") { rootAlias in
        HeistDef<String>("Echo.item", parameter: "item") { itemAlias in
            TypeText(itemAlias, into: .label(itemAlias))
        }

        HeistDef<AccessibilityTarget>("Messages.archive", parameter: "message") { messageAlias in
            CustomAction("Archive", on: messageAlias)
        }

        If(.exists(.label(rootAlias))) {
            TypeText(rootAlias)
        }

        ForEach("inner") { loopItem in
            TypeText(loopItem, into: .label(rootAlias))
        }

        ForEach(.label(rootAlias), limit: 1) { rowTarget in
            Activate(rowTarget).expect(.missing(rowTarget))
        }
    }
    """

    let plan = try HeistSourceParser.parse(source)
    let echo = try #require(plan.definitions.first { $0.name == "Echo" })
    let item = try #require(echo.definitions.first { $0.name == "item" })
    let messages = try #require(plan.definitions.first { $0.name == "Messages" })
    let archive = try #require(messages.definitions.first { $0.name == "archive" })

    #expect(plan.parameter == .string(name: "rootValue"))
    #expect(item.parameter == .string(name: "item"))
    #expect(item.body == [
        .action(ActionStep(command: .typeText(
            reference: "item",
            target: .predicate(.label(HeistReferenceName(stringLiteral: "item")))
        ))),
    ])
    #expect(archive.parameter == .accessibilityTarget(name: "message"))
    #expect(archive.body == [
        .action(ActionStep(command: .customAction(name: "Archive", target: .ref("message")))),
    ])
    #expect(plan.body == [
        .conditional(try ConditionalStep(cases: [
            PredicateCase(
                predicate: .exists(.label(HeistReferenceName(stringLiteral: "rootValue"))),
                body: [.action(ActionStep(command: .typeText(reference: "rootValue", target: nil)))]
            ),
        ])),
        .forEachString(try ForEachStringStep(
            values: ["inner"],
            parameter: "loopItem",
            body: [
                .action(ActionStep(command: .typeText(
                    reference: "loopItem",
                    target: .predicate(.label(HeistReferenceName(stringLiteral: "rootValue")))
                ))),
            ]
        )),
        .forEachElement(try ForEachElementStep(
            matching: .label(HeistReferenceName(stringLiteral: "rootValue")),
            limit: 1,
            parameter: "rowTarget",
            body: [
                .action(ActionStep(
                    command: .activate(.ref("rowTarget")),
                    expectationPolicy: .expect(ActionExpectation(
                        predicate: .missing(.ref("rowTarget")),
                        timeout: .sessionDefault
                    )))),
            ]
        )),
    ])
}

@Test func `parser rejects references outside lexical scope`() {
    let cases: [(source: String, diagnostic: String)] = [
        (
            root("""
            ForEach("Milk") { item in
                TypeText(item)
            }
            TypeText(item)
            """),
            "expected a string literal or scoped string reference"
        ),
        (
            root("""
            ForEach(.label("Row"), limit: 1) { row in
                Activate(row).expect(.missing(row))
            }
            Activate(row)
            """),
            "expected a ButtonHeist expression beginning with '.'"
        ),
        (
            """
            HeistPlan {
                HeistDef<String>("Echo.item", parameter: "item") { itemAlias in
                    TypeText(itemAlias)
                }
                TypeText(itemAlias)
            }
            """,
            "expected a string literal or scoped string reference"
        ),
    ]

    for testCase in cases {
        expect(parseError(testCase.source), contains: testCase.diagnostic)
    }
}

@Test func `parser rejects nested ForEach bodies through runtime diagnostics`() throws {
    let cases: [(source: String, path: String, observed: String)] = [
        (
            root("""
            ForEach("Milk", "Eggs") { item in
                ForEach("Small") { size in
                    TypeText(size, into: .label(item))
                }
            }
            """),
            "$.body[0].for_each_string.body[0].for_each_string",
            "for_each_string inside collection loop"
        ),
        (
            root("""
            ForEach("Message") { rowName in
                ForEach(.label("Message"), limit: 1) { rowTarget in
                    Activate(rowTarget).expect(.exists(rowTarget))
                    TypeText(rowName, into: .label("Search"))
                }
            }
            """),
            "$.body[0].for_each_string.body[0].for_each_element",
            "for_each_element inside collection loop"
        ),
        (
            root("""
            ForEach(.label("Section"), limit: 1) { section in
                ForEach("Small") { size in
                    Activate(section)
                }
            }
            """),
            "$.body[0].for_each_element.body[0].for_each_string",
            "for_each_string inside collection loop"
        ),
        (
            root("""
            ForEach(.label("Section"), limit: 1) { section in
                ForEach(.label("Row"), limit: 1) { row in
                    Activate(row)
                }
            }
            """),
            "$.body[0].for_each_element.body[0].for_each_element",
            "for_each_element inside collection loop"
        ),
        (
            """
            HeistPlan("NestedThroughRunHeist") {
                HeistDef<Void>("Inner") {
                    ForEach("Small") { size in
                        Warn("nested")
                    }
                }

                ForEach("Milk") { item in
                    RunHeist("Inner")
                }
            }
            """,
            "$.body[0].for_each_string.body[0].invoke.body[0].for_each_string",
            "for_each_string inside collection loop"
        ),
    ]

    for testCase in cases {
        let diagnostic = parseDiagnostic(testCase.source)
        #expect(diagnostic.code.rawValue == "heist.plan.runtime_safety")
        #expect(diagnostic.phase == .planValidation)
        #expect(diagnostic.path == testCase.path)
        #expect(diagnostic.message == "collection loops must not be nested; observed \(testCase.observed)")
        #expect(diagnostic.hint == "Flatten this heist so ForEach bodies contain only non-collection steps.")
    }
}
