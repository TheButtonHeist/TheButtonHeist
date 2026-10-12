import Testing
@testable import ThePlans

@Test func `inline plan source simple Activate parses to HeistPlan`() throws {
    let plan = try HeistSourceParser.parse(root("""
    Activate(.label("Pay"))
    """))
    let expected = try HeistPlan(body: [
        .action(ActionStep(command: .activate(.predicate(.label("Pay"))))),
    ])

    #expect(plan == expected)
    try assertCanonicalRoundTrip(plan)
}

@Test func `runtime parser accepts explicit StringMatch enum cases for all string predicate fields`() throws {
    let plan = try HeistSourceParser.parse(root("""
    Activate(.identifier(.suffix("field")))
    WaitFor(
        .exists(.element(
            .label(.prefix("No results")),
            .identifier(.contains("empty_state")),
            .value(.suffix("items")),
            .hint(.isEmpty)
        )),
        timeout: 2
    )
    TypeText("milk", into: .value(.prefix("Search")))
    """))
    let expected = try HeistPlan(body: [
        .action(ActionStep(command: .activate(.predicate(.identifier(.suffix("field")))))),
        .wait(WaitStep(predicate: .exists(.element(
            .label(.prefix("No results")),
            .identifier(.contains("empty_state")),
            .value(.suffix("items")),
            .hint(.isEmpty)
        )), timeout: 2)),
        .action(ActionStep(command: .typeText(
            text: "milk",
            target: .predicate(.value(.prefix("Search")))
        ))),
    ])

    #expect(plan == expected)
}

@Test func `runtime parser accepts notification predicates`() throws {
    let plan = try HeistSourceParser.parse(root("""
    Activate(.label("Delete")).expect(.notification("Item deleted"))
    WaitFor(.notification(.contains("processed")), timeout: 5)
    WaitFor(.notification)
    WaitFor(.notification(element: .label("Saved")))
    WaitFor(.notification(text: .contains("saved"), element: .element(.label("Saved"), .traits([.staticText]))))
    """))
    let expected = try HeistPlan(body: [
        .action(ActionStep(
            command: .activate(.predicate(.label("Delete"))),
            expectationPolicy: .expect(ActionExpectation(
                predicate: .notification("Item deleted"),
                timeout: .sessionDefault
            ))
        )),
        .wait(WaitStep(predicate: .notification(.contains("processed")), timeout: 5)),
        .wait(WaitStep(predicate: .notification)),
        .wait(WaitStep(predicate: .notification(element: .label("Saved")))),
        .wait(WaitStep(predicate: .notification(
            text: .contains("saved"),
            element: .element(.label("Saved"), .traits([.staticText]))
        ))),
    ])

    #expect(plan == expected)
    try assertCanonicalRoundTrip(plan)
}

@Test func `checked in predicate guidance uses canonical source spellings`() throws {
    let plan = try HeistSourceParser.parse(root("""
    Activate(.label("Pay")).expect(.screenChanged)
    WaitFor(.screenChanged("Receipt"), timeout: 10)
    WaitFor(.screenChanged(.contains("Receipt")))
    WaitFor(.notification)
    WaitFor(.notification(.contains("saved")))
    WaitFor(.notification(text: .contains("saved"), element: .label("Receipt")))
    Increment(.label("Quantity"))
        .expect(.elementsChanged([.updated(
            .label("Quantity"),
            .value(before: "2", after: "3")
        )]))
    """))

    #expect(plan.body.count == 7)
    try assertCanonicalRoundTrip(plan)
}

@Test func `runtime parser accepts container predicates and scoped targets`() throws {
    let plan = try HeistSourceParser.parse(root("""
    WaitFor(.exists(.container(.label("Checkout"))), timeout: 2)
    WaitFor(.exists(.container(.actions(.init(.custom("Archive"))))), timeout: 1)
    WaitFor(.exists(.container(.dataTable(rowCount: .init(3), columnCount: .init(2)))))
    WaitFor(.exists(.container(.matching(.type(.list), .identifier("orders"), .scrollable(true)))))
    WaitFor(.missing(.container(.identifier("Checkout"), ordinal: 1)))
    Activate(.within(container: .label("Checkout"), .label("Pay")))
    """))
    let expected = try HeistPlan(body: [
        .wait(WaitStep(predicate: .exists(.container(.label("Checkout"))), timeout: 2)),
        .wait(WaitStep(predicate: .exists(.container(.actions(.init(.custom("Archive"))))), timeout: 1)),
        .wait(WaitStep(predicate: .exists(.container(.dataTable(
            rowCount: ContainerPredicateCount(3),
            columnCount: ContainerPredicateCount(2)
        ))))),
        .wait(WaitStep(predicate: .exists(.container(.matching(
            .type(.list),
            .identifier("orders"),
            .scrollable(true)
        ))))),
        .wait(WaitStep(predicate: .missing(.container(.identifier("Checkout"), ordinal: 1)))),
        .action(ActionStep(command: .activate(.within(container: .label("Checkout"), .label("Pay"))))),
    ])

    #expect(plan == expected)
    try assertCanonicalRoundTrip(plan)
}

