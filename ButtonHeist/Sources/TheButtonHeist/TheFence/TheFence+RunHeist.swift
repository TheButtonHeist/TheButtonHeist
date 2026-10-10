import Foundation

import ThePlans
import TheScore

extension TheFence {

    // MARK: - Heist Execution and Session State

    func handleRunHeist(_ request: RunHeistRequest) async throws -> FenceResponse {
        try await dispatchHeistPlan(
            request.plan,
            argument: request.argument,
            timeoutSource: .requested(request.timeout)
        )
    }

    func handlePerform(_ request: PerformRequest) async throws -> FenceResponse {
        try await dispatchHeistPlan(
            request.plan,
            timeoutSource: .projected(actionTimeoutOverride: nil)
        )
    }

    func handleListHeists(_ request: ListHeistsRequest) -> FenceResponse {
        .heistCatalog(request.descriptions, detail: request.detail)
    }

    func handleDescribeHeist(_ request: DescribeHeistRequest) -> FenceResponse {
        .heistDescription(request.description)
    }

    /// Dispatch a `HeistPlan` to the device and project its execution into a
    /// `.heistExecution` response. Durable single commands and composed heists
    /// share this one path; transient commands use direct client dispatch.
    private func dispatchHeistPlan(
        _ plan: HeistPlan,
        argument: HeistArgument = .none,
        timeoutSource: HeistExecutionBudget.TimeoutSource
    ) async throws -> FenceResponse {
        let budget = try HeistExecutionBudget.project(
            plan: plan,
            timeoutSource: timeoutSource,
            configuration: config
        )
        let result = try await sendAndAwaitHeistExecution(
            plan,
            argument: argument,
            budget: budget
        )
        HeistResultRecording.recordIfEnabled(result, plan: plan)
        return .heistExecution(
            plan: plan,
            report: HeistReport.project(result: result)
        )
    }

    // MARK: - Durable Action Execution

    /// Project an admitted durable action onto the canonical plan runtime.
    func durableActionPlan(for execution: DurableActionExecution) throws -> HeistPlan {
        let expectationPolicy = execution.expectation.expectation.map {
            ActionExpectationPolicy.expect(ActionExpectation(
                predicate: $0,
                timeout: execution.expectation.timeout
            ))
        } ?? .default
        return try HeistPlan(version: HeistPlan.currentVersion, body: [
            .action(ActionStep(command: execution.action, expectationPolicy: expectationPolicy))
        ])
    }

    func executeDurableAction(_ execution: DurableActionExecution) async throws -> FenceResponse {
        let plan = try durableActionPlan(for: execution)
        return try await dispatchHeistPlan(
            plan,
            timeoutSource: .projected(
                actionTimeoutOverride: execution.actionTimeoutOverride
            )
        )
    }

    // MARK: - Session State

    func currentSessionState() -> SessionStatePayload {
        return SessionStatePayload(
            state: sessionConnectionState,
            actionTimeoutSeconds: FenceCommandFixedTimeout.standardAction.seconds,
            longActionTimeoutSeconds: FenceCommandFixedTimeout.longAction.seconds
        )
    }
}

extension TheFence {
    struct HeistExecutionBudget: Sendable {
        enum TimeoutSource: Sendable {
            case requested(HeistTimeout?)
            case projected(actionTimeoutOverride: WaitTimeout?)
        }

        enum Error: Swift.Error, Sendable, Equatable {
            case invalidTransportHeadroom(TimeInterval)
            case transportTimeoutOverflow(
                serverTimeout: HeistTimeout,
                transportHeadroom: TimeInterval
            )
            case unsupportedProjectedPlan
        }

        let serverTimeout: HeistTimeout
        let transportTimeout: TimeInterval
        let actionExpectationTimeoutPolicy: ActionExpectationTimeoutPolicy

        private init(
            serverTimeout: HeistTimeout,
            transportTimeout: TimeInterval,
            actionExpectationTimeoutPolicy: ActionExpectationTimeoutPolicy
        ) {
            self.serverTimeout = serverTimeout
            self.transportTimeout = transportTimeout
            self.actionExpectationTimeoutPolicy = actionExpectationTimeoutPolicy
        }

        static func project(
            plan: HeistPlan,
            timeoutSource: TimeoutSource,
            configuration: Configuration
        ) throws -> Self {
            guard configuration.postActionExpectationTimeoutBuffer.isFinite,
                  configuration.postActionExpectationTimeoutBuffer >= 0
            else {
                throw Error.invalidTransportHeadroom(configuration.postActionExpectationTimeoutBuffer)
            }

            let serverTimeout = try serverTimeout(
                for: plan,
                source: timeoutSource,
                policy: configuration.actionExpectationTimeoutPolicy
            )
            let transportTimeout = serverTimeout.seconds + configuration.postActionExpectationTimeoutBuffer
            guard transportTimeout.isFinite else {
                throw Error.transportTimeoutOverflow(
                    serverTimeout: serverTimeout,
                    transportHeadroom: configuration.postActionExpectationTimeoutBuffer
                )
            }
            return Self(
                serverTimeout: serverTimeout,
                transportTimeout: transportTimeout,
                actionExpectationTimeoutPolicy: configuration.actionExpectationTimeoutPolicy
            )
        }

        private static func serverTimeout(
            for plan: HeistPlan,
            source: TimeoutSource,
            policy: ActionExpectationTimeoutPolicy
        ) throws -> HeistTimeout {
            switch source {
            case .requested(let requestedTimeout):
                return requestedTimeout ?? .default
            case .projected(let actionTimeoutOverride):
                return try projectedSingleStepTimeout(
                    in: plan,
                    actionTimeoutOverride: actionTimeoutOverride,
                    policy: policy
                )
            }
        }

        private static func projectedSingleStepTimeout(
            in plan: HeistPlan,
            actionTimeoutOverride: WaitTimeout?,
            policy: ActionExpectationTimeoutPolicy
        ) throws -> HeistTimeout {
            guard plan.definitions.isEmpty, plan.body.count == 1, let step = plan.body.first else {
                throw Error.unsupportedProjectedPlan
            }
            let seconds = switch step {
            case .wait(let wait):
                wait.timeout.seconds
            case .action(let action):
                actionTimeout(
                    for: action,
                    override: actionTimeoutOverride,
                    policy: policy
                )
            case .conditional, .forEachElement, .forEachString, .repeatUntil, .warn, .fail, .heist, .invoke:
                throw Error.unsupportedProjectedPlan
            }
            return try HeistTimeout(validatingSeconds: seconds)
        }

        private static func actionTimeout(
            for action: ActionStep,
            override actionTimeoutOverride: WaitTimeout?,
            policy: ActionExpectationTimeoutPolicy
        ) -> TimeInterval {
            let actionBudget = fixedActionTimeout(for: action.command).seconds
            let settlementTimeout = action.expectationPolicy.expectedExpectation?
                .waitStep(using: policy).timeout ?? policy.standard
            return max(actionBudget, actionTimeoutOverride?.seconds ?? actionBudget)
                + settlementTimeout.seconds
        }

        private static func fixedActionTimeout(for action: HeistActionCommand) -> FenceCommandFixedTimeout {
            fixedActionTimeoutClass(for: action.wireType)
        }

        static func fixedActionTimeoutClass(for type: HeistActionCommandType) -> FenceCommandFixedTimeout {
            type == .typeText ? .longAction : .standardAction
        }

    }
}
