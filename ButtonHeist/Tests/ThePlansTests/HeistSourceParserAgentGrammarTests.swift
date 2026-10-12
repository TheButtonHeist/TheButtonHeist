import Testing
@testable import ThePlans

@Test func `reported agent target grammar gaps parse`() throws {
    let ordinal = try HeistSourceParser.parse(root(#"Activate(.target(.label("Pay"), ordinal: 0))"#))
    #expect(ordinal.body == [
        .action(ActionStep(command: .activate(.predicate(.label("Pay"), ordinal: 0)))),
    ])

    let scopedOrdinal = try HeistSourceParser.parse(root(
        #"Activate(.within(container: .identifier("Sheet"), .target(.label("Pay"), ordinal: 0)))"#
    ))
    #expect(scopedOrdinal.body == [
        .action(ActionStep(command: .activate(.within(
            container: .identifier("Sheet"),
            target: .predicate(.label("Pay"), ordinal: 0)
        )))),
    ])

    let traits = try HeistSourceParser.parse(root(#"Activate(.element(.label("Pay"), .traits([.button])))"#))
    #expect(traits.body == [
        .action(ActionStep(command: .activate(.predicate(.element(.label("Pay"), .traits([.button])))))),
    ])

    let typeText = try HeistSourceParser.parse(root(#"TypeText("milk", into: .label("Search"))"#))
    #expect(typeText.body == [
        .action(ActionStep(command: .typeText(text: "milk", target: .predicate(.label("Search"))))),
    ])

    let screenshot = try HeistSourceParser.parse(root("TakeScreenshot()"))
    #expect(screenshot.body == [
        .action(ActionStep(command: .takeScreenshot)),
    ])

    let waived = try HeistSourceParser.parse(root(#"Activate(.label("Pay")).withoutExpectation("reason")"#))
    #expect(waived.body == [
        .action(ActionStep(
            command: .activate(.predicate(.label("Pay"))),
            expectationPolicy: .waived("reason"))),
    ])
}

