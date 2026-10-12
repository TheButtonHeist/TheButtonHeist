import Testing
@testable import ThePlans

@Test func `inline plan source accepts controlled predicate and loop sugar`() throws {
    let plan = try HeistSourceParser.parse(root(#"""
    Activate(.label("Search"))
        .expect(.exists(.label("Results")))
    Activate(.label("Open Details"))
        .expect(.screenChanged("Details"))
    If(.exists(.value(.contains("Promo")))) {
        Warn("promo visible")
    }
    ForEach("Milk", "Eggs") { item in
        TypeText(item, into: .label("Search"))
    }
    ForEach(.label("Delete"), limit: 2) { target in
        Activate(target).expect(.missing(target))
    }
    """#))

    let expected = try HeistPlan(body: [
        .action(ActionStep(
            command: .activate(.predicate(.label("Search"))),
            expectationPolicy: .expect(ActionExpectation(
                predicate: .exists(.label("Results")),
                timeout: .sessionDefault
            )))),
        .action(ActionStep(
            command: .activate(.predicate(.label("Open Details"))),
            expectationPolicy: .expect(ActionExpectation(
                predicate: .screenChanged("Details"),
                timeout: .sessionDefault
            )))),
        .conditional(try ConditionalStep(cases: [
            PredicateCase(
                predicate: .exists(.value(.contains("Promo"))),
                body: [.warn(WarnStep(message: "promo visible"))]
            ),
        ])),
        .forEachString(try ForEachStringStep(
            values: ["Milk", "Eggs"],
            parameter: "item",
            body: [
                .action(ActionStep(command: .typeText(
                    reference: "item",
                    target: .label("Search")
                ))),
            ]
        )),
        .forEachElement(try ForEachElementStep(
            matching: .label("Delete"),
            limit: 2,
            parameter: "target",
            body: [
                .action(ActionStep(
                    command: .activate(.ref("target")),
                    expectationPolicy: .expect(ActionExpectation(
                        predicate: .missing(.ref("target")),
                        timeout: .sessionDefault
                    )))),
            ]
        )),
    ])

    #expect(plan == expected)
    try assertCanonicalRoundTrip(plan)
}

@Test func `inline plan source unicode string escapes preserve following characters`() throws {
    let plan = try HeistSourceParser.parse(root(#"""
    Warn("A\u0062C")
    """#))
    let expected = try HeistPlan(body: [
        .warn(WarnStep(message: "AbC")),
    ])

    #expect(plan == expected)
}

@Test func `runtime authored product DSL parses through canonical parser`() throws {
    let source = """
    HeistPlan("checkout") {
        HeistDef<String>("Cart.addItem", parameter: "item") { item in
            Activate(.label(item))
        }

        Activate(.label("Pay")).expect(.screenChanged)

        WaitFor(.exists(.label("Receipt")), timeout: 5).else {
            Fail("Receipt did not appear")
        }

        Warn("Receipt appeared")

        ForEach("Milk", "Bread") { item in
            RunHeist("Cart.addItem", item)
        }
    }
    """

    let plan = try HeistSourceParser.parse(source)

    #expect(plan.name == "checkout")
    #expect(plan.definitions.first?.name == "Cart")
    #expect(plan.definitions.first?.definitions.first?.name == "addItem")
    #expect(plan.body == [
        .action(ActionStep(
            command: .activate(.predicate(.label("Pay"))),
            expectationPolicy: .expect(ActionExpectation(
                predicate: .screenChanged
            )))),
        .wait(WaitStep(
            predicate: .exists(.label("Receipt")),
            timeout: 5,
            elseBody: [.fail(FailStep(message: "Receipt did not appear"))]
        )),
        .warn(WarnStep(message: "Receipt appeared")),
        .forEachString(try ForEachStringStep(
            values: ["Milk", "Bread"],
            parameter: "item",
            body: [
                .invoke(HeistInvocationStep(
                    path: "Cart.addItem",
                    argument: .string(reference: "item")
                )),
            ]
        )),
    ])

    try assertCanonicalRoundTrip(plan)
}

@Test func `runtime parser accepts the complete durable ButtonHeist DSL surface`() throws {
    let source = """
    HeistPlan("RuntimeSurface", targetParameter: "rootTarget") { rootTarget in
        HeistDef<String>("Cart.addItem", parameter: "item") { item in
            Activate(.label(item))
                .expect(.exists(.label("Added")))
        }

        HeistDef<AccessibilityTarget>("Messages.archive", parameter: "message") { message in
            CustomAction("Archive", on: message)
        }

        Activate(rootTarget)
        Activate(.label("Pay"))
            .expect(.screenChanged)

        WaitFor(.exists(.label("Receipt")), timeout: 5).else {
            Fail("Receipt did not appear")
        }

        Warn("Receipt appeared")

        If {
            Case(.exists(.label("Cart"))) {
                Warn("Cart ready")
            }
            Else {
                Warn("Cart missing")
            }
        }

        If(.exists(.label("Pay"))) {
            Warn("Pay visible")
        }.else {
            Warn("Pay missing")
        }

        ForEach("Milk", "Bread") { item in
            RunHeist("Cart.addItem", item)
        }

        ForEach(.element(.label("Message"), .traits([.button])), limit: 2) { message in
            RunHeist("Messages.archive", message)
        }
    }
    """

    let plan = try HeistSourceParser.parse(source)

    #expect(plan.name == "RuntimeSurface")
    #expect(plan.parameter == .accessibilityTarget(name: "rootTarget"))
    #expect(plan.body.map(\.testKind) == [
        .action,
        .action,
        .wait,
        .warn,
        .conditional,
        .conditional,
        .forEachString,
        .forEachElement,
    ])

    let cart = try #require(plan.definitions.first { $0.name == "Cart" })
    let addItem = try #require(cart.definitions.first { $0.name == "addItem" })
    #expect(addItem.parameter == .string(name: "item"))
    #expect(addItem.body.map(\.testKind) == [.action])

    let messages = try #require(plan.definitions.first { $0.name == "Messages" })
    let archive = try #require(messages.definitions.first { $0.name == "archive" })
    #expect(archive.parameter == .accessibilityTarget(name: "message"))
    #expect(archive.body.map(\.testKind) == [.action])

    try assertCanonicalRoundTrip(plan)
}

@Test func `inline plan source ForEach string parses`() throws {
    let plan = try HeistSourceParser.parse(root("""
    ForEach("a", "b") { item in
        Activate(.label(item)).expect(.exists(.label(item)))
    }
    """))
    let expected = try HeistPlan(body: [
        .forEachString(try ForEachStringStep(
            values: ["a", "b"],
            parameter: "item",
            body: [
                .action(ActionStep(
                    command: .activate(.predicate(
                        .label(HeistReferenceName(stringLiteral: "item"))
                    )),
                    expectationPolicy: .expect(ActionExpectation(
                        predicate: .exists(.label(HeistReferenceName(stringLiteral: "item"))),
                        timeout: .sessionDefault
                    )))),
            ]
        )),
    ])

    #expect(plan == expected)
}

@Test func `inline plan source RepeatUntil parses`() throws {
    let plan = try HeistSourceParser.parse(root("""
    RepeatUntil(.exists(.value("3")), timeout: 2) {
        Increment(.identifier("Quantity"))
    }
    """))
    let expected = try HeistPlan(body: [
        .repeatUntil(try RepeatUntilStep(
            predicate: .exists(.value("3")),
            timeout: 2,
            body: [
                .action(ActionStep(command: .increment(.predicate(.identifier("Quantity"))))),
            ]
        )),
    ])

    #expect(plan == expected)
    try assertCanonicalRoundTrip(plan)
}

@Test func `inline plan source RepeatUntil else is rejected`() throws {
    #expect(throws: HeistPlanBuildError.self) {
        _ = try HeistSourceParser.parse(root("""
        RepeatUntil(.exists(.value("3")), timeout: 2) {
            Increment(.identifier("Quantity"))
        }.else {
            Fail("quantity did not reach 3")
        }
        """))
    }
}

@Test func `inline plan source action until parses to repeat until`() throws {
    let plan = try HeistSourceParser.parse(root("""
    Increment(.label("Volume")).until(.exists(.element(.label("Volume"), .value("100"))))
    """))
    let expected = try HeistPlan(body: [
        .repeatUntil(try RepeatUntilStep(
            predicate: .exists(.element(.label("Volume"), .value("100"))),
            timeout: defaultWaitTimeout,
            body: [
                .action(ActionStep(command: .increment(.predicate(.label("Volume"))))),
            ]
        )),
    ])

    #expect(plan == expected)
    try assertCanonicalRoundTrip(plan)
}

@Test func `inline plan source WaitFor and If parse`() throws {
    let plan = try HeistSourceParser.parse(root("""
    WaitFor(.exists(.label("Home")), timeout: 1)
    If {
        Case(.exists(.label("Pay"))) {
            Warn("ready")
        }
    }
    """))
    let expected = try HeistPlan(body: [
        .wait(WaitStep(predicate: .exists(.label("Home")), timeout: 1)),
        .conditional(try ConditionalStep(cases: [
            PredicateCase(predicate: .exists(.label("Pay")), body: [.warn(WarnStep(message: "ready"))]),
        ])),
    ])

    #expect(plan == expected)
}

@Test func `inline plan source ForEach element predicate parses`() throws {
    let plan = try HeistSourceParser.parse(root("""
    ForEach(.label("Row"), limit: 2) { target in
        Activate(target).expect(.missing(target))
    }
    """))
    let expected = try HeistPlan(body: [
        .forEachElement(try ForEachElementStep(
            matching: .label("Row"),
            limit: 2,
            parameter: "target",
            body: [
                .action(ActionStep(
                    command: .activate(.ref("target")),
                    expectationPolicy: .expect(ActionExpectation(
                        predicate: .missing(.ref("target")),
                        timeout: .sessionDefault
                    )))),
            ]
        )),
    ])

    #expect(plan == expected)
}

@Test func `inline plan source rejects old ForEach compatibility spellings`() {
    let arrayDiagnostic = parseError(root("""
    ForEach(["a"]) { item in
        TypeText(item)
    }
    """))
    expect(arrayDiagnostic, contains: #"ForEach string loops use `ForEach("a", "b")`, not array literals"#)

    let matchingDiagnostic = parseError(root("""
    ForEach(.matching(.label("Row")), limit: 2) { target in
        Activate(target)
    }
    """))
    expect(
        matchingDiagnostic,
        contains: #"ForEach element loops use direct predicates like `ForEach(.label("x"))`, "# +
            #"not `.matching(...)`"#
    )
}

private enum ParsedHeistStepKind: Equatable {
    case action
    case wait
    case conditional
    case forEachElement
    case forEachString
    case repeatUntil
    case warn
    case fail
    case heist
    case invoke
}

private extension HeistStep {
    var testKind: ParsedHeistStepKind {
        switch self {
        case .action: return .action
        case .wait: return .wait
        case .conditional: return .conditional
        case .forEachElement: return .forEachElement
        case .forEachString: return .forEachString
        case .repeatUntil: return .repeatUntil
        case .warn: return .warn
        case .fail: return .fail
        case .heist: return .heist
        case .invoke: return .invoke
        }
    }
}
