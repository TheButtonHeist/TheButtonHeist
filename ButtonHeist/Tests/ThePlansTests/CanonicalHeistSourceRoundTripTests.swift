import Testing
import ThePlans

@Suite("Canonical Heist Source Round Trip")
struct CanonicalHeistSourceRoundTripTests {
    @Test("actions, targets, expectations, and waivers round trip")
    func actionsTargetsExpectationsAndWaiversRoundTrip() throws {
        try assertRoundTrip(try HeistPlan(body: [
            .action(ActionStep(
                command: .activate(.predicate(.label("Pay"))),
                expectationPolicy: .expect(ActionExpectation(predicate: .screenChanged, timeout: 0.001)))),
            .action(ActionStep(
                command: .typeText(text: "milk", target: .predicate(.label("Search"))),
                expectationPolicy: .expect(ActionExpectation(predicate: .exists(.element(.label("Search"), .value("milk"))), timeout: 2)))),
            .action(ActionStep(
                command: .typeText(text: "Bruschetta", target: .predicate(.identifier("Search"))),
                expectationPolicy: .expect(ActionExpectation(predicate: .elementsChanged([
                    .updated(.identifier("Search"), .value(after: "Bruschetta")),
                ]))))),
            .action(ActionStep(
                command: .activate(.predicate(.label("Add item"))),
                expectationPolicy: .expect(ActionExpectation(predicate: .elementsChanged([
                    .appeared(.label("Milk")),
                ]))))),
            .action(ActionStep(
                command: .activate(.predicate(.label("Remove"))),
                expectationPolicy: .expect(ActionExpectation(predicate: .elementsChanged([
                    .disappeared(.identifier("row-1")),
                ]))))),
            .action(ActionStep(
                command: .typeText(text: "milk", target: .predicate(.identifier("Search"))),
                expectationPolicy: .expect(ActionExpectation(predicate: .elementsChanged([
                    .updated(.identifier("Search"), .value(before: "", after: "milk")),
                ]))))),
            .action(ActionStep(
                command: .activate(.predicate(.identifier("Favorite"))),
                expectationPolicy: .expect(ActionExpectation(predicate: .elementsChanged([
                    .updated(
                        .identifier("Favorite"),
                        .traits(before: .init(exclude: [.selected]), after: .init(include: [.selected]))
                    ),
                ]))))),
            .action(ActionStep(command: .increment(.predicate(.identifier("quantity"))))),
            .action(ActionStep(command: .decrement(.predicate(.identifier("quantity"), ordinal: 0)))),
            .action(ActionStep(command: .customAction(
                name: "Archive",
                target: .predicate(.element(.label("Message"), .traits([.button])))
            ))),
            .action(ActionStep(command: .rotor(
                selection: .named("Headings"),
                target: .predicate(.label("Article")),
                direction: .next
            ))),
            .action(ActionStep(command: .setPasteboard(SetPasteboardTarget(text: "milk")))),
            .action(ActionStep(command: .takeScreenshot)),
            .action(ActionStep(command: .dismiss)),
            .action(ActionStep(command: .magicTap)),
            .action(ActionStep(command: .editAction(EditActionTarget(action: .paste)))),
            .action(ActionStep(command: .dismissKeyboard)),
            .action(ActionStep(
                command: .activate(.predicate(.label("Optional"))),
                expectationPolicy: .waived("No durable semantic outcome"))),
        ]))
    }

