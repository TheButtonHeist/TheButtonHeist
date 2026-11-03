import BumperBowlingCore
import BumperBowlingTestSupport
import Testing

@testable import BumperRules

@Suite("Stored callback isolation")
struct CallbackIsolationRuleTests {
    @Test
    func localTypesStillHaveStoredContractsButLocalScratchDoesNot() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Local.swift",
            source: """
            func local() {
                let completion: (() -> Void)? = nil
                struct Stored { var completion: (() -> Void)? }
            }
            """
        )
        #expect(report.count == 1)
        #expect(report.first?.ruleIdentifier == "buttonheist.callback_isolation")
        #expect(report.first?.location.line == 3)
    }

    @Test
    func storedCallbacksRequireExplicitIsolation() throws {
        let path: String = "ButtonHeist/Sources/TheInsideJob/Client.swift"
        let report = try evaluateButtonHeistRules(
            path: path,
            source: "struct Client { var onEvent: ((String) -> Void)? }"
        )

        #expect(report.count == 1)
        #expect(report.contains { $0.ruleIdentifier == "buttonheist.callback_isolation" && $0.location.file?.hasSuffix(path) == true })
    }

    @Test
    func actorAndSendableCallbacksAreExplicitlyIsolated() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Client.swift",
            source: """
                struct Client {
                    var onEvent: (@Sendable (String) -> Void)?
                    var onClose: (@MainActor () -> Void)?
                }
                """
        )

        #expect(report.isEmpty)
    }

    @Test
    func fileLocalCallbackAliasesPreserveTheirIsolationContract() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            source: """
                typealias CheckedHandler = @Sendable (String) -> Void
                typealias LooseHandler = (String) -> Void
                struct Callbacks {
                    var onChecked: CheckedHandler?
                    var onLoose: LooseHandler?
                }
                """
        )

        #expect(report.count == 1)
        #expect(report.first?.ruleIdentifier == "buttonheist.callback_isolation")
    }

    @Test
    func sameNamedNestedAliasesResolveInTheirLexicalType() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            source: """
                struct CheckedCallbacks {
                    typealias Handler = @Sendable () -> Void
                    var onEvent: Handler?
                }
                struct LooseCallbacks {
                    typealias Handler = () -> Void
                    var onEvent: Handler?
                }
                """
        )

        #expect(report.count == 1)
    }

    @Test
    func nestedSendableParametersDoNotIsolateTheStoredCallback() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            source: "struct Callbacks { var onEvent: (@Sendable () -> Void) -> Void }"
        )

        #expect(report.count == 1)
    }

    @Test
    func genericOptionalCallbacksRemainVisibleToTheRule() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            source: """
                typealias Handler = () -> Void
                struct Callbacks {
                    var onDirect: Optional<() -> Void>
                    var onAlias: Optional<Handler>
                }
                """
        )

        #expect(report.count == 2)
    }

    @Test
    func callbackNamesDoNotDetermineIsolation() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            source: """
                struct Callbacks {
                    var completion: (() -> Void)?
                    let receive: (() -> Void)?
                    let isolated: @Sendable () -> Void
                    let synchronousDependency: () -> Void
                }
                """
        )
        #expect(report.count == 2)
    }

    @Test
    func aliasChainsUseNearestLexicalScopeAndQualifiedOwners() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            source: """
                typealias Handler = @Sendable () -> Void
                struct Outer {
                    typealias Handler = () -> Void
                    typealias Chained = Handler
                    struct Inner { var completion: Chained? }
                }
                struct Other { var completion: Outer.Chained? }
                struct Checked { var receive: Handler? }
                """
        )
        #expect(report.count == 2)
    }

    @Test
    func globalActorsNeedNoNamingSuffix() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            source: """
                @globalActor actor UIExecutor { static let shared = UIExecutor() }
                typealias Handler = @UIExecutor () -> Void
                struct Callbacks {
                    var receive: Handler?
                    var completion: (@UIExecutor () -> Void)?
                }
                """
        )
        #expect(report.isEmpty)
    }

    @Test
    func aliasCyclesTerminateAndUnknownImportedTypesStayUnresolved() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            source: """
                typealias First = Second
                typealias Second = First
                struct Callbacks { var onCycle: First?; var receive: ImportedHandler? }
                """
        )
        #expect(report.isEmpty)
    }

    @Test
    func localAliasesAndShadowedNamesDoNotChangeStoredContracts() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            source: """
                typealias Handler = @Sendable () -> Void
                struct LocalAlias {
                    var completion: Handler?
                    func local() { typealias Handler = () -> Void }
                }
                struct NominalShadow {
                    struct Handler {}
                    var completion: Handler?
                }
                struct GenericShadow<Handler> { var completion: Handler? }
                """
        )
        #expect(report.isEmpty)
    }

    @Test
    func `Extension callbacks prefer the target alias to the file alias`() throws {
        let path = "ButtonHeist/Sources/TheInsideJob/Callbacks.swift"
        let report = try evaluateButtonHeistRules(
            path: path,
            source: """
                typealias Handler = @Sendable () -> Void
                struct Callbacks { typealias Handler = () -> Void }
                extension Callbacks { var completion: Handler? { nil } }
                """
        )
        #expect(report.count == 1)
        #expect(report.first?.ruleIdentifier == "buttonheist.callback_isolation")
        #expect(report.first?.location.file?.hasSuffix(path) == true)
        #expect(report.first?.location.line == 3)
        #expect(report.first?.location.character == 27)
        #expect(report.first?.severity == .error)
        #expect(report.first?.reason.contains("Declare a known global actor or @Sendable.") == true)

        let allowed = try evaluateButtonHeistRules(
            path: path,
            source: """
                typealias Handler = () -> Void
                struct Callbacks { typealias Handler = @Sendable () -> Void }
                extension Callbacks { var completion: Handler? { nil } }
                """
        )
        #expect(allowed.isEmpty)
    }

    @Test
    func `exported callback aliases declare isolation before any stored use`() throws {
        let path = "ButtonHeist/Sources/TheInsideJob/Callbacks.swift"
        let report = try evaluateButtonHeistRules(path: path, source: "public typealias Handler = () -> Void")
        #expect(report.count == 1)
        #expect(report.first?.ruleIdentifier == "buttonheist.callback_isolation")
        #expect(report.first?.location.file?.hasSuffix(path) == true)
        #expect(report.first?.location.line == 1)
        #expect(report.first?.location.character == 18)
        #expect(report.first?.severity == .error)
        #expect(report.first?.reason == "callback alias without explicit isolation: Handler. Declare a known global actor or @Sendable.")
    }

    @Test(arguments: [
        "public typealias EventCallback = () -> Void",
        "package typealias Completion = () -> Void",
        "public typealias MaybePredicate = ((Int) -> Bool)?",
        "public struct Owner {}\npublic extension Owner { typealias EventHandler = () -> Void }",
        "import Foundation\npublic extension URL { typealias EventHandler = () -> Void }",
        "public typealias `Handler` = () -> Void",
    ])
    func `exported callback naming and optional contracts require isolation`(source: String) throws {
        let report = try evaluateButtonHeistRules(path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift", source: source)
        #expect(report.count == 1)
        #expect(report.first?.ruleIdentifier == "buttonheist.callback_isolation")
    }

    @Test
    func `alias checks preserve synchronous functions private scratch and isolated callbacks`() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            source: """
                @globalActor public actor UIExecutor { public static let shared = UIExecutor() }
                public typealias EventCallback = @Sendable () -> Void
                public typealias Completion = @MainActor () -> Void
                public typealias EventHandler = @UIExecutor () -> Void
                public typealias Predicate = (Int) -> Bool
                public typealias CallbackResult = Int
                private typealias PrivateHandler = () -> Void
                typealias InternalCompletion = () -> Void
                private struct LocalOwner { public typealias Handler = () -> Void }
                public typealias ImportedHandler = UnknownFunction
                public typealias CCallback = @convention(c) () -> Void
                """
        )
        #expect(report.isEmpty)
    }

    @Test
    func `getter locals stay scratch while fields in getter local types remain contracts`() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Getter.swift",
            source: """
                struct Example {
                    var count: Int {
                        let completion: (() -> Void)? = nil
                        struct Local { var completion: (() -> Void)? }
                        _ = completion
                        return 0
                    }
                }
                """
        )
        #expect(report.count == 1)
        #expect(report.first?.ruleIdentifier == "buttonheist.callback_isolation")
        #expect(report.first?.location.line == 4)
    }
}
