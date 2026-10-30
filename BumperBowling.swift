import BumperBowlingCore

let bumper = BumperProject {
    Included {
        "ButtonHeist/Sources"
        "ButtonHeistCLI/Sources"
        "ButtonHeistMCP/Sources"
        "TestApp/Sources"
    }

    Excluded {
        ".build"
        "Derived"
        "DerivedData"
        "tests/fixtures"
    }

    Architecture(ButtonHeistComponent.self) {
        Component(.plans) {
            Owns("ButtonHeist/Sources/ThePlans")
            Modules("ThePlans")
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistPlansBoundary)
            Applies(.buttonHeistNoUIImports)
            Applies(.buttonHeistNoObjectiveCImports)
            Applies(.buttonHeistNoAccessibilityParserImports)
        }

        Component(.score) {
            Owns("ButtonHeist/Sources/TheScore")
            Modules("TheScore")
            MayDependOn(.plans)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistScoreBoundary)
            Applies(.buttonHeistNoUIImports)
            Applies(.buttonHeistNoObjectiveCImports)
            Applies(.buttonHeistNoAccessibilityParserImports)
        }

        Component(.embeddedRuntime) {
            Owns(
                "ButtonHeist/Sources/TheInsideJob",
                "ButtonHeist/Sources/ThePlant"
            )
            Modules("TheInsideJob", "ThePlant")
            MayDependOn(.support, .plans, .score)
            Applies(.buttonHeistCheckedConcurrency)
        }

        Component(.client) {
            Owns("ButtonHeist/Sources/TheButtonHeist")
            Modules("ButtonHeist")
            MayDependOn(.support, .plans, .score)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoUIImports)
            Applies(.buttonHeistNoObjectiveCImports)
            Applies(.buttonHeistNoAccessibilityParserImports)
        }

        Component(.support) {
            Owns("ButtonHeist/Sources/ButtonHeistSupport")
            Modules("ButtonHeistSupport")
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoUIImports)
            Applies(.buttonHeistNoObjectiveCImports)
            Applies(.buttonHeistNoAccessibilityParserImports)
        }

        Component(.testing) {
            Owns("ButtonHeist/Sources/ButtonHeistTesting")
            Modules("ButtonHeistTesting")
            MayDependOn(.embeddedRuntime, .plans)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoUIImports)
            Applies(.buttonHeistNoObjectiveCImports)
            Applies(.buttonHeistNoAccessibilityParserImports)
        }

        Component(.cli) {
            Owns("ButtonHeistCLI/Sources")
            Modules("ButtonHeistCLIExe")
            MayDependOn(.client, .plans, .score)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoUIImports)
            Applies(.buttonHeistNoObjectiveCImports)
            Applies(.buttonHeistNoAccessibilityParserImports)
        }

        Component(.mcp) {
            Owns("ButtonHeistMCP/Sources")
            Modules("ButtonHeistMCP")
            MayDependOn(.client, .score)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoUIImports)
            Applies(.buttonHeistNoObjectiveCImports)
            Applies(.buttonHeistNoAccessibilityParserImports)
        }

        Component(.demo) {
            Owns("TestApp/Sources")
            MayDependOn(.plans, .score, .embeddedRuntime)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoObjectiveCImports)
            Applies(.buttonHeistNoAccessibilityParserImports)
        }
    }

    Rules {
        DependencyBoundaries(.error)
        SingleOwner(.error)
        AcyclicDeclaredDependencies(.error)
        buttonHeistRules
    }
}
