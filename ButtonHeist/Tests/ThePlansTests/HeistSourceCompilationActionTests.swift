import Testing
@testable import ThePlans

@Test func `screen action namespace compiles regular actions`() throws {
    let plan = try HeistSourceCompilation.compile(root("""
    ScreenActions.Dismiss()
        .expect(.screenChanged)
    ScreenActions.MagicTap()
        .withoutExpectation("Magic tap toggles process-local playback state")
    """))
    let expected = try HeistPlan(body: [
        .action(ActionStep(
            command: .dismiss,
            expectationPolicy: .expect(ActionExpectation(
                predicate: .screenChanged
            )))),
        .action(ActionStep(
            command: .magicTap,
            expectationPolicy: .waived("Magic tap toggles process-local playback state"))),
    ])

    #expect(plan == expected)
}

@Test func `inline plan source type text replacement and clear compile`() throws {
    let replacement = try HeistSourceCompilation.compile(root(#"""
    TypeText(.replacing("b"), into: .identifier("Field"))
    """#))
    let clear = try HeistSourceCompilation.compile(root(#"""
    ClearText(.identifier("Field"))
    """#))
    let emptyReplacement = try HeistSourceCompilation.compile(root(#"""
    TypeText(.replacing(""), into: .identifier("Field"))
    """#))

    let expectedReplacement = try HeistPlan(body: [
        .action(ActionStep(command: .typeText(
            text: .replacing("b"),
            target: .predicate(.identifier("Field"))
        ))),
    ])
    let expectedClear = try HeistPlan(body: [
        .action(ActionStep(command: .typeText(
            text: .replacing(""),
            target: .predicate(.identifier("Field"))
        ))),
    ])

    #expect(replacement == expectedReplacement)
    #expect(clear == expectedClear)
    #expect(emptyReplacement == expectedClear)
    try assertCanonicalRoundTrip(replacement)
    try assertCanonicalRoundTrip(clear)
}

@Test func `runtime parser accepts repeated string predicate checks for one field`() throws {
    let plan = try HeistSourceCompilation.compile(root("""
    Activate(.element(.label(.prefix("foo")), .label(.contains("bar")), .label(.suffix("baz")), .traits([.button])))
    """))
    let expected = try HeistPlan(body: [
        .action(ActionStep(command: .activate(.predicate(.element(
            .label(.prefix("foo")),
            .label(.contains("bar")),
            .label(.suffix("baz")),
            .traits([.button])
        ))))),
    ])

    #expect(plan == expected)
    try assertCanonicalRoundTrip(plan)
}

@Test func `inline plan source chained expectation compiles`() throws {
    let plan = try HeistSourceCompilation.compile(root("""
    Activate(.label("Pay")).expect(.screenChanged)
    """))
    let expected = try HeistPlan(body: [
        .action(ActionStep(
            command: .activate(.predicate(.label("Pay"))),
            expectationPolicy: .expect(ActionExpectation(
                predicate: .screenChanged
            )))),
    ])

    #expect(plan == expected)
}

@Test func `inline plan source RunHeist expectation compiles`() throws {
    let plan = try HeistSourceCompilation.compile("""
    HeistPlan("shop") {
        HeistDef<String>("Cart.addItem", parameter: "item") { item in
            Activate(.label(item))
        }

        HeistDef<Void>("Checkout.pay") {
            Activate(.label("Pay"))
        }

        RunHeist("Cart.addItem", "Milk")
            .expect(.elementsChanged([.appeared(.label("subtotal"))]))

        RunHeist("Cart.addItem", "Eggs")
            .expect(.elementsChanged([.updated(.label("subtotal"), .value(.contains("2 items")))]))

        RunHeist("Checkout.pay")
            .expect(.exists(.label("Payment Complete")))

        RunHeist("Checkout.pay")
            .expect(.screenChanged("Receipt"))
    }
    """)
    let expected = try HeistPlan(
        name: "shop",
        definitions: [
            try HeistPlan(name: "Cart", definitions: [
                try HeistPlan(
                    name: "addItem",
                    parameter: .string(name: "item"),
                    body: [
                        .action(ActionStep(command: .activate(.predicate(
                            .label(HeistReferenceName(stringLiteral: "item"))
                        )))),
                    ]
                ),
            ], body: []),
            try HeistPlan(name: "Checkout", definitions: [
                try HeistPlan(name: "pay", body: [
                    .action(ActionStep(command: .activate(.predicate(.label("Pay"))))),
                ]),
            ], body: []),
        ],
        body: [
            .invoke(HeistInvocationStep(
                path: "Cart.addItem",
                argument: .string("Milk"),
                expectation: ActionExpectation(
                    predicate: .elementsChanged([.appeared(.label("subtotal"))])
                )
            )),
            .invoke(HeistInvocationStep(
                path: "Cart.addItem",
                argument: .string("Eggs"),
                expectation: ActionExpectation(
                    predicate: .elementsChanged([
                        .updated(.label("subtotal"), .value(after: .contains("2 items"))),
                    ])
                )
            )),
            .invoke(HeistInvocationStep(
                path: "Checkout.pay",
                expectation: ActionExpectation(
                    predicate: .exists(.label("Payment Complete"))
                )
            )),
            .invoke(HeistInvocationStep(
                path: "Checkout.pay",
                expectation: ActionExpectation(
                    predicate: .screenChanged("Receipt")
                )
            )),
        ]
    )

    #expect(plan == expected)
    try assertCanonicalRoundTrip(plan)
}

@Test func `inline plan source rejects empty HeistDef path components`() throws {
    do {
        _ = try HeistSourceCompilation.compile("""
        HeistPlan("cart") {
            HeistDef<Void>("Cart..checkout") {
                Warn("checkout")
            }

            RunHeist("Cart.checkout")
        }
        """)
        Issue.record("Expected source compilation to reject empty HeistDef path component")
    } catch let error {
        let diagnostic = try #require(error.diagnostics.first)
        #expect(diagnostic.code == .dslInvalidDefinition)
        #expect(diagnostic.title == "Invalid heist definition")
        #expect(diagnostic.phase == .sourceCompilation)
        #expect(diagnostic.path == "Cart..checkout")
        #expect(diagnostic.sourceSpan?.line == 2)
        expect(error.description, contains: "heist path component at index 1 must not be empty")
    }
}

@Test func `inline plan source property update expectations compile`() throws {
    let scoped = try HeistSourceCompilation.compile(root(#"""
    TypeText("Bruschetta", into: .identifier("Search"))
        .expect(.elementsChanged([.updated(.identifier("Search"), .value("Bruschetta"))]))
    """#))
    let unscoped = try HeistSourceCompilation.compile(root(#"""
    Increment(.identifier("Quantity"))
        .expect(.elementsChanged([.updated(.identifier("Quantity"), .value("3"))]))
    """#))
    let beforeAfter = try HeistSourceCompilation.compile(root(#"""
    Increment(.identifier("Quantity"))
        .expect(.elementsChanged([.updated(
            .identifier("Quantity"),
            .value(before: "2", after: "3")
        )]))
    """#))
    let broadBeforeAfter = try HeistSourceCompilation.compile(root(#"""
    Increment(.identifier("Quantity"))
        .expect(.elementsChanged([.updated(
            .identifier("Quantity"),
            .value(before: .prefix("cart:"), after: .contains("items"))
        )]))
    """#))

    let expectedScoped = try HeistPlan(body: [
        .action(ActionStep(
            command: .typeText(
                text: "Bruschetta",
                target: .predicate(.identifier("Search"))
            ),
            expectationPolicy: .expect(ActionExpectation(predicate: .elementsChanged([
                .updated(.identifier("Search"), .value(after: "Bruschetta")),
            ]), timeout: .sessionDefault)))),
    ])
    let expectedUnscoped = try HeistPlan(body: [
        .action(ActionStep(
            command: .increment(.predicate(.identifier("Quantity"))),
            expectationPolicy: .expect(ActionExpectation(predicate: .elementsChanged([
                .updated(.identifier("Quantity"), .value(after: "3")),
            ]), timeout: .sessionDefault)))),
    ])
    let expectedBeforeAfter = try HeistPlan(body: [
        .action(ActionStep(
            command: .increment(.predicate(.identifier("Quantity"))),
            expectationPolicy: .expect(ActionExpectation(predicate: .elementsChanged([
                .updated(.identifier("Quantity"), .value(before: "2", after: "3")),
            ]), timeout: .sessionDefault)))),
    ])
    let expectedBroadBeforeAfter = try HeistPlan(body: [
        .action(ActionStep(
            command: .increment(.predicate(.identifier("Quantity"))),
            expectationPolicy: .expect(ActionExpectation(predicate: .elementsChanged([
                .updated(
                    .identifier("Quantity"),
                    .value(before: .prefix("cart:"), after: .contains("items"))
                ),
            ]), timeout: .sessionDefault)))),
    ])

    #expect(scoped == expectedScoped)
    #expect(unscoped == expectedUnscoped)
    #expect(beforeAfter == expectedBeforeAfter)
    #expect(broadBeforeAfter == expectedBroadBeforeAfter)
    try assertCanonicalRoundTrip(scoped)
    try assertCanonicalRoundTrip(beforeAfter)
}

@Test func `inline plan source custom content update queries label and value`() throws {
    let plan = try HeistSourceCompilation.compile(root(#"""
    WaitFor(.elementsChanged([.updated(.identifier("status"), .customContent(after: .init(
        label: "Status",
        value: .contains("Ready"),
        isImportant: true
    )))]))
    """#))
    let expected = try HeistPlan(body: [
        .wait(WaitStep(predicate: .elementsChanged([
            .updated(.identifier("status"), .customContent(after: CustomContentMatch(
                label: .exact("Status"),
                value: .contains("Ready"),
                isImportant: true
            ))),
        ]))),
    ])

    #expect(plan == expected)
    let expectedCustomContent = #".customContent(after: .init(label: "Status", "# +
        #"value: .contains("Ready"), isImportant: true))"#
    #expect(try plan.canonicalSwiftDSL().contains(expectedCustomContent))
    try assertCanonicalRoundTrip(plan)
}

@Test func `inline plan source accepts canonical direct delta predicates`() throws {
    let appeared = try HeistSourceCompilation.compile(root(#"""
    Activate(.label("Add"))
        .expect(.elementsChanged([.appeared(.label("Back"))]))
    """#))
    let disappeared = try HeistSourceCompilation.compile(root(#"""
    Activate(.label("Clear"))
        .expect(.elementsChanged([.disappeared(.identifier("row-1"))]))
    """#))
    let updatedPropertyOnly = try HeistSourceCompilation.compile(root(#"""
    TypeText("milk", into: .identifier("Search"))
        .expect(.elementsChanged([.updated(.identifier("Search"), .value())]))
    """#))
    let updatedBeforeAfterOnly = try HeistSourceCompilation.compile(root(#"""
    TypeText("milk", into: .identifier("Search"))
        .expect(.elementsChanged([.updated(
            .identifier("Search"),
            .value(before: "", after: "milk")
        )]))
    """#))
    let expectedAppeared = try HeistPlan(body: [
        .action(ActionStep(
            command: .activate(.predicate(.label("Add"))),
            expectationPolicy: .expect(ActionExpectation(predicate: .elementsChanged([
                .appeared(.label("Back")),
            ]), timeout: .sessionDefault)))),
    ])
    let expectedDisappeared = try HeistPlan(body: [
        .action(ActionStep(
            command: .activate(.predicate(.label("Clear"))),
            expectationPolicy: .expect(ActionExpectation(predicate: .elementsChanged([
                .disappeared(.identifier("row-1")),
            ]), timeout: .sessionDefault)))),
    ])
    let expectedUpdatedPropertyOnly = try HeistPlan(body: [
        .action(ActionStep(
            command: .typeText(text: "milk", target: .predicate(.identifier("Search"))),
            expectationPolicy: .expect(ActionExpectation(predicate: .elementsChanged([
                .updated(.identifier("Search"), .value()),
            ]), timeout: .sessionDefault)))),
    ])
    let expectedUpdatedBeforeAfterOnly = try HeistPlan(body: [
        .action(ActionStep(
            command: .typeText(text: "milk", target: .predicate(.identifier("Search"))),
            expectationPolicy: .expect(ActionExpectation(predicate: .elementsChanged([
                .updated(.identifier("Search"), .value(before: "", after: "milk")),
            ]), timeout: .sessionDefault)))),
    ])
    #expect(appeared == expectedAppeared)
    #expect(disappeared == expectedDisappeared)
    #expect(updatedPropertyOnly == expectedUpdatedPropertyOnly)
    #expect(updatedBeforeAfterOnly == expectedUpdatedBeforeAfterOnly)
    try assertCanonicalRoundTrip(appeared)
    try assertCanonicalRoundTrip(disappeared)
    try assertCanonicalRoundTrip(updatedBeforeAfterOnly)
}

@Test func `inline plan source rejects inferred element change predicates`() {
    let cases = [
        #"Activate(.label("Add Bruschetta")).expect(.appeared(.label("Toast")))"#,
        #"Activate(.label("Remove Bruschetta")).expect(.disappeared(.identifier("row")))"#,
        #"TypeText("Bruschetta", into: .identifier("Search")).expect(.updated(.value("Bruschetta")))"#,
    ]

    for source in cases {
        expect(compileError(root(source)), contains: "unsupported accessibility predicate")
    }
}
