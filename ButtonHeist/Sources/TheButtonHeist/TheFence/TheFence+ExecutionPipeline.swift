extension TheFence {
    /// Execute one user intent.
    ///
    /// Durable UI actions run as a one-step `HeistPlan` on the device — the
    /// same engine that runs composed heists and authored waits.
    /// Transient runtime actions that are not durable heist primitives execute
    /// directly. Non-action commands retain their dedicated response operation.
    @_spi(ButtonHeistTooling) public func execute(_ admittedCommand: AdmittedFenceCommand) async throws -> FenceResponse {
        if !handoff.connectionLifecycle.isConnected,
           admittedCommand.requiresConnectionBeforeDispatch {
            try await start()
        }
        do {
            switch admittedCommand.execution {
            case .durableAction(let action):
                return try await executeDurableAction(action)
            case .directAction(let action):
                return try await executeDirectAction(action)
            case .response(let operation):
                return try await operation(self)
            }
        } catch let error as SchemaValidationError {
            return .failure(error)
        }
    }
}
