import Foundation

import ThePlans
import TheScore

extension TheFence {

    // MARK: - Send Action

    func sendAndAwaitAction(_ message: ClientMessage, timeout: TimeInterval) async throws -> ActionResult {
        try await sendAndAwait(message, expecting: .action, timeout: timeout)
    }

    func sendAndAwaitPong(timeout: TimeInterval) async throws -> PongPayload {
        try await sendAndAwait(.ping, expecting: .pong, timeout: timeout)
    }

    func sendAndAwaitInterface(_ message: ClientMessage, timeout: TimeInterval) async throws -> Interface {
        try await sendAndAwait(message, expecting: .interface, timeout: timeout)
    }

    func sendAndAwaitScreen(
        _ message: ClientMessage,
        timeout: TimeInterval
    ) async throws -> ScreenPayload {
        try await sendAndAwait(message, expecting: .screen, timeout: timeout)
    }

    func sendAndAwaitNotifications(
        timeout: TimeInterval
    ) async throws -> [Observation.Notification] {
        try await sendAndAwait(
            .getNotifications,
            expecting: .notifications,
            timeout: timeout
        )
    }

    func sendAndAwaitHeistExecution(
        _ plan: HeistPlan,
        argument: HeistArgument = .none,
        budget: HeistExecutionBudget
    ) async throws -> HeistResult {
        let message = ClientMessage.heistPlan(HeistPlanRun(
            plan: plan,
            argument: argument,
            timeout: budget.serverTimeout,
            actionExpectationTimeoutPolicy: budget.actionExpectationTimeoutPolicy
        ))
        return try await sendAndAwait(
            message,
            expecting: .heistExecution,
            timeout: budget.transportTimeout
        )
    }

    func cancelAllPendingRequests(error: Error = FenceError.actionTimeout) {
        pendingRequests.cancelAll(error: error)
    }

    private func sendAndAwait<Response: Sendable>(
        _ message: ClientMessage,
        expecting expectation: PendingResponseExpectation<Response>,
        timeout: TimeInterval
    ) async throws -> Response {
        guard handoff.connectionLifecycle.isConnected else { throw FenceError.notConnected }
        let requestId = RequestID()
        return try await pendingRequests.waitForResponse(
            expectation,
            requestId: requestId,
            timeout: timeout
        ) {
            self.sendClientMessage(message, requestId: requestId)
        }
    }

    private func sendClientMessage(
        _ message: ClientMessage,
        requestId: RequestID
    ) {
        let outcome = handoff.send(
            message,
            requestId: requestId
        )
        if case .failed(let failure) = outcome {
            pendingRequests.resolveTransientFailure(FenceError(failure), requestId: requestId)
        }
    }
}
