import Foundation
import TheScore

/// Failure produced while routing an external command name into a Fence command.
///
/// This stays separate from `FenceError`: it describes pre-dispatch routing
/// failures before a concrete Fence command exists.
@_spi(ButtonHeistTooling) public struct FenceOperationRoutingError: Error, LocalizedError, Sendable {
    @_spi(ButtonHeistTooling) public let message: String
    @_spi(ButtonHeistTooling) public let details: FailureDetails

    @_spi(ButtonHeistTooling) public init(message: String, details: FailureDetails = FailureDetails(code: .requestInvalid)) {
        self.message = message
        self.details = details
    }

    public var errorDescription: String? { message }
}

/// Unadmitted boundary input. Execution can only consume its typed admission.
@_spi(ButtonHeistTooling) public struct FenceCommandInput: Sendable {
    @_spi(ButtonHeistTooling) public let command: TheFence.Command
    @_spi(ButtonHeistTooling) public let arguments: TheFence.CommandArgumentEnvelope

    @_spi(ButtonHeistTooling) public init(command: TheFence.Command, arguments: TheFence.CommandArgumentEnvelope) {
        self.command = command
        self.arguments = arguments
    }
}

/// Fully admitted command ready to enter TheFence's execution pipeline.
@_spi(ButtonHeistTooling) public struct AdmittedFenceCommand: Sendable {
    let requiresConnectionBeforeDispatch: Bool
    let execution: TheFence.CommandExecution
}

@_spi(ButtonHeistTooling) public extension TheFence.Command {
    static func routeToolCall(named name: String) throws(FenceOperationRoutingError) -> Self {
        guard let command = Self(rawValue: name),
              command.descriptor.mcpExposure == .directTool else {
            throw FenceOperationRoutingError(message: "Unknown tool: \(name)")
        }

        return command
    }

    static func routeToolRequest(
        named name: String,
        arguments: TheFence.CommandArgumentEnvelope
    ) throws(FenceOperationRoutingError) -> FenceCommandInput {
        FenceCommandInput(command: try routeToolCall(named: name), arguments: arguments)
    }

    static func routeCLICommandEnvelope(
        _ arguments: TheFence.CommandArgumentEnvelope,
        context: String
    ) throws(FenceOperationRoutingError) -> FenceCommandInput {
        try routeCanonicalStep(
            arguments,
            context: context,
            isExecutable: { $0.descriptor.cliExposure == .directCommand }
        )
    }
}

private extension TheFence.Command {
    static func routeCanonicalStep(
        _ step: TheFence.CommandArgumentEnvelope,
        context: String,
        isExecutable: ((Self) -> Bool)?
    ) throws(FenceOperationRoutingError) -> FenceCommandInput {
        let commandName: String
        do {
            commandName = try step.requiredValue(FenceParameters.commandName)
        } catch let error as SchemaValidationError {
            throw FenceOperationRoutingError(
                message: error.message,
                details: FailureDetails(code: .requestValidationError)
            )
        } catch {
            throw FenceOperationRoutingError(message: error.localizedDescription)
        }

        return try routeCanonicalStep(
            commandName: commandName,
            arguments: step.dropping("command"),
            context: context,
            isExecutable: isExecutable
        )
    }

    static func routeCanonicalStep(
        commandName: String,
        arguments: TheFence.CommandArgumentEnvelope,
        context: String,
        isExecutable: ((Self) -> Bool)?
    ) throws(FenceOperationRoutingError) -> FenceCommandInput {
        guard let command = Self(rawValue: commandName) else {
            throw FenceOperationRoutingError(
                message: "\(context) command must be a canonical TheFence.Command; unknown command \"\(commandName)\""
            )
        }

        if let isExecutable, !isExecutable(command) {
            throw FenceOperationRoutingError(
                message: "\(context) command \"\(command.rawValue)\" is not supported"
            )
        }

        return FenceCommandInput(command: command, arguments: arguments)
    }
}
