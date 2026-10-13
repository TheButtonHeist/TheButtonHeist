#if canImport(UIKit)
#if DEBUG
import Foundation
import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension HeistExecution {
    internal mutating func begin(
        action step: ActionStep,
        path: HeistExecutionPath,
        environment: HeistExecutionEnvironment
    ) -> HeistExecution.Decision {
        let command: ResolvedHeistActionCommand
        do {
            command = try step.command.resolve(in: environment)
        } catch {
            return resume(afterCompletedLeaf: HeistExecution.ResultProjector.actionResolutionFailure(
                step: step,
                path: path,
                error: error
            ))
        }

        let expectation: HeistExecution.ActionObservationExpectation
        let observationTimeout: Duration
        do {
            expectation = try HeistExecution.ActionObservationExpectation(
                step.expectationPolicy,
                bindings: environment
            )
            switch step.expectationPolicy {
            case .expect(let authored):
                observationTimeout = HeistExecution.duration(
                    authored.waitStep(using: actionExpectationTimeoutPolicy).timeout
                )
            case .default, .waived:
                observationTimeout = HeistExecution.duration(actionExpectationTimeoutPolicy.standard)
            }
        } catch {
            return resume(afterCompletedLeaf: HeistExecution.ResultProjector.expectationResolutionFailure(
                step: step,
                command: command,
                path: path,
                error: error
            ))
        }

        let id = nextID()
        let deadline = observationDeadline(observationTimeout)
        running.observationDeadline = deadline
        running.activeLeaf = .beginningAction(HeistExecution.ActionLeaf(
            id: id,
            step: step,
            command: command,
            expectation: expectation,
            path: path
        ))
        return perform(.beginObservation(
            id,
            scope: expectation.observationScope,
            deadline: activeDeadline
        ))
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