    @Test("canonical source renders shortest unambiguous sugar")
    func canonicalSourceRendersShortestUnambiguousSugar() throws {
        let plan = try HeistPlan {
            Activate(.label("Add"))
                .expect(.elementsChanged([.appeared(.label("Toast"))]))

            TypeText("milk", into: .label("Search"))
                .expect(.elementsChanged([.updated(.label("Search"), .value("milk"))]))

            WaitFor(.exists(.label("Results")), timeout: 2)

            If(.exists(.value(.contains("Promo")))) {
                Warn("promo")
            }

            ForEach("Milk", "Eggs") { item in
                Activate(.label(item))
            }

            ForEach(.label("Delete"), limit: 2) { target in
                Activate(target)
                    .expect(.missing(target))
            }
        }

        #expect(try plan.canonicalSwiftDSL() == """
        HeistPlan {
            Activate(.label("Add"))
                .expect(.elementsChanged([.appeared(.label("Toast"))]))

            TypeText("milk", into: .label("Search"))
                .expect(.elementsChanged([.updated(.label("Search"), .value("milk"))]))

            WaitFor(.exists(.label("Results")), timeout: 2)

            If(.exists(.value(.contains("Promo")))) {
                Warn("promo")
            }

            ForEach("Milk", "Eggs") { item in
                Activate(.label(item))
            }

            ForEach(.label("Delete"), limit: 2) { target in
                Activate(target)
                    .expect(.missing(target))
            }
        }
        """)
    }

    @Test("authored references render through one canonical source spelling")
    func authoredReferencesRenderCanonically() throws {
        let item: HeistReferenceName = "item"
        let plan = try HeistPlan(
            name: "search",
            parameter: .string(name: item),
            body: [
                .action(ActionStep(
                    command: .typeText(
                        reference: item,
                        target: .label(.contains(item))
                    ),
                    expectationPolicy: .expect(ActionExpectation(
                        predicate: .exists(.within(
                            container: .identifier(item),
                            .label(item)
                        )),
                        timeout: 1
                    ))
                )),
            ]
        )

        let source = try plan.canonicalSwiftDSL()
        #expect(source == """
        HeistPlan("search", parameter: "item") { item in
            TypeText(item, into: .label(.contains(item)))
                .expect(.exists(.within(container: .identifier(item), .label(item))), timeout: 1)
        }
        """)
        #expect(try HeistSourceParser.parse(source) == plan)
    }

    @Test("durable spatial gesture actions round trip")
    func durableMechanicalActionsRoundTrip() throws {
        try assertRoundTrip(try HeistPlan(body: [
            .action(ActionStep(command: .oneFingerTap(TapTarget(
                selection: .coordinate(ScreenPoint(x: 12, y: 34))
            )))),
            .action(ActionStep(command: .longPress(LongPressTarget(
                selection: .coordinate(ScreenPoint(x: 20, y: 40)),
                duration: 1
            )))),
            .action(ActionStep(command: .swipe(SwipeTarget(selection: .elementDirection(
                .label("List"),
                .down
            ))))),
            .action(ActionStep(command: .swipe(SwipeTarget(selection: .unitElement(
                .label("Carousel"),
                start: UnitPoint(x: 0.8, y: 0.5),
                end: UnitPoint(x: 0.2, y: 0.5)
            ))))),
            .action(ActionStep(command: .drag(DragTarget(
                selection: .pointToPoint(start: ScreenPoint(x: 10, y: 10), end: ScreenPoint(x: 100, y: 100))
            )))),
        ]))
    }

    @Test("waits, conditionals, loops, warnings, and failures round trip")
    func controlsWarningsAndFailuresRoundTrip() throws {
        try assertRoundTrip(try HeistPlan(body: [
            .wait(WaitStep(predicate: .exists(.label("Home")), timeout: 1)),
            .conditional(try ConditionalStep(
                cases: [
                    PredicateCase(predicate: .exists(.label("Pay")), body: [
                        .action(ActionStep(command: .activate(.predicate(.label("Pay"))))),
                    ]),
                ],
                elseBody: [.fail(FailStep(message: "Pay button missing"))]
            )),
            .wait(WaitStep(
                predicate: .screenChanged,
                timeout: 3,
                elseBody: [.fail(FailStep(message: "screen did not change"))]
            )),
            .repeatUntil(try RepeatUntilStep(
                predicate: .exists(.value("2")),
                timeout: 4,
                body: [
                    .action(ActionStep(command: .increment(.predicate(.identifier("Quantity"))))),
                ]
            )),
            .warn(WarnStep(message: "screen changed")),
            .forEachString(try ForEachStringStep(
                values: ["Milk", "Eggs"],
                parameter: "item",
                body: [
                    .action(ActionStep(command: .typeText(
                        reference: "item",
                        target: .predicate(.label("Add item"))
                    ))),
                ]
            )),
            .forEachElement(try ForEachElementStep(
                matching: .element(.label("Delete"), .traits([.button])),
                limit: 2,
                parameter: "target",
                body: [
                    .action(ActionStep(
                        command: .activate(.ref("target")),
                        expectationPolicy: .expect(ActionExpectation(predicate: .missing(.ref("target")), timeout: 2)))),
                ]
            )),
            .warn(WarnStep(message: "done")),
            .fail(FailStep(message: "stop")),
        ]))
    }

    @Test("definitions, parameters, and RunHeist composition round trip")
    func definitionsParametersAndCompositionRoundTrip() throws {
        let tapDefinition = try HeistPlan(
            name: "tap",
            body: [.action(ActionStep(command: .activate(.predicate(.label("Add to Cart")))))]
        )
        let addButtonNamespace = try HeistPlan(name: "AddButton", definitions: [tapDefinition], body: [])
        let addToCart = try HeistPlan(
            name: "addToCart",
            parameter: .string(name: "item"),
            definitions: [addButtonNamespace],
            body: [
                .action(ActionStep(
                    command: .activate(.predicate(.label(HeistReferenceName(stringLiteral: "item")))),
                    expectationPolicy: .expect(ActionExpectation(predicate: .exists(.label("Added")), timeout: 2)))),
                .invoke(HeistInvocationStep(path: "AddButton.tap")),
            ]
        )
        let targetDefinition = try HeistPlan(
            name: "archive",
            parameter: .accessibilityTarget(name: "row"),
            body: [
                .action(ActionStep(command: .customAction(name: "Archive", target: .ref("row")))),
            ]
        )
        let library = try HeistPlan(name: "LibraryScreen", definitions: [addToCart, targetDefinition], body: [])
        let plan = try HeistPlan(
            name: "purchaseFlow",
            definitions: [library],
            body: [
                .invoke(HeistInvocationStep(
                    path: "LibraryScreen.addToCart",
                    argument: .string("Milk")
                )),
                .invoke(HeistInvocationStep(
                    path: "LibraryScreen.archive",
                    argument: .accessibilityTarget(.predicate(.label("Milk")))
                )),
            ]
        )

        try assertRoundTrip(plan)
    }

    private func assertRoundTrip(_ plan: HeistPlan) throws {
        let source = try plan.canonicalSwiftDSL()
        let parsed = try HeistSourceParser.parse(source)
        #expect(parsed == plan, "Canonical source failed round trip:\n\(source)")
    }
}
