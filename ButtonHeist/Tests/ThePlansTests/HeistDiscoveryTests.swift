import Foundation
import ButtonHeistTestSupport
import Testing
@_spi(ButtonHeistInternals) import ThePlans

private func invocation(_ dottedName: String) -> HeistInvocationPath {
    do {
        return try HeistInvocationPath(validating: dottedName)
    } catch {
        preconditionFailure("invalid discovery fixture path \(dottedName): \(error)")
    }
}

private func existsLabel(_ label: String) -> AccessibilityPredicate {
    .exists(.label(label))
}

private let screenChangePredicate = AccessibilityPredicate.screenChanged

@Test func `discovery includes root entry`() throws {
    let descriptions = try HeistPlan(
        name: "checkout",
        body: [.warn(WarnStep(message: "ready"))]
    ).heistDescriptions()

    #expect(descriptions.map { $0.identity.displayName } == ["checkout"])
    #expect(descriptions[0].role == .entry)
    #expect(descriptions[0].parameterKind == .none)
    #expect(descriptions[0].requiresArgument == false)
    #expect(descriptions[0].parameterName == nil)
}

@Test func `discovery includes unparameterized definition`() throws {
    let descriptions = try HeistPlan(
        name: "root",
        definitions: [
            try HeistPlan(name: "openCart", body: [.warn(WarnStep(message: "open"))]),
        ],
        body: [.warn(WarnStep(message: "ready"))]
    ).heistDescriptions()

    #expect(descriptions.map { $0.identity.displayName } == ["root", "openCart"])
    #expect(descriptions[0].role == .entry)
    #expect(descriptions[1].role == .capability)
    #expect(descriptions[1].parameterKind == .none)
    #expect(descriptions[1].requiresArgument == false)
    #expect(descriptions[1].parameterName == nil)
}

@Test func `discovery includes string definition`() throws {
    let descriptions = try HeistPlan(
        name: "root",
        definitions: [
            HeistPlan(
                name: "addToCart",
                parameter: .string(name: "item"),
                body: [
                    .action(ActionStep(command: .activate(.predicate(
                        .label(HeistReferenceName(stringLiteral: "item"))
                    )))),
                ]
            ),
        ],
        body: [.warn(WarnStep(message: "ready"))]
    ).heistDescriptions()

    #expect(descriptions[1].identity.displayName == "addToCart")
    #expect(descriptions[1].role == .capability)
    #expect(descriptions[1].parameterKind == .string)
    #expect(descriptions[1].requiresArgument == true)
    #expect(descriptions[1].parameterName == "item")
}

@Test func `discovery includes element target definition`() throws {
    let descriptions = try HeistPlan(
        name: "root",
        definitions: [
            HeistPlan(
                name: "tapRow",
                parameter: .accessibilityTarget(name: "row"),
                body: [
                    .action(ActionStep(command: .activate(.ref("row")))),
                ]
            ),
        ],
        body: [.warn(WarnStep(message: "ready"))]
    ).heistDescriptions()

    #expect(descriptions[1].identity.displayName == "tapRow")
    #expect(descriptions[1].role == .capability)
    #expect(descriptions[1].parameterKind == .accessibilityTarget)
    #expect(descriptions[1].requiresArgument == true)
    #expect(descriptions[1].parameterName == "row")
}

@Test func testDiscoveryPreservesFirstOccurrenceOrder() throws {
    let plan = try detailedSurfacePlan()
    let descriptions = try plan.heistDescriptions()
    let checkout = try #require(descriptions.first { $0.identity.displayName == "checkout" })

    #expect(descriptions.map(\.identity.displayName) == ["root", "checkout", "checkout.confirm"])
    #expect(checkout.parameterName == nil)
    #expect(checkout.semanticSurface.nestedRunHeists == [invocation("checkout.confirm")])
    #expect(checkout.semanticSurface.actionCommands == [.activate])
    #expect(checkout.semanticSurface.waits.count == 1)
    #expect(checkout.semanticSurface.expectations.count == 1)
    #expect(checkout.semanticSurface.semanticSurfaces == [
        .label(.exact("Checkout")),
        .label(.exact("Done")),
        .label(.exact("Confirm")),
        .identifier(.exact("confirmation_button")),
        .traits([.button]),
    ])

    let description = try plan.describeHeist(at: "checkout")
    #expect(description.identity == .capability("checkout"))
    #expect(description.semanticSurface.actionCommands == [.activate])
    #expect(description.semanticSurface.targetPredicates == [
        .predicate(.label("Checkout")),
        .predicate(.label("Done")),
        .predicate(.label("Confirm")),
        .predicate(ElementPredicate(identifier: .exact("confirmation_button"), traits: [.button])),
    ])
    #expect(description.semanticSurface.waits == [existsLabel("Confirm")])
    #expect(description.semanticSurface.expectations == [existsLabel("Done")])
    #expect(description.semanticSurface.nestedRunHeists == [invocation("checkout.confirm")])
    #expect(description.semanticSurface.expectedEffects == [existsLabel("Confirm"), existsLabel("Done")])
    #expect(description.semanticSurface.semanticSurfaces == checkout.semanticSurface.semanticSurfaces)
}

