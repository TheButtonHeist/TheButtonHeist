import Foundation
import ThePlans
import TheScore

extension TheFence {
    typealias ResponseOperation = @ButtonHeistActor @Sendable (TheFence) async throws -> FenceResponse

    struct DurableActionExecution: Sendable {
        let action: HeistActionCommand
        let expectation: ExpectationPayload

        init?(_ action: HeistActionCommand, expectation: ExpectationPayload) {
            guard action.durableHeistActionFailure == nil else { return nil }
            self.action = action
            self.expectation = expectation
        }

        var actionTimeoutOverride: WaitTimeout? {
            guard expectation.expectation == nil else { return nil }
            return expectation.timeout
        }
    }

    struct DirectActionExecution: Sendable {
        let action: HeistActionCommand
        let timeout: TimeInterval

        init?(_ action: HeistActionCommand, timeout: TimeInterval) {
            guard action.durableHeistActionFailure != nil else { return nil }
            self.action = action
            self.timeout = timeout
        }
    }

    enum CommandExecution: Sendable {
        case durableAction(DurableActionExecution)
        case directAction(DirectActionExecution)
        case response(ResponseOperation)

        init(response: @escaping ResponseOperation) {
            self = .response(response)
        }
    }

    private static func validateBoundaryShape(
        command: Command,
        arguments: CommandArgumentEnvelope
    ) throws {
        let descriptor = command.descriptor
        guard descriptor.isPublicRequestContract else {
            throw SchemaValidationError(
                field: "command",
                observed: "string \"\(command.rawValue)\"",
                expected: "public command for The Button Heist"
            )
        }
        let allowedKeys = descriptor.topLevelParameterKeys
        if let unexpectedKey = arguments.keys.sorted().first(where: { !allowedKeys.contains($0) }) {
            throw SchemaValidationError(
                field: arguments.field(forUnknownKey: unexpectedKey),
                observed: arguments.observedDescription(forUnknownKey: unexpectedKey) ?? "missing",
                expected: "valid \(command.rawValue) parameter"
            )
        }
        for parameter in descriptor.parameters {
            guard parameter.required, arguments.values[parameter.key] == nil else { continue }
            throw SchemaValidationError(
                field: arguments.field(forUnknownKey: parameter.key),
                observed: "missing",
                expected: parameter.expectedTypeDescription
            )
        }
    }

    func decodeAction(_ arguments: CommandArgumentEnvelope) throws -> HeistActionCommand {
        guard let value = arguments.value(for: "action") else {
            throw SchemaValidationError(
                field: arguments.field("action"),
                observed: "missing",
                expected: "heist action command object"
            )
        }
        return try HeistValuePayloadDecoder.decode(
            value,
            field: arguments.field("action"),
            as: HeistActionCommand.self
        )
    }

    static func appInteractionExecution(
        _ action: HeistActionCommand,
        expectationPayload: ExpectationPayload
    ) throws -> CommandExecution {
        if let execution = DurableActionExecution(action, expectation: expectationPayload) {
            return .durableAction(execution)
        }
        guard expectationPayload.expectation == nil else {
            throw FenceError.invalidRequest("command \"action\" direct dispatch does not support expect")
        }
        guard let execution = DirectActionExecution(
            action,
            timeout: HeistExecutionBudget.fixedActionTimeoutClass(for: action.wireType).seconds
        ) else {
            preconditionFailure("Action contract classified a durable action as direct execution")
        }
        return .directAction(execution)
    }

    /// Admit a routed public command input into TheFence's typed runtime.
    @_spi(ButtonHeistTooling) public func admit(_ input: FenceCommandInput) throws -> AdmittedFenceCommand {
        try Self.validateBoundaryShape(command: input.command, arguments: input.arguments)
        return AdmittedFenceCommand(
            requiresConnectionBeforeDispatch: input.command.descriptor.requiresConnectionBeforeDispatch,
            execution: try input.command.contract.admission(self, input.arguments)
        )
    }
}
