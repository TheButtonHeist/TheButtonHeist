import BumperBowlingCore
import BumperBowlingTestSupport
import Testing

@testable import BumperRules

@Suite("Plan language boundaries")
struct PlanLanguageBoundaryRuleTests {
    @Test
    func heistContentDoesNotExposePublicProperties() throws {
        let valid = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/HeistContent.swift",
            source: "public struct HeistContent { let steps: [Int] }"
        )
        let invalid = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/PublicHeistContent.swift",
            source: "public struct HeistContent { public let steps: [Int] }"
        )

        #expect(valid.isEmpty)
        #expect(
            invalid.contains {
                $0.ruleIdentifier == "buttonheist.heist_content_opacity"
                    && $0.location.file?.hasSuffix("ButtonHeist/Sources/ThePlans/PublicHeistContent.swift") == true
            })

        let computed = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/ComputedHeistContent.swift",
            source: "public extension HeistContent { var stepCount: Int { 0 } }"
        )
        #expect(
            computed.contains {
                $0.ruleIdentifier == "buttonheist.heist_content_opacity"
                    && $0.location.file?.hasSuffix("ButtonHeist/Sources/ThePlans/ComputedHeistContent.swift") == true
            })
    }

    @Test
    func onlyWaitAndConditionalFragmentsExposeElse() throws {
        let valid = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/HeistControl.swift",
            source: """
                public struct WaitFor {
                    public func `else`() {}
                }
                public struct IfContent {
                    public func `else`() {}
                }
                """
        )
        let invalid = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/RepeatUntil.swift",
            source: """
                public struct RepeatUntil {
                    public func `else`() {}
                }
                """
        )

        #expect(valid.isEmpty)
        #expect(
            invalid.contains {
                $0.ruleIdentifier == "buttonheist.plan_else_ownership" && $0.location.file?.hasSuffix("ButtonHeist/Sources/ThePlans/RepeatUntil.swift") == true
            })
    }

    @Test
    func exportedTupleContractsCoverEveryAuditedDeclarationForm() throws {
        let valid = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheScore/TupleScratch.swift",
            source: """
                public struct ExportedContainer {
                    var internalByDefault: (left: Int, right: Int) { (1, 2) }
                }

                public struct NamedResult {}
                public func admit() -> NamedResult { NamedResult() }

                private func privateScratch(
                    _ input: (left: Int, right: Int)
                ) -> (left: Int, right: Int) {
                    input
                }

                func internalScratch() -> (left: Int, right: Int) { (1, 2) }

                public extension ExportedContainer {
                    private var privateScratch: (left: Int, right: Int) { (1, 2) }
                    internal subscript(index: (left: Int, right: Int)) -> (left: Int, right: Int) {
                        index
                    }
                }

                private protocol PrivateScratch {
                    var pair: (left: Int, right: Int) { get }
                }

                func useLocalScratch() {
                    let local: (left: Int, right: Int) = (1, 2)
                    func nested() -> (left: Int, right: Int) { local }
                    _ = nested()
                }

                public func parenthesized(_ value: (Int)) -> (String) { String(value) }
                """
        )
        #expect(valid.isEmpty)

        let invalidCases: [(name: String, source: String)] = [
            (
                "function-parameter",
                "public func explicitFunction(_ input: (left: Int, right: Int)) -> Int { input.left }"
            ),
            (
                "nested-return",
                "package func nestedReturn() -> Result<(value: Int, ordinal: Int), Never> { .success((1, 0)) }"
            ),
            (
                "property",
                "public let explicitProperty: (value: Int, ordinal: Int) = (1, 0)"
            ),
            (
                "subscript-parameter",
                """
                public struct ExplicitSubscript {
                    public subscript(key: (section: Int, row: Int)) -> String { "" }
                }
                """
            ),
            (
                "protocol-function",
                "public protocol PublicContract { func requirement() -> (value: Int, ordinal: Int) }"
            ),
            (
                "protocol-property",
                "public protocol PublicContract { var property: (value: Int, ordinal: Int) { get } }"
            ),
            (
                "protocol-subscript",
                "public protocol PublicContract { subscript(index: Int) -> (value: Int, ordinal: Int) { get } }"
            ),
            (
                "package-protocol-parameter",
                "package protocol PackageContract { func requirement(_ input: (value: Int, ordinal: Int)) }"
            ),
            (
                "extension-function",
                """
                public struct ExtensionTarget {}
                public extension ExtensionTarget {
                    func inheritedFunction() -> (value: Int, ordinal: Int) { (1, 0) }
                }
                """
            ),
            (
                "extension-property",
                """
                public struct ExtensionTarget {}
                public extension ExtensionTarget {
                    var inheritedProperty: (value: Int, ordinal: Int) { (1, 0) }
                }
                """
            ),
            (
                "extension-subscript",
                """
                public struct ExtensionTarget {}
                public extension ExtensionTarget {
                    subscript(index: Int) -> (value: Int, ordinal: Int) { (index, 0) }
                }
                """
            ),
            (
                "package-extension-function",
                """
                public struct ExtensionTarget {}
                package extension ExtensionTarget {
                    func inheritedPackageFunction() -> (value: Int, ordinal: Int) { (1, 0) }
                }
                """
            ),
        ]

        for invalidCase in invalidCases {
            let path = "ButtonHeist/Sources/TheScore/ExportedTuples-\(invalidCase.name).swift"
            let invalid = try evaluateButtonHeistRules(
                path: path,
                source: invalidCase.source
            )

            #expect(invalid.count == 1, "Expected one violation for \(invalidCase.name)")
            #expect(invalid.contains { $0.ruleIdentifier == "buttonheist.exported_tuple_contract" && $0.location.file?.hasSuffix(path) == true })
        }
    }

    @Test
    func opaqueContentRejectsEveryPublicMemberForm() throws {
        for source in [
            "public struct HeistContent { public func exposedSteps() -> [Int] { [] } }",
            "public struct HeistContent { public init() {} }",
            "public struct HeistContent { public subscript(index: Int) -> Int { index } }",
            "public struct HeistContent { public typealias Steps = [Int] }",
            "public struct HeistContent { public struct Exposed {} }",
            "public extension HeistContent { func exposedSteps() -> [Int] { [] } }",
        ] {
            let report = try evaluateButtonHeistRules(
                path: "ButtonHeist/Sources/ThePlans/Fragment.swift", source: source
            )
            #expect(report.contains { $0.ruleIdentifier == "buttonheist.heist_content_opacity" })
        }
    }

    @Test
    func privateElseHelpersAreNotPublicGrammar() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/Helpers.swift",
            source: """
                public struct RepeatUntil { private func `else`() {} }
                private struct Helper { func `else`() {} }
                """
        )
        #expect(report.isEmpty)
    }

    @Test
    func exportedTupleContractsIncludeConstructorsAliasesAndEnumPayloads() throws {
        for source in [
            "public typealias Pair = (Int, Int)",
            "public struct Example { public init(_ pair: (Int, Int)) {} }",
            "public enum Example { case pair((Int, Int)) }",
            "public struct Example { private(set) public var pair: (Int, Int) = (0, 0) }",
            "public protocol Example { associatedtype Pair = (Int, Int) }",
        ] {
            let report = try evaluateButtonHeistRules(
                path: "ButtonHeist/Sources/TheScore/Contract.swift", source: source
            )
            #expect(report.count == 1)
            #expect(report.first?.ruleIdentifier == "buttonheist.exported_tuple_contract")
        }
        let valid = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheScore/PrivateContract.swift",
            source: """
                private enum Example { case pair((Int, Int)) }
                private typealias Pair = (Int, Int)
                public enum NamedPayload { case pair(left: Int, right: Int) }
                """
        )
        #expect(valid.isEmpty)
    }

    @Test
    func nestedLookalikesDoNotOwnPublicElseGrammar() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/Other.swift",
            source: "public struct Other { public struct WaitFor { public func `else`() {} } }"
        )
        #expect(report.first?.ruleIdentifier == "buttonheist.plan_else_ownership")
    }

    @Test
    func `Unresolved exported tuple access requires a repair`() throws {
        let path = "ButtonHeist/Sources/TheScore/External.swift"
        let report = try evaluateButtonHeistRules(
            path: path,
            source: "extension Imported { public func pair() -> (Int, Int) { (1, 2) } }"
        )
        let allowed = try evaluateButtonHeistRules(
            path: path,
            source: """
                extension Imported {
                    func internalPair() -> (Int, Int) { (1, 2) }
                }
                public extension Imported {
                    private var pairs: [(Int, Int)] { [] }
                    internal func helper() -> (Int, Int) { (1, 2) }
                }
                """
        )
        #expect(allowed.isEmpty)
        #expect(report.count == 1)
        #expect(report.first?.ruleIdentifier == "buttonheist.exported_tuple_contract")
        #expect(report.first?.location.file?.hasSuffix(path) == true)
        #expect(report.first?.location.line == 1)
        #expect(report.first?.location.character == 22)
        #expect(report.first?.severity == .error)
        #expect(report.first?.reason == "Tuple contract declares exported access. Effective visibility is unresolved. Use a named Swift type or narrow the declared access.")
    }

    @Test
    func `Cross-file extensions preserve public grammar intent and private helpers`() throws {
        let allowed = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/Extensions.swift",
            source: """
                public extension HeistContent {
                    private func helper() {}
                    internal var count: Int { 0 }
                }
                extension RepeatUntil { private func `else`() {} }
                """
        )
        let denied = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/Extensions.swift",
            source: "public extension RepeatUntil { func `else`() {} }"
        )
        #expect(allowed.isEmpty)
        #expect(denied.count == 1)
        #expect(denied.first?.ruleIdentifier == "buttonheist.plan_else_ownership")
    }

    @Test
    func `plan grammar rules do not inspect other component declarations`() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Other.swift",
            source: """
                public struct HeistContent { public var count: Int { 0 } }
                public struct Other { public func `else`() {} }
                """
        )
        #expect(report.isEmpty)
    }
}
