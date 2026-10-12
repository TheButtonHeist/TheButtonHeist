import Testing
@testable import ThePlans

func assertCanonicalRoundTrip(_ plan: HeistPlan) throws {
    let source = try plan.canonicalSwiftDSL()
    let parsed = try HeistSourceParser.parse(source)
    #expect(parsed == plan, "Rendered source did not parse back to the same plan:\n\(source)")
}

func parseError(_ source: String) -> String {
    do {
        _ = try HeistSourceParser.parse(source)
        Issue.record("Expected source to fail: \(source)")
        return ""
    } catch {
        return String(describing: error)
    }
}

func parseDiagnostic(_ source: String) -> HeistBuildDiagnostic {
    do {
        _ = try HeistSourceParser.parse(source)
        Issue.record("Expected source to fail: \(source)")
        return HeistBuildDiagnostic(
            externalBoundaryRawCode: "test.missing_diagnostic",
            phase: .sourceCompilation,
            message: "Expected source to fail"
        )
    } catch let error {
        return error.diagnostics.first ?? HeistBuildDiagnostic(
            externalBoundaryRawCode: "test.missing_diagnostic",
            phase: .sourceCompilation,
            message: "Source parsing failed without diagnostics"
        )
    }
}

func root(_ body: String) -> String {
    """
    HeistPlan {
    \(body)
    }
    """
}

func expect(_ string: String, contains substring: String) {
    if !string.contains(substring) {
        Issue.record("Expected error to contain '\(substring)', got: \(string)")
    }
    #expect(string.contains(substring))
}

@Test func `inline plan source RunHeist syntax validates through normal runtime pipeline`() throws {
    let diagnostic = parseDiagnostic(root("""
    RunHeist("CartScreen.checkout")
    """))

    #expect(diagnostic.code.rawValue == "heist.plan.runtime_safety")
    #expect(diagnostic.kind == .error)
    #expect(diagnostic.phase == .planValidation)
    #expect(diagnostic.path == "$.body[0].invoke.path")
}

@Test func `non-durable action admission exposes source diagnostic code and path`() throws {
    let diagnostics: [HeistBuildDiagnostic]
    do {
        _ = try HeistPlan(body: [
            .action(ActionStep(command: .scroll(ScrollTarget(direction: .down)))),
        ])
        Issue.record("Expected non-durable action to fail runtime safety admission")
        return
    } catch let error as HeistPlanBuildError {
        diagnostics = error.diagnostics
    }
    let diagnostic = try #require(diagnostics.first)

    #expect(diagnostics.count == 1)
    #expect(diagnostic.code == .nonDurableAction)
    #expect(diagnostic.code.rawValue == "heist.plan.non_durable_action")
    #expect(diagnostic.kind == .error)
    #expect(diagnostic.phase == .planValidation)
    #expect(diagnostic.path == "$.body[0].action.command")
    #expect(
        diagnostic.message ==
            "durable heist action; observed scroll is a direct client command, " +
            "not a durable heist action"
    )
    #expect(diagnostic.hint == nonDurableHeistActionRepairHint)
}

@Test func `inline plan source unsupported Swift syntax is rejected`() throws {
    for source in [
        "let x = 1",
        "FileManager.default",
        "Process()",
        #"await Warn("x")"#,
    ] {
        #expect(throws: HeistPlanBuildError.self) {
            _ = try HeistSourceParser.parse(source)
        }
    }
}

@Test func `inline plan source syntax errors expose typed diagnostic fields`() throws {
    let diagnostic = parseDiagnostic("""
    HeistPlan {
        let label = "Pay"
        Activate(.label(label))
    }
    """)

    #expect(diagnostic.code.rawValue == "heist.source.invalid_syntax")
    #expect(diagnostic.kind == .error)
    #expect(diagnostic.phase == .sourceCompilation)
    #expect(diagnostic.sourceSpan?.sourceName == "inline-heist-plan")
    #expect(diagnostic.sourceSpan?.line == 2)
    #expect(diagnostic.sourceSpan?.column == 5)
}

private func assertCanonicalSourceRoundTripPreservesBranchSemantics() throws {
    let source = """
    HeistPlan {
        If {
            Case(.exists(.label("Pay"))) {
                Warn("primary")
            }
            Case(.missing(.label("Pay"))) {
                Fail("missing")
            }
            Else {
                Warn("fallback")
            }
        }
    }
    """
    let plan = try HeistSourceParser.parse(source)
    let reparsed = try HeistSourceParser.parse(plan.canonicalSwiftDSL())

    #expect(reparsed == plan)
    guard case .conditional(let branches) = plan.body.first else {
        Issue.record("Expected the canonical source to preserve its conditional")
        return
    }
    #expect(branches.cases.map(\.predicate) == [.exists(.label("Pay")), .missing(.label("Pay"))])
    #expect(branches.cases.map(\.body) == [
        [.warn(WarnStep(message: "primary"))],
        [.fail(FailStep(message: "missing"))],
    ])
    #expect(branches.elseBody == [.warn(WarnStep(message: "fallback"))])
}