@Test func `reported agent grammar mistakes fail with corrections`() throws {
    let stringTraits = parseError(root(#"Activate(.element(.label("Pay"), .traits(["button"])))"#))
    expect(stringTraits, contains: "traits must use enum-style syntax like [.button]")

    let actionOrdinal = parseError(root(#"Activate(.label("Pay"), ordinal: 0)"#))
    expect(
        actionOrdinal,
        contains: #"Ordinal belongs to the target. Use Activate(.target(.label("Pay"), ordinal: 0))."#
    )

    let scopedActionOrdinal = parseError(root(
        #"Activate(.within(container: .identifier("Sheet"), .label("Pay")), ordinal: 0)"#
    ))
    expect(
        scopedActionOrdinal,
        contains: #"Use Activate(.within(container: .identifier("Sheet"), .target(.label("Pay"), ordinal: 0)))."#
    )

    let labeledStringMatchMode = parseError(root(#"Activate(.label(contains: "Pay"))"#))
    expect(labeledStringMatchMode, contains: #"StringMatch modes use enum-case syntax; use `.label(.contains("..."))`"#)

    let nativeIf = parseError(root("""
    if true {
        Activate(.label("Pay"))
    } else {
        Fail("missing")
    }
    """))
    expect(nativeIf, contains: "native Swift if/else is not supported")
    expect(nativeIf, contains: "If { Case(...) { ... } Else { ... } }")

    let ifShorthand = try HeistSourceParser.parse(root("""
    If(.exists(.label("Pay"))) {
        Activate(.label("Pay"))
    }.else {
        Fail("missing")
    }
    """))
    #expect(ifShorthand.body == [
        .conditional(try ConditionalStep(
            cases: [
                PredicateCase(
                    predicate: .exists(.label("Pay")),
                    body: [.action(ActionStep(command: .activate(.predicate(.label("Pay")))))]
                ),
            ],
            elseBody: [.fail(FailStep(message: "missing"))]
        )),
    ])

    let unknownAction = parseError(root(#"Tap(.label("Pay"))"#))
    expect(unknownAction, contains: "unsupported ButtonHeist source statement 'Tap'")

    let wrongRunHeistArgument = parseError("""
    HeistPlan {
        HeistDef<String>("addItem", parameter: "item") { item in
            Activate(.label(item))
        }

        RunHeist("addItem", .label("Milk"))
    }
    """)
    expect(wrongRunHeistArgument, contains: "heist run argument type must match the target parameter")

    let emptyCustomActionName = parseError(root(#"CustomAction("", on: .label("Message"))"#))
    expect(emptyCustomActionName, contains: "custom action name must not be blank")

    let emptyRunHeistPath = parseError(root(#"RunHeist("")"#))
    expect(emptyRunHeistPath, contains: "heist path must not be empty")

    let emptyRunHeistPathComponent = parseError(root(#"RunHeist("lib..checkout")"#))
    expect(emptyRunHeistPathComponent, contains: "heist path component at index 1 must not be empty")

    let bodyTry = parseError(root("""
    try ForEach("Milk") { item in
        Activate(.label(item))
    }
    """))
    expect(bodyTry, contains: "`try` is only allowed in Swift wrapper code")

    let caseAfterElse = parseError(root("""
    If {
        Else {
            Warn("fallback")
        }
        Case(.exists(.label("Pay"))) {
            Activate(.label("Pay"))
        }
    }
    """))
    expect(caseAfterElse, contains: "Case must appear before Else")
}

@Test func `reported agent update grammar mistakes fail with corrections`() throws {
    let emptyUpdated = parseError(root(#"Activate(.label("Pay")).expect(.elementsChanged([.updated()]))"#))
    expect(emptyUpdated, contains: "expected a ButtonHeist expression beginning with '.'")

    let elementOnlyUpdated = parseError(root(
        #"Activate(.label("Pay")).expect(.elementsChanged([.updated(.label("Total"))]))"#
    ))
    expect(elementOnlyUpdated, contains: "expected ','")

    let explicitlyElementOnlyUpdated = parseError(root(
        #"Activate(.label("Pay")).expect("# +
            #".elementsChanged([.updated(.element(.label("Quantity")))]))"#
    ))
    expect(explicitlyElementOnlyUpdated, contains: "expected ','")

    let labeledElementUpdated = parseError(root(
        #"Activate(.label("Pay")).expect("# +
            #".elementsChanged([.updated(element: .label("Total"), .value("$3"))]))"#
    ))
    expect(labeledElementUpdated, contains: "expected a ButtonHeist expression beginning with '.'")

    let labeledExplicitElementUpdated = parseError(root(
        #"Activate(.label("Pay")).expect("# +
            #".elementsChanged([.updated(element: .element(.label("Total")), "# +
            #".value("$3"))]))"#
    ))
    expect(labeledExplicitElementUpdated, contains: "expected a ButtonHeist expression beginning with '.'")

    let beforeOnlyUpdate = parseError(root(
        #"Activate(.label("Pay")).expect("# +
            #".elementsChanged([.updated(.label("Total"), .value(before: "$2"))]))"#
    ))
    expect(beforeOnlyUpdate, contains: "value update predicate requires after when before is set")

    let containerUpdate = parseError(root(
        #"Activate(.label("Pay")).expect("# +
            #".elementsChanged([.updated(.container(.identifier("Checkout")), .value("$3"))]))"#
    ))
    expect(containerUpdate, contains: "element updates require an element target")

    let scopedContainerUpdate = parseError(root(
        #"Activate(.label("Pay")).expect("# +
            #".elementsChanged([.updated(.within(container: .identifier("Checkout"), "# +
            #".container(.identifier("List"))), .value("$3"))]))"#
    ))
    expect(scopedContainerUpdate, contains: "element updates require an element target")

    // An element assertion written inside `.screen(...)` is the costume mistake:
    // `.screen` names the arrived-at screen, so the correction has to point at
    // `.elements([...])`, which is where an element question belongs.
    let screenChangedAppeared = parseError(root(
        #"Activate(.label("Pay")).expect(.screenChanged([.appeared(.label("Receipt"))]))"#
    ))
    expect(screenChangedAppeared, contains: ".elementsChanged([...]) for element assertions")

    let screenChangedUpdated = parseError(root(
        #"Activate(.label("Pay")).expect("# +
            #".screenChanged([.updated(.label("Total"), .value("$3"))]))"#
    ))
    expect(screenChangedUpdated, contains: ".elementsChanged([...]) for element assertions")
}

@Test func `runtime parser rejects empty predicates`() throws {
    let emptyExists = parseError(root(#"WaitFor(.exists())"#))
    expect(emptyExists, contains: "expected a ButtonHeist expression beginning with '.'")

    let emptyMissing = parseError(root(#"WaitFor(.missing())"#))
    expect(emptyMissing, contains: "expected a ButtonHeist expression beginning with '.'")

    let emptyAppeared = parseError(root(#"WaitFor(.elementsChanged([.appeared()]))"#))
    expect(emptyAppeared, contains: "expected a ButtonHeist expression beginning with '.'")

    let emptyDisappeared = parseError(root(#"WaitFor(.elementsChanged([.disappeared()]))"#))
    expect(emptyDisappeared, contains: "expected a ButtonHeist expression beginning with '.'")

}

@Test func `runtime parser rejects transition predicates in conditionals`() throws {
    let ifAppeared = parseError(root(#"""
    If(.appeared(.label("Receipt"))) {
        Warn("ready")
    }
    """#))
    expect(ifAppeared, contains: "branch conditions accept only .exists and .missing")

    let caseUpdated = parseError(root(#"""
    If {
        Case(.updated(.value("Ready"))) {
            Warn("ready")
        }
    }
    """#))
    expect(caseUpdated, contains: "branch conditions accept only .exists and .missing")
}

@Test func `runtime parser rejects arbitrary Swift and bypass shapes`() throws {
    let cases: [(String, String)] = [
        (
            """
            import Foundation
            HeistPlan {
                Warn("x")
            }
            """,
            "import declarations are not supported"
        ),
        (
            root("""
            let items = ["Milk", "Bread"]
            Warn("x")
            """),
            "let declarations are not supported"
        ),
        (
            root("""
            var item = "Milk"
            Warn("x")
            """),
            "var declarations are not supported"
        ),
        (
            root("""
            func helper() {
                Warn("x")
            }
            """),
            "function declarations are not supported"
        ),
        (
            root("""
            if Bool.random() {
                Warn("x")
            }
            """),
            "native Swift if/else is not supported"
        ),
        (
            root("""
            for item in ["Milk"] {
                Warn("x")
            }
            """),
            "native Swift for statements are not supported"
        ),
        (
            root("""
            switch "x" {
            default:
                Warn("x")
            }
            """),
            "native Swift switch statements are not supported"
        ),
        (
            root("""
            struct Helper {}
            """),
            "type declarations are not supported"
        ),
        (
            root("""
            .init("Bypass") {
                Warn("x")
            }
            """),
            "expected an identifier"
        ),
        (
            """
            HeistPlan(body: [
                .warn(WarnStep(message: "raw"))
            ])
            """,
            "expected a string literal"
        ),
        (
            root(#"Activate(.label(helper()))"#),
            "arbitrary calls are not supported"
        ),
        (
            root(#"try RunHeist("Cart.addItem")"#),
            "`try` is only allowed in Swift wrapper code"
        ),
    ]

    for (source, expectedDiagnostic) in cases {
        expect(parseError(source), contains: expectedDiagnostic)
    }
}
