import ThePlans

extension TheFence.Command {
    static var planSourceParameters: [FenceParameterSpec] {
        [
            FenceParameters.planPath.spec,
            FenceParameters.inlinePlan.spec,
        ]
    }

    static let performDescription = """
        Run one durable ButtonHeist DSL instruction from `step`: one action or one `WaitFor(...)` statement.

        Examples:
        `Activate(.label("Pay")).expect(.screenChanged)`
        `TypeText("milk", into: .label("Search")).expect(.elementsChanged)`
        `Increment(.label("Quantity"))`
        `Decrement(.label("Quantity"))`
        `CustomAction("Archive", on: .label("Message"))`
        `Rotor("Headings", on: .label("Article"))`
        `ScreenActions.Dismiss()`
        `ScreenActions.MagicTap()`
        `SetPasteboard("hello")`
        `Edit(.paste)`
        `dismissKeyboard()`
        `oneFingerTap(.label("Map"))`
        `oneFingerTap(ScreenPoint(x: 888, y: 372))`
        `oneFingerTap(.label("Map"), at: UnitPoint(x: 0.5, y: 0.25))`
        `longPress(.label("Message"), at: UnitPoint(x: 0.5, y: 0.5))`
        `swipe(.label("Carousel"), .left)`
        `drag(.label("Slider"), to: ScreenPoint(x: 200, y: 40))`
        `WaitFor(.label("Checkout"), timeout: 5)`

        Use `perform` when one line is enough. Use `run_heist` when the job needs
        multiple instructions, reusable heists, `RunHeist`, `If`,
        `WaitFor(...).else { ... }`, `ForEach`, `Warn`, or `Fail`.
        """

    static let runHeistDescription = """
        Run a durable heist from a ButtonHeist source plan in `plan`, or from a generated `.heist` package at `path`.

        Author plans as ButtonHeist source, not raw JSON IR:
        `HeistPlan("shop") { ... }`
        `HeistDef<String>("Cart.addItem", parameter: "item") { item in ... }`
        `RunHeist("Cart.addItem", "Milk").expect(.elementsChanged([.appeared(.element(.label("subtotal"), .value(.contains("1 item"))))]))`
        `If(.label("Pay")) { ... }.else { ... }`
        `WaitFor(.screenChanged, timeout: 10).else { ... }`
        `ForEach("Milk", "Bread") { item in ... }`
        `ForEach(.element(.label(.prefix("Delete")), .traits([.button])), limit: 20) { target in ... }`
        `Warn("message")`
        `Fail("message")`

        Provide exactly one source: `path` or `plan`. Use `argument` when the root
        heist takes a string or accessibility target. Runtime source is restricted
        ButtonHeist DSL, not arbitrary Swift.
        """

    static let validateHeistDescription = """
        Validate a durable Button Heist plan without connecting to an app.
        Returns runtime-admission diagnostics, optional authoring lint, and
        canonical source. Provide exactly one of `plan` or `path`. This cannot
        verify live targets or UI outcomes. Call `run_heist` only after
        `admissible` is true.
        """

    static var rootArgumentParameter: FenceParameterSpec {
        objectParam(
            "argument",
            properties: [
                param(
                    "type",
                    .string,
                    required: true,
                    enumValues: [
                        HeistParameterKind.none.rawValue,
                        HeistParameterKind.string.rawValue,
                        HeistParameterKind.accessibilityTarget.rawValue,
                    ]
                ),
                param("value", .string),
                param("value_ref", .string),
                accessibilityTargetParam("target"),
            ],
            additionalProperties: false
        )
    }
}
