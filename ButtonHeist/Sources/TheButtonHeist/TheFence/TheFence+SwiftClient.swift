import ThePlans
import TheScore

extension TheFence {
    // MARK: - Typed Swift Operations

    /// Run a plan and return its execution outcome, timing, and evidence unchanged.
    public func run(
        _ plan: HeistPlan,
        argument: HeistArgument = .none,
        timeout: HeistTimeout = .default
    ) async throws -> HeistResult {
        try await executeHeistPlan(plan, argument: argument, timeoutSource: .requested(timeout))
    }

    /// Author and run a plan through the same typed execution operation.
    public func run(
        timeout: HeistTimeout = .default,
        @HeistBuilder _ content: @ButtonHeistActor () throws -> HeistContent
    ) async throws -> HeistResult {
        try await run(HeistPlan(content), timeout: timeout)
    }

    /// Capture semantic evidence and geometry from the requested interface scope.
    public func captureInterface(
        _ query: InterfaceQuery = InterfaceQuery(capture: .current),
        timeout: HeistTimeout = .default
    ) async throws -> Interface {
        try Task.checkCancellation()
        try await start()
        return try await sendAndAwaitInterface(.requestInterface(query), timeout: timeout.seconds)
    }
}
