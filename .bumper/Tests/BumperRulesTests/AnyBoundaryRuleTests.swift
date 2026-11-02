import BumperBowlingCore
import BumperBowlingTestSupport
import Testing

@testable import BumperRules

@Suite("Any bridge boundary")
struct AnyBoundaryRuleTests {
    @Test
    func arbitraryProductionAPIsCannotExposeAny() throws {
        let path: String = "ButtonHeist/Sources/TheInsideJob/UntypedValue.swift"
        let report = try evaluateButtonHeistRules(
            path: path,
            source: "func render(_ value: Any) {}"
        )

        #expect(report.count == 1)
        #expect(report.contains { $0.ruleIdentifier == "buttonheist.any_boundary" && $0.location.file?.hasSuffix(path) == true })
    }

    @Test
    func exactSystemBoundaryDeclarationsPermitAny() throws {
        let fixtures = [
            (
                "ButtonHeist/Sources/TheButtonHeist/Storage/PrivateStorage.swift",
                "private typealias FoundationFileAttributeDictionary = [String: Any]"
            ),
            (
                "ButtonHeist/Sources/TheButtonHeist/TheFence/TheFence+CommandArguments.swift",
                "enum HeistValuePayloadDecoder { static func expectedDescription(for type: Any.Type) {} }"
            ),
            (
                "ButtonHeist/Sources/TheInsideJob/Lifecycle/InsideJobRuntimeConfiguration+Resolution.swift",
                "func decodeFoundationInfoPlistValue(_ object: Any) {}"
            ),
        ]

        for (path, source) in fixtures {
            let report = try evaluateButtonHeistRules(
                path: path,
                source: source
            )
            #expect(report.isEmpty)
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
            let path = "ButtonHeist/Sources/TheInsideJob/Impostor\(index).swift"
            let report = try evaluateButtonHeistRules(
                path: path,
                source: source
            )

            #expect(report.contains { $0.ruleIdentifier == "buttonheist.any_boundary" && $0.location.file?.hasSuffix(path) == true })
        }
    }

    @Test
    func typeDescriptionExceptionDoesNotPermitErasedValues() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheButtonHeist/TheFence/TheFence+CommandArguments.swift",
            source: "enum HeistValuePayloadDecoder { static func expectedDescription(for value: Any) {} }"
        )
        #expect(report.first?.ruleIdentifier == "buttonheist.any_boundary")
    }
}
