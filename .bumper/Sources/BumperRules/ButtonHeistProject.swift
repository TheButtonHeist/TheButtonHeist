import BumperBowlingCore

/// Source boundaries that supplement Swift's build and type checks.
public let buttonHeistProject = BumperProject(
    included: ["ButtonHeist/Sources", "ButtonHeistCLI/Sources", "ButtonHeistMCP/Sources", "TestApp/Sources"],
    excluded: [".build", "Derived", "DerivedData", "tests/fixtures"]
) {
    SourceOwnershipRule.self
    ComponentBoundaryRule.self
    PlatformImportRule.self
    CheckedConcurrencyRule.self
    UncheckedSendableBoundaryRule.self
    DemoAccessibilityIdentifierRule.self
    AnyBoundaryRule.self
    TransportImportOwnershipRule.self
    SecurityImportOwnershipRule.self
    CallbackIsolationRule.self
    HeistContentOpacityRule.self
    PlanElseOwnershipRule.self
    ExportedTupleContractRule.self
}
