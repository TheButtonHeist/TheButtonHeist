import ThePlans
import TheScore

@_spi(ButtonHeistTooling) public enum FenceParameters {
    public static let action = objectParam("action", required: true)
    public static let commandName = FenceParameter<String>.string("command", required: true)
    public static let connectionTarget = FenceParameter<String>.string("target")
    public static let device = FenceParameter<String>.string("device")
    public static let elementProperty = FenceParameter<ElementProperty>.enumValue("property")
    public static let heistCatalogDetail = FenceParameter<HeistCatalogDetail>.enumValue(
        "detail",
        defaultValue: .summary
    )
    public static let heistName = FenceParameter<String>.string("heist", required: true)
    public static let heistTimeout = FenceParameter<HeistTimeout>.heistTimeout(
        "timeout",
        defaultValue: .default
    )
    public static let heistValidationLint = FenceParameter<HeistValidationLintMode>.enumValue(
        "lint",
        defaultValue: .compositionQuality
    )
    public static let inlineData = FenceParameter<Bool>.boolean("inlineData", defaultValue: false)
    public static let inlinePlan = FenceParameter<String>.string("plan")
    public static let interfaceDetail = FenceParameter<InterfaceDetail>.enumValue("detail", defaultValue: .summary)
    public static let maxScrollsPerContainer = FenceParameter<Int>.integer(
        "maxScrollsPerContainer",
        minimum: Double(InterfaceDiscoveryLimit.allowedRange.lowerBound),
        maximum: Double(InterfaceDiscoveryLimit.allowedRange.upperBound)
    )
    public static let maxScrollsPerDiscovery = FenceParameter<Int>.integer(
        "maxScrollsPerDiscovery",
        minimum: Double(InterfaceDiscoveryLimit.allowedRange.lowerBound),
        maximum: Double(InterfaceDiscoveryLimit.allowedRange.upperBound)
    )
    public static let output = FenceParameter<String>.string("output")
    public static let performStep = FenceParameter<String>.string("step", required: true, minLength: 1)
    public static let planPath = FenceParameter<String>.string("path")
    public static let screenMode = FenceParameter<ScreenCaptureMode>.enumValue("mode", defaultValue: .raw)
    public static let timeout = FenceParameter<Double>.number(
        "timeout",
        maximum: WaitTimeout.maximumSeconds,
        exclusiveMinimum: 0
    )
    public static let token = FenceParameter<String>.string("token")
}

internal func param(
    _ key: String,
    _ kind: JSONSchema.Scalar,
    required: Bool = false,
    enumValues: [String]? = nil,
    defaultValue: HeistValue? = nil,
    minimum: Double? = nil,
    maximum: Double? = nil,
    exclusiveMinimum: Double? = nil,
    minLength: Int? = nil
) -> FenceParameterSpec {
    FenceParameterSpec(
        key: key,
        schema: .scalar(
            kind,
            enumValues: enumValues,
            defaultValue: defaultValue,
            minimum: minimum,
            maximum: maximum,
            exclusiveMinimum: exclusiveMinimum,
            minLength: minLength
        ),
        required: required
    )
}

internal func objectParam(
    _ key: String,
    required: Bool = false
) -> FenceParameterSpec {
    FenceParameterSpec(
        key: key,
        schema: .object(),
        required: required
    )
}

internal func objectParam(
    _ key: String,
    required: Bool = false,
    properties: [FenceParameterSpec],
    additionalProperties: Bool = false
) -> FenceParameterSpec {
    FenceParameterSpec(
        key: key,
        schema: .object(properties: properties, additionalProperties: additionalProperties),
        required: required
    )
}

internal func arrayParam(
    _ key: String,
    required: Bool = false,
    items: JSONSchema? = nil,
    minItems: Int? = nil,
    maxItems: Int? = nil
) -> FenceParameterSpec {
    FenceParameterSpec(
        key: key,
        schema: .array(
            items: items,
            minItems: minItems,
            maxItems: maxItems
        ),
        required: required
    )
}

internal func unconstrainedParam(
    _ key: String,
    required: Bool = false
) -> FenceParameterSpec {
    FenceParameterSpec(
        key: key,
        schema: .unconstrained,
        required: required
    )
}

internal func accessibilityTargetParam(
    _ key: String,
    required: Bool = false
) -> FenceParameterSpec {
    FenceParameterSpec(
        key: key,
        schema: .reference(AccessibilityTargetSchemaDefinition.reference),
        required: required
    )
}

internal func stringMatchParam(
    _ key: String,
    required: Bool = false,
    allowsArray: Bool = false
) -> FenceParameterSpec {
    let modeValues = StringMatch.Mode.allCases.map(\.rawValue)
    let description = "StringMatch object with mode \(modeValues.joined(separator: "/")) and optional value. " +
        "Use mode exact for exact matching. Broad modes require a non-empty value; isEmpty must omit value." +
        (allowsArray
            ? " Element matcher fields also accept an array of StringMatch objects; every object must match."
            : "")
    return FenceParameterSpec(
        key: key,
        schema: .scalar(.stringMatch(modeValues: modeValues, description: description)),
        required: required
    )
}

internal func containerPredicateParam(_ key: String) -> FenceParameterSpec {
    objectParam(
        key,
        properties: [
            arrayParam(
                "checks",
                required: true,
                items: .object(
                    properties: containerPredicateCheckProperties,
                    additionalProperties: false
                ),
                minItems: 1
            ),
        ]
    )
}

internal func accessibilityTargetProperties() -> [FenceParameterSpec] {
    [
        predicateChecksParam("checks"),
        param("ref", .string),
        param("ordinal", .integer, minimum: 0),
        containerPredicateParam("container"),
        FenceParameterSpec(
            key: "target",
            schema: .reference(AccessibilityTargetSchemaDefinition.reference),
            required: false
        ),
    ]
}

internal func predicateChecksParam(_ key: String) -> FenceParameterSpec {
    arrayParam(
        key,
        items: .object(
            properties: [
                param(
                    "kind", .string, required: true,
                    enumValues: ElementPredicateCheck.Kind.allCases.map(\.rawValue)
                ),
                stringMatchParam("match"),
                arrayParam("values", items: .unconstrained),
                objectParam("check"),
            ],
            additionalProperties: false
        )
    )
}

private let semanticContainerPredicateProperties: [FenceParameterSpec] = [
    param("kind", .string, required: true, enumValues: semanticContainerPredicateKindValues),
    stringMatchParam("match", required: true),
]

private let semanticContainerPredicateKindValues: [String] = [
    SemanticContainerPredicate.label("sample"),
    SemanticContainerPredicate.value("sample"),
].map(\.wireKindValue)

private let containerPredicateCheckProperties: [FenceParameterSpec] = [
    param(
        "kind", .string, required: true,
        enumValues: ContainerPredicateCheck.wireKindValues
    ),
    param("type", .string, enumValues: AccessibilityContainerKind.allCases.map(\.rawValue)),
    stringMatchParam("match"),
    objectParam(
        "semantic",
        properties: semanticContainerPredicateProperties
    ),
    arrayParam("values", items: .unconstrained, minItems: 1),
    unconstrainedParam("value"),
]
