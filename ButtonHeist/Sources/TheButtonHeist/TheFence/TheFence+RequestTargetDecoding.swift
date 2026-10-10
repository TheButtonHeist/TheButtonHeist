import ThePlans

extension TheFence.CommandArgumentEnvelope {
    func decodeAccessibilityTargetPayload() throws -> AccessibilityTarget {
        try TheFence.HeistValuePayloadDecoder.decode(
            objectValue,
            field: argumentFieldPrefix ?? "target",
            as: AccessibilityTarget.self
        )
    }
}