@Test func testCanonicalSourceRoundTripPreservesDiagnosticSpan() throws {
    try assertCanonicalSourceRoundTripPreservesBranchSemantics()
    let removedSpellings: [(String, String, Int)] = [
        (
            #"WaitFor(.present(.label("Receipt")))"#,
            "unsupported accessibility predicate '.present'",
            21
        ),
        ("WaitFor(.change(.screen()))", "unsupported accessibility predicate '.change'", 21),
        ("WaitFor(.notification())", "empty notification predicate must use .notification", 34),
        (
            #"WaitFor(.notification(containing: "done"))"#,
            "expected a string literal or scoped string reference",
            34
        ),
        (
            #"WaitFor(.elementsChanged([.updated(.label("Total"), .label(before: "Old", after: "New"))]))"#,
            "unsupported element update property '.label'. Valid: value, traits, hint, actions, customContent, rotors",
            70
        ),
        (
            #"WaitFor(.elementsChanged([.updated(.label("Total"), .identifier(before: "old", after: "new"))]))"#,
            "unsupported element update property '.identifier'. Valid: value, traits, hint, actions, customContent, rotors",
            75
        ),
        (
            #"WaitFor(.elementsChanged([.updated(.label("Total"), .value(from: "$2", to: "$3"))]))"#,
            "value update predicate accepts before and after",
            71
        ),
        (
            #"WaitFor(.elementsChanged([.updated(.label("Total"), .traits(after: .include([.selected])))]))"#,
            "trait set match must use .init(...)",
            80
        ),
        (
            #"WaitFor(.elementsChanged([.updated(.identifier("item"), .actions(after: .exclude([.activate])))]))"#,
            "action set match must use .init(...)",
            85
        ),
        (
            #"WaitFor(.elementsChanged([.updated(.identifier("item"), .customContent(after: .match(label: "Status")))]))"#,
            "custom content match must use .init(...)",
            91
        ),
        (
            #"WaitFor(.elementsChanged([.updated(.identifier("item"), .rotors(after: .include(["Headings"])))]))"#,
            "rotor set match must use .init(...)",
            84
        ),
        (#"WaitFor(.change(.appeared(.label("Toast"))))"#, "unsupported accessibility predicate '.change'", 21),
        (
            #"Activate(.label(.exact("Search")))"#,
            #"exact label matches use the literal form: .label("...")"#,
            28
        ),
        (
            #"Activate(.element(label: "Pay", traits: [.button]))"#,
            #".element(...) accepts ordered checks like .label("Pay"), .identifier("id"), "# +
                #".traits([.button]), .actions([.activate]), .exclude(.traits([.notEnabled]))"#,
            30
        ),
        (#"Tap(.label("Pay"))"#, "unsupported ButtonHeist source statement 'Tap'", 12),
        (
            #"Activate("Pay")"#,
            "target expression requires an explicit accessibility property such as .label(...)",
            21
        ),
        (
            #"WaitFor("Receipt")"#,
            "expected a ButtonHeist expression beginning with '.'",
            20
        ),
    ]

    for (statement, message, offset) in removedSpellings {
        let invalidSource = "HeistPlan { \(statement) }"
        let diagnostic = parseDiagnostic(invalidSource)
        #expect(diagnostic.code == .sourceInvalidSyntax)
        #expect(diagnostic.message == message)
        #expect(diagnostic.sourceSpan == HeistBuildSourceSpan(
            sourceName: "inline-heist-plan",
            offset: offset,
            line: 1,
            column: offset + 1,
            length: 1
        ))
    }
}

@Test func `canonical ForEach string parses without body try`() throws {
    let plan = try HeistSourceParser.parse(root("""
    ForEach("a") { item in
        TypeText(item)
    }
    """))
    let expected = try HeistPlan(body: [
        .forEachString(try ForEachStringStep(
            values: ["a"],
            parameter: "item",
            body: [
                .action(ActionStep(command: .typeText(reference: "item", target: nil))),
            ]
        )),
    ])

    #expect(plan == expected)
}

@Test func `inline plan source import Foundation is rejected`() throws {
    #expect(throws: HeistPlanBuildError.self) {
        _ = try HeistSourceParser.parse("""
        import Foundation
        Activate(.label("Pay"))
        """)
    }
}

@Test func `inline plan source while true is rejected`() throws {
    #expect(throws: HeistPlanBuildError.self) {
        _ = try HeistSourceParser.parse("""
        while true {
            Activate(.label("Pay"))
        }
        """)
    }
}

@Test func `inline plan source arbitrary function declaration is rejected`() throws {
    #expect(throws: HeistPlanBuildError.self) {
        _ = try HeistSourceParser.parse("""
        func pay() {
            Activate(.label("Pay"))
        }
        """)
    }
}

private let nonDurableHeistActionRepairHint =
    "Use a direct client command for debug/session actions, or replace " +
    "this with a canonical durable DSL action."

@Test func `runtime source parsing rejects standard definition cap`() throws {
    let definitions = (0...250).map { index in
        """
            HeistDef<String>("Definitions.definition\(index)", parameter: "value") { value in
                Activate(.label(value))
            }
        """
    }.joined(separator: "\n\n")
    let source = """
    HeistPlan("tooManyDefinitions") {
    \(definitions)

        Warn("body")
    }
    """

    let diagnostic = parseError(source)

    expect(diagnostic, contains: "max total heist definitions")
    expect(diagnostic, contains: "252 definitions")

    let typedDiagnostic = parseDiagnostic(source)
    #expect(typedDiagnostic.code.rawValue == "heist.plan.runtime_safety")
    #expect(typedDiagnostic.phase == .planValidation)
    #expect(typedDiagnostic.path == "$.definitions[0].definitions")
    #expect(typedDiagnostic.hint == "Use 250 definitions or fewer.")
}
