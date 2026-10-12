import Foundation
import Testing
@testable import ThePlans

@Test func testAllPublicBoundariesAdmitOneHeistPlan() throws {
    let cases = [
        PublicBoundaryAdmissionCase(
            boundary: "JSON",
            expectedContract: "heist run path must resolve to a local capability"
        ) {
            try JSONDecoder().decode(HeistPlan.self, from: Data("""
            {
              "version": 3,
              "body": [
                {
                  "type": "invoke",
                  "invoke": { "path": "Missing" }
                }
              ]
            }
            """.utf8))
        },
        PublicBoundaryAdmissionCase(
            boundary: "Swift DSL",
            expectedContract: "heist run path must resolve"
        ) {
            let caller = HeistDef<Void>("caller") {
                RunHeist("missing")
            }
            return try HeistPlan {
                caller
                try caller()
            }
        },
        PublicBoundaryAdmissionCase(
            boundary: "source parsing",
            expectedContract: "max nested step depth"
        ) {
            try HeistSourceParser.parse(deeplyNestedSource)
        },
        PublicBoundaryAdmissionCase(
            boundary: "source parsing cycle",
            expectedContract: "heist runs must not be recursive"
        ) {
            try HeistSourceParser.parse(recursiveSource)
        },
        PublicBoundaryAdmissionCase(
            boundary: "live composition",
            expectedContract: "max total heist steps"
        ) {
            try HeistPlan(body: Array(
                repeating: .warn(WarnStep(message: "step")),
                count: 501
            ))
        },
        PublicBoundaryAdmissionCase(
            boundary: "Swift DSL expansion",
            expectedContract: "max total heist steps"
        ) {
            let expanded = HeistDef<Void>("expanded") {
                HeistContent(Array(
                    repeating: .warn(WarnStep(message: "expanded")),
                    count: 170
                ))
            }
            return try HeistPlan {
                expanded
                try expanded()
                try expanded()
            }
        },
    ]

    for testCase in cases {
        do {
            _ = try testCase.admit()
            Issue.record("\(testCase.boundary) accepted an unsafe plan")
        } catch let error as HeistPlanBuildError {
            #expect(
                error.diagnostics.contains { $0.message.contains(testCase.expectedContract) },
                "\(testCase.boundary): \(error)"
            )
        } catch {
            Issue.record("\(testCase.boundary) bypassed canonical diagnostics: \(error)")
        }
    }
}

private struct PublicBoundaryAdmissionCase {
    let boundary: String
    let expectedContract: String
    let admit: () throws -> HeistPlan
}

private let deeplyNestedSource: String = {
    let nesting = 17
    return """
    HeistPlan {
    \(String(repeating: "If(.exists(.label(\"Home\"))) {\n", count: nesting))
    Warn("nested")
    \(String(repeating: "}\n", count: nesting))
    }
    """
}()

private let recursiveSource = """
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
"""

@Test func `name and path currencies use one single value wire shape`() throws {
    let planName: HeistPlanName = "Cart"
    let definitionPath: HeistDefinitionPath = "Cart.addItem"
    let invocationPath: HeistInvocationPath = "Cart.addItem"
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    #expect(String(bytes: try encoder.encode(planName), encoding: .utf8) == #""Cart""#)
    #expect(String(bytes: try encoder.encode(definitionPath), encoding: .utf8) == #""Cart.addItem""#)
    #expect(String(bytes: try encoder.encode(invocationPath), encoding: .utf8) == #""Cart.addItem""#)
    #expect(try decoder.decode(HeistPlanName.self, from: encoder.encode(planName)) == planName)
    #expect(try decoder.decode(HeistDefinitionPath.self, from: encoder.encode(definitionPath)) == definitionPath)
    #expect(try decoder.decode(HeistInvocationPath.self, from: encoder.encode(invocationPath)) == invocationPath)
}

@Test func `typed paths build definitions and invocations without raw strings`() throws {
    let definitionPath: HeistDefinitionPath = "Cart.addItem"
    let invocationPath: HeistInvocationPath = "Cart.addItem"
    let addItem = HeistDef<String>(definitionPath, parameter: "item") { item in
        Activate(.label(item))
    }

    let plan = try HeistPlan {
        addItem
        RunHeist(invocationPath, "Milk")
    }

    #expect(plan.definitions.map(\.name) == ["Cart"])
    #expect(plan.body == [
        .invoke(HeistInvocationStep(
            path: invocationPath,
            argument: .string("Milk")
        )),
    ])
    #expect(plan.heistDefinition(at: definitionPath)?.name == "addItem")
}

