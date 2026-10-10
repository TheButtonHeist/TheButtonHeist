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
        "submodules"
        "tests/fixtures"
    }

    Architecture(ButtonHeistComponent.self) {
        Component(.plans) {
            Owns("ButtonHeist/Sources/ThePlans")
            Modules("ThePlans")
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistPlansBoundary)
            Applies(.buttonHeistNoUIAuthority)
            Applies(.buttonHeistNoNetworkAuthority)
            Applies(.buttonHeistNoSecurityAuthority)
            Applies(.buttonHeistNoObjectiveCAuthority)
            Applies(.buttonHeistNoAccessibilityParserAuthority)
        }

        Component(.score) {
            Owns("ButtonHeist/Sources/TheScore")
            Modules("TheScore")
            MayDependOn(.plans)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistScoreBoundary)
            Applies(.buttonHeistNoUIAuthority)
            Applies(.buttonHeistNoObjectiveCAuthority)
            Applies(.buttonHeistNoAccessibilityParserAuthority)
        }

        Component(.embeddedRuntime) {
            Owns(
                "ButtonHeist/Sources/TheInsideJob",
                "ButtonHeist/Sources/ThePlant"
            )
            Modules("TheInsideJob", "ThePlant")
            MayDependOn(.support, .plans, .score)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoSecurityAuthority)
        }

        Component(.client) {
            Owns("ButtonHeist/Sources/TheButtonHeist")
            Modules("ButtonHeist")
            MayDependOn(.support, .plans, .score)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoUIAuthority)
            Applies(.buttonHeistNoSecurityAuthority)
            Applies(.buttonHeistNoObjectiveCAuthority)
            Applies(.buttonHeistNoAccessibilityParserAuthority)
        }

        Component(.support) {
            Owns("ButtonHeist/Sources/ButtonHeistSupport")
            Modules("ButtonHeistSupport")
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoUIAuthority)
            Applies(.buttonHeistNoSecurityAuthority)
            Applies(.buttonHeistNoObjectiveCAuthority)
            Applies(.buttonHeistNoAccessibilityParserAuthority)
        }

        Component(.testing) {
            Owns("ButtonHeist/Sources/ButtonHeistTesting")
            Modules("ButtonHeistTesting")
            MayDependOn(.embeddedRuntime, .plans)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoUIAuthority)
            Applies(.buttonHeistNoNetworkAuthority)
            Applies(.buttonHeistNoSecurityAuthority)
            Applies(.buttonHeistNoObjectiveCAuthority)
            Applies(.buttonHeistNoAccessibilityParserAuthority)
        }

        Component(.planTool) {
            Owns("ButtonHeist/Sources/HeistPlanTool")
            Modules("HeistPlanTool")
            MayDependOn(.plans)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoUIAuthority)
            Applies(.buttonHeistNoNetworkAuthority)
            Applies(.buttonHeistNoSecurityAuthority)
            Applies(.buttonHeistNoObjectiveCAuthority)
            Applies(.buttonHeistNoAccessibilityParserAuthority)
        }

        Component(.cli) {
            Owns("ButtonHeistCLI/Sources")
            Modules("ButtonHeistCLIExe")
            MayDependOn(.client, .plans, .score)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoUIAuthority)
            Applies(.buttonHeistNoNetworkAuthority)
            Applies(.buttonHeistNoSecurityAuthority)
            Applies(.buttonHeistNoObjectiveCAuthority)
            Applies(.buttonHeistNoAccessibilityParserAuthority)
        }

        Component(.mcp) {
            Owns("ButtonHeistMCP/Sources")
            Modules("ButtonHeistMCP")
            MayDependOn(.client, .score)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoUIAuthority)
            Applies(.buttonHeistNoNetworkAuthority)
            Applies(.buttonHeistNoSecurityAuthority)
            Applies(.buttonHeistNoObjectiveCAuthority)
            Applies(.buttonHeistNoAccessibilityParserAuthority)
        }

        Component(.demo) {
            Owns("TestApp/Sources")
            MayDependOn(.plans, .score, .embeddedRuntime)
            Applies(.buttonHeistCheckedConcurrency)
            Applies(.buttonHeistNoNetworkAuthority)
            Applies(.buttonHeistNoSecurityAuthority)
            Applies(.buttonHeistNoObjectiveCAuthority)
            Applies(.buttonHeistNoAccessibilityParserAuthority)
        }
    }

    Rules {
        DependencyBoundaries(.error)
        SingleOwner(.error)
        AcyclicDeclaredDependencies(.error)
        buttonHeistRules
    }
}