@Test func `runtime parser rejects empty element predicates and matcher payloads`() {
    let cases = [
        ("Activate(.element())", ".element(...) requires at least one non-empty predicate check"),
        (#"Activate(.label(""))"#, "label match value must not be empty"),
        ("Activate(.traits([]))", "traits predicate payload must not be empty"),
        ("Activate(.actions([]))", "actions predicate payload must not be empty"),
        (#"Activate(.actions([.custom("")]))"#, "custom action name must not be blank"),
        ("Activate(.rotors([]))", "rotors predicate payload must not be empty"),
        ("Activate(.customContent(.init()))", "customContent match must include label, value, or isImportant"),
        (
            "WaitFor(.notification(element: .element()))",
            ".element(...) requires at least one non-empty predicate check"
        ),
        (#"WaitFor(.exists(.container(.identifier("Screen"), ordinal: -1)))"#, "ordinal must be non-negative"),
    ]

    for (source, expected) in cases {
        expect(parseError(root(source)), contains: expected)
    }
}

@Test func `runtime parser admits payload values before constructing commands`() {
    let cases = [
        (#"TypeText("")"#, "text to append must be non-empty"),
        (#"SetPasteboard("")"#, "pasteboard text must be non-empty"),
        (
            "longPress(ScreenPoint(x: 1, y: 1), duration: 0)",
            "duration must be"
        ),
        (
            "longPress(ScreenPoint(x: 1, y: 1), duration: 61)",
            "duration must be"
        ),
    ]

    for (source, expected) in cases {
        expect(parseError(root(source)), contains: expected)
    }
}

@Test func `runtime parser rejects malformed and removed container predicate source`() {
    let cases = [
        ("WaitFor(.exists(.container(.matching())))", "container matching predicate requires at least one check"),
        (
            "WaitFor(.exists(.container(.matching(.rowCount(.init(-1))))))",
            "container rowCount must be non-negative"
        ),
        (
            "WaitFor(.exists(.container(.dataTable(rowCount: 3))))",
            "container rowCount must use .init(...)"
        ),
        (
            "WaitFor(.exists(.container(.matching(.rowCount(3)))))",
            "container rowCount must use .init(...)"
        ),
        (
            "WaitFor(.exists(.container(.actions(.init()))))",
            "container actions predicate payload must not be empty"
        ),
        (
            "WaitFor(.exists(.container(.matching(.semantic(.identifier(\"Checkout\"))))))",
            "semantic container predicates accept .label and .value"
        ),
        (
            "WaitFor(.exists(.container(.semantic(.label(\"Checkout\")))))",
            "container predicates accept"
        ),
        (
            "WaitFor(.exists(.container(.type(.scrollable))))",
            "unknown container kind '.scrollable'"
        ),
        (
            "WaitFor(.exists(.container(.scrollable)))",
            "expected '('"
        ),
        (
            "WaitFor(.exists(.container(.dataTable)))",
            "expected '('"
        ),
        (
            "WaitFor(.exists(.container(.modalBoundary(true))))",
            "expected ')'"
        ),
        (
            "WaitFor(.exists(.container(.actions([.custom(\"Archive\")]))))",
            "container actions must use .init(...)"
        ),
    ]

    for (source, expected) in cases {
        expect(parseError(root(source)), contains: expected)
    }
}

@Test func `runtime parser requires canonical dotted enum cases`() throws {
    _ = try HeistSourceParser.parse(root("""
    Activate(.traits([.button]))
    Edit(.paste)
    Rotor("Headings", on: .label("Article"), direction: .previous)
    swipe(.label("List"), .down)
    """))

    let cases = [
        ("Activate(.traits([button]))", "accessibility trait must use canonical dotted enum-case syntax"),
        ("Edit(paste)", "edit action must use canonical dotted enum-case syntax"),
        (
            #"Rotor("Headings", on: .label("Article"), direction: previous)"#,
            "rotor direction must use canonical dotted enum-case syntax"
        ),
        (#"swipe(.label("List"), down)"#, "swipe direction must use canonical dotted enum-case syntax"),
    ]

    for (source, expected) in cases {
        expect(parseError(root(source)), contains: expected)
    }
}
