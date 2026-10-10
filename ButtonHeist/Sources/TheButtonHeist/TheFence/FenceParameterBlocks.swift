import ThePlans
import TheScore

internal enum FenceParameterBlocks: Sendable {
    internal static let interfaceSubtree = accessibilityTargetParam("subtree")

    private static let assertionProperties: [FenceParameterSpec] = [
        param("type", .string, required: true, enumValues: PredicateAssertionType.allCases.map(\.rawValue)),
        accessibilityTargetParam("target"),
        FenceParameters.elementProperty.spec,
        unconstrainedParam("before"),
        unconstrainedParam("after"),
    ]

    /// Canonical predicate shape used by action expectations.
    private static let accessibilityPredicateProperties: [FenceParameterSpec] = [
        param(
            "type",
            .string,
            required: true,
            enumValues: AccessibilityPredicate.wireTypeValues
        ),
        accessibilityTargetParam("target"),
        stringMatchParam("text"),
        objectParam(
            "element",
            properties: [predicateChecksParam("checks")]
        ),
        stringMatchParam("match"),
        param("scope", .string, enumValues: ChangedScope.allCases.map(\.rawValue)),
        arrayParam(
            "assertions",
            items: .object(properties: assertionProperties, additionalProperties: false)
        ),
    ]

    internal static let expect: FenceParameterSpec = objectParam(
        "expect",
        properties: accessibilityPredicateProperties
    )

    internal static let expectationTimeout = FenceParameters.timeout.spec
    internal static let expectation: [FenceParameterSpec] = [expect, expectationTimeout]

}

private enum ChangedScope: String, CaseIterable {
    case screen
    case elements
}

private enum PredicateAssertionType: String, CaseIterable {
    case exists
    case missing
    case appeared
    case disappeared
    case updated
}
