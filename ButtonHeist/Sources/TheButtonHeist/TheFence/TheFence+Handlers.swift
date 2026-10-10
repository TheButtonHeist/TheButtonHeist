import Foundation
import ThePlans

import TheScore

@ButtonHeistActor
extension TheFence {

    // MARK: - Handler: Interface

    func handlePing(timeout: TimeInterval) async throws -> FenceResponse {
        let payload = try await sendAndAwaitPong(timeout: timeout)
        return .pong(payload)
    }

    func handleGetInterface(_ request: GetInterfaceRequest, timeout: TimeInterval) async throws -> FenceResponse {
        let interface = try await sendAndAwaitInterface(
            .requestInterface(request.query),
            timeout: timeout
        )
        return .interface(interface, detail: request.detail)
    }

    func handleGetPasteboard(timeout: TimeInterval) async throws -> FenceResponse {
        let result = try await sendAndAwaitAction(
            .getPasteboard,
            timeout: timeout
        )
        return .action(result: result)
    }

    func handleGetNotifications(timeout: TimeInterval) async throws -> FenceResponse {
        let notifications = try await sendAndAwaitNotifications(
            timeout: timeout
        )
        return .notifications(notifications)
    }

    // MARK: - Direct Action Execution

    func executeDirectAction(_ execution: DirectActionExecution) async throws -> FenceResponse {
        let result = try await sendAndAwaitAction(
            .runtimeAction(execution.action),
            timeout: execution.timeout
        )
        return .action(result: result)
    }

}
