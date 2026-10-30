import BumperBowlingCore
import Testing

@Suite("Transport import ownership")
struct TransportImportRuleTests {
    @Test
    func transportImportsStayAtTransportBoundaries() throws {
        let allowed = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Server/NetworkBoundary/NewTransport.swift",
            component: .embeddedRuntime, source: "import Network"
        )
        let denied = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/TheBrains/HeistExecution.swift",
            component: .embeddedRuntime, source: "import Network"
        )
        #expect(allowed.violations.isEmpty)
        #expect(denied.violations.first?.rule.id == "buttonheist.transport_import_ownership")
    }

    @Test
    func scoreHasOnlyOneTLSBoundary() throws {
        let allowed = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheScore/Core/TLSPreSharedKeyMaterial.swift",
            component: .score, source: "import Network\nimport Security"
        )
        let denied = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheScore/Reports/Report.swift",
            component: .score, source: "import Network\nimport Security"
        )
        #expect(allowed.violations.isEmpty)
        #expect(Set(denied.violations.map(\.rule.id)) == [
            "buttonheist.transport_import_ownership", "buttonheist.security_import_ownership",
        ])
    }
}
