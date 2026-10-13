#if canImport(UIKit)
#if DEBUG
import Foundation
import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension HeistExecution {
    internal mutating func begin(
        wait step: WaitStep,
        context: HeistExecution.StepContext
    ) -> HeistExecution.Decision {
        let predicate: HeistExecution.Predicate
        do {
            predicate = try HeistExecution.Predicate(
                authored: step.predicate,
                bindings: context.environment
            )
        } catch {
            return resume(afterCompletedLeaf: HeistExecution.ResultProjector.waitResolutionFailure(
                step: step,
                context: context,
                error: error
            ))
        }

        return begin(
            wait: predicate,
            purpose: .authored(step: step, context: context),
            timeout: step.timeout
        )
    }

    internal mutating func begin(
        wait predicate: HeistExecution.Predicate,
        purpose: HeistExecution.WaitPurpose,
        timeout: WaitTimeout
    ) -> HeistExecution.Decision {
        let id = nextID()
        let deadline = observationDeadline(HeistExecution.duration(timeout))
        running.observationDeadline = deadline
        running.activeLeaf = .beginningWait(HeistExecution.WaitLeaf(
            id: id,
            predicate: predicate,
            purpose: purpose
        ))
        return perform(.beginObservation(
            id,
            scope: predicate.observationScope,
            deadline: activeDeadline
        ))
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
