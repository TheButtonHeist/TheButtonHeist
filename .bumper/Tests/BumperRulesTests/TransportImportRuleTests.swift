import BumperBowlingCore
import Testing

@testable import BumperRules

@Suite("Transport import ownership")
struct TransportImportRuleTests {
    @Test
    func transportImportsStayAtTransportBoundaries() throws {
        let allowed = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Server/NetworkBoundary/NewTransport.swift", source: "import Network"
        )
        let denied = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/TheBrains/HeistExecution.swift", source: "import Network"
        )
        #expect(allowed.isEmpty)
        #expect(denied.first?.ruleIdentifier == "buttonheist.transport_import_ownership")
    }

    @Test
    func scoreHasOnlyOneTLSBoundary() throws {
        let allowed = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheScore/Core/TLSPreSharedKeyMaterial.swift", source: "import Network\nimport Security"
        )
        let denied = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheScore/Reports/Report.swift", source: "import Network\nimport Security"
        )
        #expect(allowed.isEmpty)
        #expect(
            Set(denied.map(\.ruleIdentifier)) == [
                "buttonheist.transport_import_ownership", "buttonheist.security_import_ownership",
            ])
    }

    @Test
    func `Selective and escaped imports retain their boundary and repair`() throws {
        let path = "ButtonHeist/Sources/TheScore/Report.swift"
        let source = "import struct `Network`.NWEndpoint"
        let allowed = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheScore/Core/TLSPreSharedKeyMaterial.swift", source: source
        )
        let denied = try evaluateButtonHeistRules(path: path, source: source)
        #expect(allowed.isEmpty)
        #expect(denied.count == 1)
        #expect(denied.first?.ruleIdentifier == "buttonheist.transport_import_ownership")
        #expect(denied.first?.location.file?.hasSuffix(path) == true)
        #expect(denied.first?.location.line == 1)
        #expect(denied.first?.location.character == 1)
        #expect(denied.first?.severity == .error)
        #expect(denied.first?.reason.contains("Allowed locations:") == true)
        #expect(denied.first?.reason.contains("TLSPreSharedKeyMaterial.swift") == true)
        #expect(denied.first?.reason.contains("Move the code that needs this import to an allowed location.") == true)
    }

}
