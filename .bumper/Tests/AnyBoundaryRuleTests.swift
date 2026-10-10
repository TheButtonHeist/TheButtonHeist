import BumperBowlingCore
import BumperBowlingTestSupport
import Testing

@Suite("Any bridge boundary")
struct AnyBoundaryRuleTests {
    @Test
    func arbitraryProductionAPIsCannotExposeAny() throws {
        let path: RelativeFilePath = "ButtonHeist/Sources/TheInsideJob/UntypedValue.swift"
        let report = try evaluateButtonHeistRules(
            path: path,
            component: .embeddedRuntime,
            source: "func render(_ value: Any) {}"
        )

        #expect(report.violations.count == 1)
        #expect(report.contains(ViolationMatcher(id: "buttonheist.any_boundary", path: path)))
    }

    @Test
    func exactSystemBoundaryDeclarationsPermitAny() throws {
        let fixtures = [
            (
                RelativeFilePath("ButtonHeist/Sources/TheButtonHeist/Storage/PrivateStorage.swift"),
                ButtonHeistComponent.client,
                "private typealias FoundationFileAttributeDictionary = [String: Any]"
            ),
            (
                RelativeFilePath(
                    "ButtonHeist/Sources/TheButtonHeist/TheFence/TheFence+CommandArguments.swift"
                ),
                ButtonHeistComponent.client,
                "enum HeistValuePayloadDecoder { static func expectedDescription(for type: Any.Type) {} }"
            ),
            (
                RelativeFilePath("ButtonHeist/Sources/TheInsideJob/Lifecycle/StartupConfiguration.swift"),
                ButtonHeistComponent.embeddedRuntime,
                "func decodeFoundationInfoPlistValue(_ object: Any) {}"
            ),
        ]

        for (path, component, source) in fixtures {
            let report = try evaluateButtonHeistRules(
                path: path,
                component: component,
                source: source
            )
            #expect(report.violations.isEmpty)
        }
    }

    @Test
    func lookalikeBoundaryNamesDoNotExemptAny() throws {
        let fixtures = [
            "private typealias FoundationFileAttributeDictionary = [String: Any]",
            "enum HeistValuePayloadDecoder { static func expectedDescription(for type: Any.Type) {} }",
            "func decodeFoundationInfoPlistValue(_ object: Any) {}",
        ]

        for (index, source) in fixtures.enumerated() {
            let path = try RelativeFilePath("ButtonHeist/Sources/TheInsideJob/Impostor\(index).swift")
            let report = try evaluateButtonHeistRules(
                path: path,
                component: .embeddedRuntime,
                source: source
            )

            #expect(report.contains(ViolationMatcher(id: "buttonheist.any_boundary", path: path)))
        }
    }
}
