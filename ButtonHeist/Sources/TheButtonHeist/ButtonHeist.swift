import ThePlans
import TheScore

/// Connect for a sequence of typed operations, then disconnect on every exit path.
@ButtonHeistActor
public func withSession<Value: Sendable>(
    _ session: EnvironmentConfig,
    operation: @ButtonHeistActor (TheFence) async throws -> Value
) async throws -> Value {
    let heist = TheFence(configuration: session.fenceConfiguration)
    return try await withSession(heist, operation: operation)
}

/// Run a validated plan over a connection scoped to this call.
@ButtonHeistActor
public func run(
    _ plan: HeistPlan,
    configuration: EnvironmentConfig,
    argument: HeistArgument = .none,
    timeout: HeistTimeout = .default
) async throws -> HeistResult {
    try await withSession(configuration) { heist in
        try await heist.run(plan, argument: argument, timeout: timeout)
    }
}

/// Author and run a plan over a connection scoped to this call.
@ButtonHeistActor
public func run(
    configuration: EnvironmentConfig,
    timeout: HeistTimeout = .default,
    @HeistBuilder _ content: @ButtonHeistActor () throws -> HeistContent
) async throws -> HeistResult {
    try await run(HeistPlan(content), configuration: configuration, timeout: timeout)
}

@ButtonHeistActor
func withSession<Value: Sendable>(
    _ heist: TheFence,
    operation: @ButtonHeistActor (TheFence) async throws -> Value
) async throws -> Value {
    defer { heist.stop() }
    try Task.checkCancellation()
    try await heist.start()
    try Task.checkCancellation()
    return try await operation(heist)
}
