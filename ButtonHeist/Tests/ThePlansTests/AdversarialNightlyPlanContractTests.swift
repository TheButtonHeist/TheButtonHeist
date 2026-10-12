import Testing

@_spi(AdversarialLab) @testable import ThePlans

@Test func `adversarial catalog projects one admitted contract per scenario`() throws {
    let scenarios = AdversarialScenarioCatalog.Scenario.allCases
    #expect(scenarios.count == 19)
    #expect(Set(scenarios.map(\.rawValue)).count == scenarios.count)
    #expect(Set(scenarios.map(\.route)) == Set(AdversarialScenarioCatalog.Route.allCases))

    for scenario in scenarios {
        let plan = try scenario.plan()
        let manifest = try scenario.manifest()
        #expect(manifest.name == scenario.rawValue)
        #expect(manifest.route == scenario.route.rawValue)
        #expect(manifest.classification == scenario.classification)
        #expect(manifest.expectedOutcome == scenario.expectedOutcome)
        #expect(manifest.expectedEvidence == scenario.expectedEvidence)
        #expect(try HeistSourceParser.parse(manifest.plan) == plan)

        let diagnostics = scenario.expectedEvidence.filter { $0.kind == .diagnostic }
        switch scenario.expectedOutcome {
        case .commandSucceeds:
            #expect(diagnostics.isEmpty)
        case .commandFailsWithDiagnostic:
            #expect(diagnostics.count == 1)
        }
    }
}

@Test func `nightly projection contains only genuinely repeated contracts`() {
    let scenarios = AdversarialScenarioCatalog.Scenario.allCases
    let statistical = scenarios.filter { $0.classification == .statistical }
    let deterministic = scenarios.filter { $0.classification == .deterministic }

    #expect(statistical.count == 9)
    #expect(statistical.allSatisfy { $0.expectedOutcome == .commandSucceeds })
    #expect(deterministic.count == 10)
    #expect(deterministic.contains(.duplicateLabelIdentityPass))
    #expect(scenarios.filter { $0.route == .duplicateLabels } == [.duplicateLabelIdentityPass])
}