@Test func `discovery includes parameter name for parameterized capability`() throws {
    let descriptions = try HeistPlan(
        name: "root",
        definitions: [
            HeistPlan(
                name: "tapRow",
                parameter: .accessibilityTarget(name: "row"),
                body: [
                    .action(ActionStep(command: .activate(.ref("row")))),
                ]
            ),
        ],
        body: [.warn(WarnStep(message: "ready"))]
    ).heistDescriptions()

    let tapRow = try #require(descriptions.first { $0.identity.displayName == "tapRow" })
    #expect(tapRow.parameterName == "row")
    #expect(tapRow.parameterKind == .accessibilityTarget)
    #expect(tapRow.requiresArgument)
    #expect(tapRow.semanticSurface.semanticSurfaces.isEmpty)
}

@Test func `semantic discovery structurally dedupes before catalog projection`() throws {
    let duplicateTemplate = ElementPredicate([
        .label("Pay"),
        .label("Pay"),
        .traits([.link, .button]),
        .traits([.button, .link]),
    ])
    let descriptions = try HeistPlan(
        name: "pay",
        body: [
            .action(ActionStep(command: .activate(.predicate(.label("Pay"))))),
            .action(ActionStep(command: .activate(.predicate(duplicateTemplate)))),
        ]
    ).heistDescriptions()

    let pay = try #require(descriptions.first)
    #expect(pay.semanticSurface.actionCommands == [.activate])
    #expect(pay.semanticSurface.semanticSurfaces == [
        .label(.exact("Pay")),
        .traits([.button, .link]),
    ])
}

@Test func `target discovery dedupes authored predicates structurally`() throws {
    let description = try HeistPlan(
        name: "pay",
        body: [
            .action(ActionStep(command: .activate(.label("Pay")))),
            .action(ActionStep(command: .activate(.predicate(.label("Pay"))))),
        ]
    ).describeHeist(at: "pay")

    #expect(description.semanticSurface.targetPredicates == [.predicate(.label("Pay"))])
    #expect(description.semanticSurface.semanticSurfaces == [.label(.exact("Pay"))])
}

@Test func `target discovery dedupes typed facts after ordinal projection`() throws {
    let description = try HeistPlan(
        name: "pay",
        body: [
            .action(ActionStep(command: .activate(.target(.label("Pay"), ordinal: 0)))),
            .action(ActionStep(command: .activate(.target(.label("Pay"), ordinal: 1)))),
        ]
    ).describeHeist(at: "pay")

    #expect(description.semanticSurface.targetPredicates == [.predicate(.label("Pay"))])
}

@Test func `list heists cannot be reached for invalid raw plan`() throws {
    #expect(throws: HeistPlanBuildError.self) {
        _ = try HeistSourceCompilation.compile("""
        HeistPlan("root") {
            HeistDef<Void>("duplicate") { Warn("one") }
            HeistDef<Void>("duplicate") { Warn("two") }
            Warn("ready")
        }
        """)
    }
}

@Test func `catalog rejects entry and capability sharing one lookup path`() throws {
    let plan = try HeistPlan(
        name: "checkout",
        definitions: [
            try HeistPlan(name: "checkout", body: [.warn(WarnStep(message: "nested"))]),
        ],
        body: [.warn(WarnStep(message: "root"))]
    )

    #expect(throws: HeistCatalogError.self) {
        _ = try plan.heistDescriptions()
    }
}

@Test func `discovery includes parameterized root entry`() throws {
    let descriptions = try HeistPlan(
        name: "root",
        parameter: .string(name: "item"),
        body: [
            .action(ActionStep(command: .typeText(
                reference: "item",
                target: .label("Search")
            ))),
        ]
    ).heistDescriptions()

    let root = try #require(descriptions.first)
    #expect(root.identity.displayName == "root")
    #expect(root.role == .entry)
    #expect(root.parameterKind == .string)
    #expect(root.requiresArgument)
    #expect(root.parameterName == "item")
}

@Test func `describe root entry`() throws {
    let description = try HeistPlan(
        name: "checkout",
        body: [.warn(WarnStep(message: "ready"))]
    ).describeHeist(at: "checkout")

    #expect(description.identity.displayName == "checkout")
    #expect(description.role == .entry)
    #expect(description.parameterKind == .none)
    #expect(description.requiresArgument == false)
}