@Test func `semantic validation rejects duplicate unresolved and recursive plans`() throws {
    try expectSemanticDiagnostic(
        {
            try HeistSourceParser.parse("""
            HeistPlan {
                HeistDef<Void>("checkout") { Warn("one") }
                HeistDef<Void>("checkout") { Warn("two") }
                Warn("root")
            }
            """)
        },
        path: "$.definitions[1].name",
        message: "duplicate heist definition names are not allowed in the same scope"
    )

    try expectSemanticDiagnostic(
        { try HeistPlan(body: [.invoke(HeistInvocationStep(path: "Missing"))]) },
        path: "$.body[0].invoke.path",
        message: "heist run path must resolve to a local capability"
    )

    try expectSemanticDiagnostic(
        { try HeistSourceParser.parse(recursiveSource) },
        path: "$.definitions[0].definitions[0].body[0].invoke.body[0].invoke.path",
        message: "heist runs must not be recursive"
    )
}

@Test func `semantic validation rejects nested collection loops`() throws {
    let cases = [
        (
            """
            HeistPlan {
                ForEach("Milk") { item in
                    ForEach("Small") { size in Warn("nested") }
                }
            }
            """,
            "$.body[0].for_each_string.body[0].for_each_string",
            "for_each_string inside collection loop"
        ),
        (
            """
            HeistPlan {
                ForEach(.label("Section"), limit: 1) { section in
                    ForEach(.label("Row"), limit: 1) { row in Warn("nested") }
                }
            }
            """,
            "$.body[0].for_each_element.body[0].for_each_element",
            "for_each_element inside collection loop"
        ),
    ]

    for testCase in cases {
        let diagnostic = try semanticDiagnostic {
            try HeistSourceParser.parse(testCase.0)
        }
        #expect(diagnostic.code == .planRuntimeSafety)
        #expect(diagnostic.title == "Plan semantic validation failed")
        #expect(diagnostic.phase == .planValidation)
        #expect(diagnostic.path == testCase.1)
        #expect(diagnostic.message == "collection loops must not be nested; observed \(testCase.2)")
        #expect(diagnostic.hint == "Flatten this heist so ForEach bodies contain only non-collection steps.")
    }
}

@Test func `source and JSON admit nested plans once at the root diagnostic path`() throws {
    let expectedPath = "$.body[0].conditional.cases[0].body[0].heist.body[0].invoke.path"
    let sourceDiagnostic = try semanticDiagnostic {
        try HeistSourceParser.parse("""
        HeistPlan {
            If(.exists(.label("Home"))) {
                HeistPlan { RunHeist("Missing") }
            }
        }
        """)
    }
    let json = Data("""
    {"version":3,"body":[{"type":"conditional","conditional":{"cases":[{
      "predicate":{"type":"exists","target":{"checks":[
        {"kind":"label","match":{"mode":"exact","value":"Home"}}]}},
      "body":[{"type":"heist","heist":{"version":3,"body":[
        {"type":"invoke","invoke":{"path":"Missing"}}]}}]}]}}]}
    """.utf8)
    let jsonDiagnostic = try semanticDiagnostic {
        try JSONDecoder().decode(HeistPlan.self, from: json)
    }

    #expect(sourceDiagnostic.path == expectedPath)
    #expect(jsonDiagnostic.path == expectedPath)
    #expect(sourceDiagnostic.code == .planRuntimeSafety)
    #expect(sourceDiagnostic.message == jsonDiagnostic.message)
}

private func expectSemanticDiagnostic(
    _ operation: () throws -> HeistPlan,
    path expectedPath: String,
    message expectedMessage: String
) throws {
    let diagnostic = try semanticDiagnostic(operation)

    #expect(diagnostic.code == .planRuntimeSafety)
    #expect(diagnostic.title == "Plan semantic validation failed")
    #expect(diagnostic.phase == .planValidation)
    #expect(diagnostic.path == expectedPath)
    #expect(diagnostic.message.contains(expectedMessage))
    #expect(diagnostic.hint != nil)
}

private func semanticDiagnostic(_ operation: () throws -> HeistPlan) throws -> HeistBuildDiagnostic {
    do {
        _ = try operation()
        throw LanguageContractFailure.expectedSemanticFailure
    } catch let error as HeistPlanBuildError {
        return try #require(error.diagnostics.first)
    }
}

private enum LanguageContractFailure: Error {
    case expectedSemanticFailure
}
