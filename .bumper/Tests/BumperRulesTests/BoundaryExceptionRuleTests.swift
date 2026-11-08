import BumperBowlingCore
import BumperBowlingTestSupport
import Testing

@testable import BumperRules

@Suite
struct BoundaryExceptionRuleTests {
    @Test
    func `new unchecked conformances require a reviewed boundary`() throws {
        let path = "ButtonHeist/Sources/TheInsideJob/Unsafe.swift"
        let report = try evaluateButtonHeistRules(path: path, source: "final class Unsafe: @unchecked Sendable {}")
        #expect(report.count == 1)
        #expect(report.first?.ruleIdentifier == "buttonheist.unchecked_sendable_boundary")
        #expect(report.first?.location.file?.hasSuffix(path) == true)
        #expect(report.first?.location.line == 1)
        #expect(report.first?.location.character == 21)
        #expect(report.first?.severity == .error)
        #expect(report.first?.reason == "Unchecked Sendable conformance is outside the reviewed boundary declarations. Use checked Sendable or review and register this exact declaration's safety argument.")
    }

    @Test
    func `approved unchecked declarations are exact file and owner exceptions`() throws {
        let fixtures: [(String, String)] = [
            ("TheTripwire/AccessibilityNotificationObserver.swift", "private final class PendingAccessibilityNotificationCallback: @unchecked Sendable {}"),
            ("Server/NetworkBoundary/SocketConnectionAdmission.swift", "final class ConnectionAdmission: @unchecked Swift.Sendable {}"),
            ("Server/NetworkBoundary/SocketListenerRuntime.swift", "final class NetworkSocketListener: @unchecked Sendable {}"),
            ("Server/NetworkBoundary/SocketListenerRuntime.swift", "private final class PendingSocketConnections { private struct OwnedConnection: @unchecked Sendable {} }"),
            ("Server/NetworkBoundary/SocketConnectionAdmission.swift", "final class ConnectionAdmission {}\nextension ConnectionAdmission: @unchecked Sendable {}"),
        ]
        for (relativePath, source) in fixtures {
            let report = try evaluateButtonHeistRules(path: "ButtonHeist/Sources/TheInsideJob/" + relativePath, source: source)
            #expect(report.isEmpty)
        }
    }

    @Test(arguments: [
        "final class Other: @unchecked Sendable {}",
        "enum Other { final class ConnectionAdmission: @unchecked Sendable {} }",
        "func local() { final class ConnectionAdmission: @unchecked Sendable {} }",
        "var sample: any Sendable { final class ConnectionAdmission: @unchecked Sendable {}; return ConnectionAdmission() }",
    ])
    func `approved files do not exempt new nested or local unchecked types`(source: String) throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Server/NetworkBoundary/SocketConnectionAdmission.swift", source: source
        )
        #expect(report.count == 1)
        #expect(report.first?.ruleIdentifier == "buttonheist.unchecked_sendable_boundary")
    }

    @Test
    func `an approved name in another file still requires review`() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Other.swift",
            source: "final class ConnectionAdmission: @unchecked Sendable {}"
        )
        #expect(report.count == 1)
        #expect(report.first?.ruleIdentifier == "buttonheist.unchecked_sendable_boundary")
        let checked = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Other.swift", source: "struct Checked: Sendable {}"
        )
        #expect(checked.isEmpty)
    }

    @Test
    func `demo identifiers fail with a user-facing accessibility repair`() throws {
        let path = "TestApp/Sources/Demo.swift"
        let report = try evaluateButtonHeistRules(path: path, source: "view.accessibilityIdentifier = \"demo\"")
        #expect(report.count == 1)
        #expect(report.first?.ruleIdentifier == "buttonheist.demo_accessibility_identifier")
        #expect(report.first?.location.file?.hasSuffix(path) == true)
        #expect(report.first?.location.line == 1)
        #expect(report.first?.location.character == 6)
        #expect(report.first?.severity == .error)
        #expect(report.first?.reason == "Demo screens must use user-facing accessibility properties. Replace accessibilityIdentifier with labels, values, traits, hints, or actions; research exceptions require an exact harness path.")
    }

    @Test(arguments: [
        "Text(\"Hello\").accessibilityIdentifier(\"demo\")",
        "view?.accessibilityIdentifier = \"demo\"",
        "let path = \\UIView.accessibilityIdentifier",
        "let current = view.accessibilityIdentifier",
        "accessibilityIdentifier = \"demo\"",
        "view.`accessibilityIdentifier` = \"demo\"",
        "class Demo: UIView { override var accessibilityIdentifier: String? { get { \"demo\" } set {} } }",
    ])
    func `demo identifier references are checked across their written forms`(source: String) throws {
        let report = try RuleTestHarness(DemoAccessibilityIdentifierRule.self).evaluate([.swift("TestApp/Sources/Demo.swift", source: source)])
        #expect(report.count == 1)
    }

    @Test
    func `only named research files permit identifier references`() throws {
        for name in ["ScrollSPIHarnessView", "TraitValidationView", "TraitProbeView"] {
            let report = try evaluateButtonHeistRules(
                path: "TestApp/Sources/\(name).swift", source: "view.accessibilityIdentifier = \"fixture\""
            )
            #expect(report.isEmpty)
        }
        let report = try evaluateButtonHeistRules(
            path: "TestApp/Sources/NewResearchHarness.swift", source: "view.accessibilityIdentifier = \"fixture\""
        )
        #expect(report.count == 1)
        let misplaced = try RuleTestHarness(DemoAccessibilityIdentifierRule.self).evaluate([
            .swift("TestApp/Sources/Other/TraitProbeView.swift", source: "view.accessibilityIdentifier = \"fixture\"")
        ])
        #expect(misplaced.count == 1)
    }

    @Test
    func `ordinary accessibility and code outside demo sources stay outside the identifier policy`() throws {
        let report = try evaluateButtonHeistRules(
            path: "TestApp/Sources/Demo.swift",
            source: """
                // accessibilityIdentifier is reserved for research fixtures.
                let description = "accessibilityIdentifier"
                Text("Hello").accessibilityLabel("Greeting")
                """
        )
        #expect(report.isEmpty)
        let outside = try RuleTestHarness(DemoAccessibilityIdentifierRule.self).evaluate([
            .swift("ButtonHeist/Sources/TheInsideJob/Probe.swift", source: "view.accessibilityIdentifier")
        ])
        #expect(outside.isEmpty)
    }
}