@Test func `describe parameterized capability`() throws {
    let description = try HeistPlan(
        name: "root",
        definitions: [
            HeistPlan(
                name: "addToCart",
                parameter: .string(name: "item"),
                body: [
                    .action(ActionStep(command: .activate(.predicate(
                        .label(HeistReferenceName(stringLiteral: "item"))
                    )))),
                ]
            ),
        ],
        body: [.warn(WarnStep(message: "ready"))]
    ).describeHeist(at: "addToCart")

    #expect(description.role == .capability)
    #expect(description.parameterKind == .string)
    #expect(description.parameterName == "item")
    #expect(description.requiresArgument)
}

@Test func `describe action targets and predicates`() throws {
    let description = try HeistPlan(
        name: "activateSave",
        body: [
            .action(ActionStep(command: .activate(.predicate(.identifier("save_button"))))),
        ]
    ).describeHeist(at: "activateSave")

    #expect(description.semanticSurface.actionCommands == [.activate])
    #expect(description.semanticSurface.targetPredicates == [.predicate(.identifier("save_button"))])
}

@Test func `describe waits expectations and expected effects`() throws {
    let notification = AccessibilityPredicate.notification(
        text: .contains("saved"),
        element: .identifier("save_status")
    )
    let description = try HeistPlan(
        name: "submit",
        body: [
            .action(ActionStep(
                command: .activate(.predicate(.label("Submit"))),
                expectationPolicy: .expect(ActionExpectation(predicate: .exists(.label("Done")), timeout: 1)))),
            .wait(WaitStep(predicate: .screenChanged, timeout: 2)),
            .wait(WaitStep(predicate: notification, timeout: 2)),
        ]
    ).describeHeist(at: "submit")

    #expect(description.semanticSurface.expectations == [existsLabel("Done")])
    #expect(description.semanticSurface.waits == [screenChangePredicate, notification])
    #expect(description.semanticSurface.expectedEffects == [
        screenChangePredicate,
        notification,
        existsLabel("Done"),
    ])
    #expect(description.semanticSurface.targetPredicates == [
        .predicate(.label("Submit")),
        .predicate(.label("Done")),
        .predicate(.identifier("save_status")),
    ])
    #expect(description.semanticSurface.semanticSurfaces == [
        .label(.exact("Submit")),
        .label(.exact("Done")),
        .identifier(.exact("save_status")),
    ])
}

@Test func `describe expected effects dedupes typed predicates before projection`() throws {
    let description = try HeistPlan(
        name: "submit",
        body: [
            .action(ActionStep(
                command: .activate(.predicate(.label("Submit"))),
                expectationPolicy: .expect(ActionExpectation(predicate: .exists(.label("Done")), timeout: 1)))),
            .wait(WaitStep(predicate: .exists(.label("Done")), timeout: 2)),
        ]
    ).describeHeist(at: "submit")

    #expect(description.semanticSurface.expectations == [existsLabel("Done")])
    #expect(description.semanticSurface.waits == [existsLabel("Done")])
    #expect(description.semanticSurface.expectedEffects == [existsLabel("Done")])
}

@Test func `describe missing name reports available names`() throws {
    let plan = try HeistPlan(
        name: "root",
        definitions: [
            try HeistPlan(name: "openCart", body: [.warn(WarnStep(message: "open"))]),
        ],
        body: [.warn(WarnStep(message: "ready"))]
    )

    do {
        _ = try plan.describeHeist(at: "checkout")
        Issue.record("Expected missing heist diagnostic")
    } catch let error as HeistDescriptionLookupError {
        #expect(error.availableIdentities.map(\.displayName) == ["root", "openCart"])
        #expect(error.description.contains("checkout"))
    }
}

private func detailedSurfacePlan() throws -> HeistPlan {
    try HeistPlan(
        name: "root",
        definitions: [
            try HeistPlan(
                name: "checkout",
                definitions: [
                    try HeistPlan(
                        name: "confirm",
                        body: [
                            .action(ActionStep(command: .activate(.predicate(ElementPredicate(
                                identifier: .exact("confirmation_button"),
                                traits: [.button]
                            ))))),
                        ]
                    ),
                ],
                body: [
                    .action(ActionStep(
                        command: .activate(.predicate(.label("Checkout"))),
                        expectationPolicy: .expect(ActionExpectation(predicate: .exists(.label("Done")), timeout: 1)))),
                    .wait(WaitStep(predicate: .exists(.label("Confirm")), timeout: 1)),
                    .invoke(HeistInvocationStep(path: "confirm")),
                ]
            ),
        ],
        body: [.warn(WarnStep(message: "ready"))]
    )
}
