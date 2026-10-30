import BumperBowlingCore
import BumperBowlingTestSupport
import Testing

@Suite("Plan language boundaries")
struct PlanLanguageBoundaryRuleTests {
    @Test
    func heistContentDoesNotExposePublicProperties() throws {
        let valid = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/HeistContent.swift",
            component: .plans,
            source: "public struct HeistContent { let steps: [Int] }"
        )
        let invalid = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/PublicHeistContent.swift",
            component: .plans,
            source: "public struct HeistContent { public let steps: [Int] }"
        )

        #expect(valid.violations.isEmpty)
        #expect(invalid.contains(ViolationMatcher(
            id: "buttonheist.heist_content_opacity",
            path: "ButtonHeist/Sources/ThePlans/PublicHeistContent.swift"
        )))

        let computed = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/ComputedHeistContent.swift",
            component: .plans,
            source: "public extension HeistContent { var stepCount: Int { 0 } }"
        )
        #expect(computed.contains(ViolationMatcher(
            id: "buttonheist.heist_content_opacity",
            path: "ButtonHeist/Sources/ThePlans/ComputedHeistContent.swift"
        )))
    }

    @Test
    func onlyWaitAndConditionalFragmentsExposeElse() throws {
        let valid = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/HeistControl.swift",
            component: .plans,
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
            component: .plans,
            source: """
            public struct RepeatUntil {
                public func `else`() {}
            }
            """
        )

        #expect(valid.violations.isEmpty)
        #expect(invalid.contains(ViolationMatcher(
            id: "buttonheist.plan_else_ownership",
            path: "ButtonHeist/Sources/ThePlans/RepeatUntil.swift"
        )))
    }

    @Test
    func exportedTupleContractsCoverEveryAuditedDeclarationForm() throws {
        let valid = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheScore/TupleScratch.swift",
            component: .score,
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
        #expect(valid.violations.isEmpty)

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
            let path = try RelativeFilePath(
                "ButtonHeist/Sources/TheScore/ExportedTuples-\(invalidCase.name).swift"
            )
            let invalid = try evaluateButtonHeistRules(
                path: path,
                component: .score,
                source: invalidCase.source
            )

            #expect(invalid.violations.count == 1, "Expected one violation for \(invalidCase.name)")
            #expect(invalid.contains(ViolationMatcher(
                id: "buttonheist.exported_tuple_contract",
                path: path
            )))
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
            "public extension HeistContent { func exposedSteps() -> [Int] { [] } }"
        ] {
            let report = try evaluateButtonHeistRules(
                path: "ButtonHeist/Sources/ThePlans/Fragment.swift", component: .plans, source: source
            )
            #expect(report.violations.contains { $0.rule.id == "buttonheist.heist_content_opacity" })
        }
    }

    @Test
    func privateElseHelpersAreNotPublicGrammar() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/Helpers.swift", component: .plans,
            source: """
            public struct RepeatUntil { private func `else`() {} }
            private struct Helper { func `else`() {} }
            """
        )
        #expect(report.violations.isEmpty)
    }

    @Test
    func exportedTupleContractsIncludeConstructorsAliasesAndEnumPayloads() throws {
        for source in [
            "public typealias Pair = (Int, Int)",
            "public struct Example { public init(_ pair: (Int, Int)) {} }",
            "public enum Example { case pair((Int, Int)) }",
            "public struct Example { private(set) public var pair: (Int, Int) = (0, 0) }",
            "public protocol Example { associatedtype Pair = (Int, Int) }"
        ] {
            let report = try evaluateButtonHeistRules(
                path: "ButtonHeist/Sources/TheScore/Contract.swift", component: .score, source: source
            )
            #expect(report.violations.count == 1)
            #expect(report.violations.first?.rule.id == "buttonheist.exported_tuple_contract")
        }
        let valid = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheScore/PrivateContract.swift", component: .score,
            source: """
            private enum Example { case pair((Int, Int)) }
            private typealias Pair = (Int, Int)
            public enum NamedPayload { case pair(left: Int, right: Int) }
            """
        )
        #expect(valid.violations.isEmpty)
    }

    @Test
    func nestedLookalikesDoNotOwnPublicElseGrammar() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/ThePlans/Other.swift", component: .plans,
            source: "public struct Other { public struct WaitFor { public func `else`() {} } }"
        )
        #expect(report.violations.first?.rule.id == "buttonheist.plan_else_ownership")
    }
}
