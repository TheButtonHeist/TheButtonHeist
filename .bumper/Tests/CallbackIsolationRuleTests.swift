import BumperBowlingCore
import BumperBowlingTestSupport
import Testing

@Suite("Stored callback isolation")
struct CallbackIsolationRuleTests {
    @Test
    func storedCallbacksRequireExplicitIsolation() throws {
        let path: RelativeFilePath = "ButtonHeist/Sources/TheInsideJob/Client.swift"
        let report = try evaluateButtonHeistRules(
            path: path,
            component: .embeddedRuntime,
            source: "struct Client { var onEvent: ((String) -> Void)? }"
        )

        #expect(report.violations.count == 1)
        #expect(report.contains(ViolationMatcher(id: "buttonheist.callback_isolation", path: path)))
    }

    @Test
    func actorAndSendableCallbacksAreExplicitlyIsolated() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Client.swift",
            component: .embeddedRuntime,
            source: """
            struct Client {
                var onEvent: (@Sendable (String) -> Void)?
                var onClose: (@MainActor () -> Void)?
            }
            """
        )

        #expect(report.violations.isEmpty)
    }

    @Test
    func fileLocalCallbackAliasesPreserveTheirIsolationContract() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            component: .embeddedRuntime,
            source: """
            typealias CheckedHandler = @Sendable (String) -> Void
            typealias LooseHandler = (String) -> Void
            struct Callbacks {
                var onChecked: CheckedHandler?
                var onLoose: LooseHandler?
            }
            """
        )

        #expect(report.violations.count == 1)
        #expect(report.violations.first?.rule.id == "buttonheist.callback_isolation")
    }

    @Test
    func sameNamedNestedAliasesResolveInTheirLexicalType() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            component: .embeddedRuntime,
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

        #expect(report.violations.count == 1)
    }

    @Test
    func nestedSendableParametersDoNotIsolateTheStoredCallback() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            component: .embeddedRuntime,
            source: "struct Callbacks { var onEvent: (@Sendable () -> Void) -> Void }"
        )

        #expect(report.violations.count == 1)
    }

    @Test
    func genericOptionalCallbacksRemainVisibleToTheRule() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift",
            component: .embeddedRuntime,
            source: """
            typealias Handler = () -> Void
            struct Callbacks {
                var onDirect: Optional<() -> Void>
                var onAlias: Optional<Handler>
            }
            """
        )

        #expect(report.violations.count == 2)
    }

    @Test
    func callbackNamesDoNotDetermineIsolation() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift", component: .embeddedRuntime,
            source: """
            struct Callbacks {
                var completion: (() -> Void)?
                let receive: (() -> Void)?
                let isolated: @Sendable () -> Void
                let synchronousDependency: () -> Void
            }
            """
        )
        #expect(report.violations.count == 2)
    }

    @Test
    func aliasChainsUseNearestLexicalScopeAndQualifiedOwners() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift", component: .embeddedRuntime,
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
        #expect(report.violations.count == 2)
    }

    @Test
    func globalActorsNeedNoNamingSuffix() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift", component: .embeddedRuntime,
            source: """
            @globalActor actor UIExecutor { static let shared = UIExecutor() }
            typealias Handler = @UIExecutor () -> Void
            struct Callbacks {
                var receive: Handler?
                var completion: (@UIExecutor () -> Void)?
            }
            """
        )
        #expect(report.violations.isEmpty)
    }

    @Test
    func aliasCyclesTerminateAndUnknownImportedTypesStayUnresolved() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift", component: .embeddedRuntime,
            source: """
            typealias First = Second
            typealias Second = First
            struct Callbacks { var onCycle: First?; var receive: ImportedHandler? }
            """
        )
        #expect(report.violations.isEmpty)
    }

    @Test
    func localAliasesAndShadowedNamesDoNotChangeStoredContracts() throws {
        let report = try evaluateButtonHeistRules(
            path: "ButtonHeist/Sources/TheInsideJob/Callbacks.swift", component: .embeddedRuntime,
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
        #expect(report.violations.isEmpty)
    }
}
