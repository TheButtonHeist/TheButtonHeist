public enum HeistPlanSource: Sendable, Equatable {
    case artifactPath(String)
    case inlineDSL(String)
}

public struct HeistPlanLoadRequest: Sendable, Equatable {
    public let commandName: String
    public let source: HeistPlanSource

    public init(commandName: String, source: HeistPlanSource) {
        self.commandName = commandName
        self.source = source
    }
}
