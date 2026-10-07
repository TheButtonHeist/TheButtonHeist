#if canImport(UIKit)
#if DEBUG
import Foundation

import ButtonHeistSupport

@MainActor
extension TheInsideJob {
    enum ServerPhase: Equatable {
        case stopped
        case starting(InsideJobTransportStartRequest)
        case running(InsideJobRuntimeResources)
        case suspending(InsideJobSuspension)
        case suspended(InsideJobSuspendedRuntime)
        case resuming(InsideJobResumeAttempt)
        case stopping(InsideJobStopAttempt)

        static func == (lhs: ServerPhase, rhs: ServerPhase) -> Bool {
            switch (lhs, rhs) {
            case (.stopped, .stopped):
                return true
            case (.starting(let lhsAttempt), .starting(let rhsAttempt)):
                return lhsAttempt == rhsAttempt
            case (.running(let lhsResources), .running(let rhsResources)):
                return lhsResources == rhsResources
            case (.suspending(let lhsSuspension), .suspending(let rhsSuspension)):
                return lhsSuspension == rhsSuspension
            case (.suspended(let lhsRuntime), .suspended(let rhsRuntime)):
                return lhsRuntime == rhsRuntime
            case (.resuming(let lhsAttempt), .resuming(let rhsAttempt)):
                return lhsAttempt == rhsAttempt
            case (.stopping(let lhsAttempt), .stopping(let rhsAttempt)):
                return lhsAttempt == rhsAttempt
            case (.stopped, _),
                 (.starting, _),
                 (.running, _),
                 (.suspending, _),
                 (.suspended, _),
                 (.resuming, _),
                 (.stopping, _):
                return false
            }
        }
    }

    struct InsideJobRuntimeResources: Equatable {
        let transport: ServerTransport
        let actualPort: UInt16
        let bonjourServiceName: String?
        let idleTimerBaseline: Bool

        static func == (lhs: InsideJobRuntimeResources, rhs: InsideJobRuntimeResources) -> Bool {
            lhs.transport === rhs.transport
                && lhs.actualPort == rhs.actualPort
                && lhs.bonjourServiceName == rhs.bonjourServiceName
                && lhs.idleTimerBaseline == rhs.idleTimerBaseline
        }
    }

    struct InsideJobSuspendedRuntime: Equatable, Sendable {
        let idleTimerBaseline: Bool
    }

    struct InsideJobSuspension: Equatable {
        let id: UUID
        let resources: InsideJobRuntimeResources
    }

    struct InsideJobResumeAttempt: Equatable, Sendable {
        let id: UUID
        let suspendedRuntime: InsideJobSuspendedRuntime
        let task: Task<Void, Never>

        static func == (lhs: InsideJobResumeAttempt, rhs: InsideJobResumeAttempt) -> Bool {
            lhs.id == rhs.id && lhs.suspendedRuntime == rhs.suspendedRuntime
        }
    }

    struct InsideJobStopAttempt: Equatable, Sendable {
        static let timeout: Duration = .seconds(5)

        let id: UUID
        private let completion: CompletionSignal

        @MainActor
        init(id: UUID) {
            self.id = id
            completion = CompletionSignal()
        }

        @MainActor
        func waitForCompletion(timeout: Duration = Self.timeout) async -> Bool {
            await completion.wait(timeout: timeout)
        }

        @MainActor
        func finish() {
            completion.finish()
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
        }
    }

    enum RuntimeReleasePolicy: Equatable, Sendable {
        case suspend
        case stop
    }

    struct InsideJobTransportStartRequest: Equatable {
        let id: UUID
        let transport: ServerTransport
        let idleTimerBaseline: Bool

        static func == (
            lhs: InsideJobTransportStartRequest,
            rhs: InsideJobTransportStartRequest
        ) -> Bool {
            lhs.id == rhs.id
                && lhs.transport === rhs.transport
                && lhs.idleTimerBaseline == rhs.idleTimerBaseline
        }
    }

    enum LifecycleObservationState: Equatable, Sendable {
        case uninstalled
        case installed

        var isInstalled: Bool {
            switch self {
            case .installed:
                return true
            case .uninstalled:
                return false
            }
        }

        mutating func installIfNeeded() -> Bool {
            guard case .uninstalled = self else { return false }
            self = .installed
            return true
        }

        mutating func uninstallIfNeeded() -> Bool {
            guard case .installed = self else { return false }
            self = .uninstalled
            return true
        }
    }

}

struct InsideJobLifecycleReducer: @MainActor StateReducer {
    typealias State = TheInsideJob.ServerPhase
    typealias Transition = StateTransition<State, Effect, Rejection>

    enum Event: Equatable {
        case lifecycleSuspensionNotification
        case foregroundNotification(replacingExisting: Bool)
        case terminationNotification
        case startRequested(TheInsideJob.InsideJobTransportStartRequest)
        case startSucceeded(UUID, TheInsideJob.InsideJobRuntimeResources)
        case startFailed(UUID)
        case stopRequested(TheInsideJob.InsideJobStopAttempt)
        case stopFinished(UUID)
        case suspendRequested(TheInsideJob.InsideJobSuspension?)
        case suspendFinished(UUID)
        case resumeRequested(TheInsideJob.InsideJobResumeAttempt)
        case resumeTransportRequested(TheInsideJob.InsideJobTransportStartRequest)
        case resumeSucceeded(UUID, TheInsideJob.InsideJobRuntimeResources)
        case resumeFailed(UUID)

        static func == (lhs: Event, rhs: Event) -> Bool {
            switch (lhs, rhs) {
            case (.lifecycleSuspensionNotification, .lifecycleSuspensionNotification),
                 (.terminationNotification, .terminationNotification):
                return true
            case (
                .foregroundNotification(let lhsReplacingExisting),
                .foregroundNotification(let rhsReplacingExisting)
            ):
                return lhsReplacingExisting == rhsReplacingExisting
            case (.startRequested(let lhsRequest), .startRequested(let rhsRequest)):
                return lhsRequest == rhsRequest
            case (.startSucceeded(let lhsID, let lhsResources), .startSucceeded(let rhsID, let rhsResources)):
                return lhsID == rhsID && lhsResources == rhsResources
            case (.startFailed(let lhsID), .startFailed(let rhsID)):
                return lhsID == rhsID
            case (.stopRequested(let lhsAttempt), .stopRequested(let rhsAttempt)):
                return lhsAttempt == rhsAttempt
            case (.stopFinished(let lhsID), .stopFinished(let rhsID)):
                return lhsID == rhsID
            case (.suspendRequested(let lhsSuspension), .suspendRequested(let rhsSuspension)):
                return lhsSuspension == rhsSuspension
            case (.suspendFinished(let lhsID), .suspendFinished(let rhsID)):
                return lhsID == rhsID
            case (.resumeRequested(let lhsAttempt), .resumeRequested(let rhsAttempt)):
                return lhsAttempt == rhsAttempt
            case (.resumeTransportRequested(let lhsRequest), .resumeTransportRequested(let rhsRequest)):
                return lhsRequest == rhsRequest
            case (.resumeSucceeded(let lhsID, let lhsResources), .resumeSucceeded(let rhsID, let rhsResources)):
                return lhsID == rhsID && lhsResources == rhsResources
            case (.resumeFailed(let lhsID), .resumeFailed(let rhsID)):
                return lhsID == rhsID
            default:
                return false
            }
        }
    }

    enum Effect: Equatable {
        case scheduleSuspend
        case scheduleResume(afterCancelling: TheInsideJob.InsideJobResumeAttempt?)
        case scheduleStop
        case stopTransport(ServerTransport)
        case cleanupTransport(ServerTransport)
        case releaseResources(policy: TheInsideJob.RuntimeReleasePolicy, idleTimerBaseline: Bool)
        case cancelResume(TheInsideJob.InsideJobResumeAttempt)
        case activateRuntime
        case tearDownRuntimeServices

        static func == (lhs: Effect, rhs: Effect) -> Bool {
            switch (lhs, rhs) {
            case (.scheduleSuspend, .scheduleSuspend),
                 (.scheduleStop, .scheduleStop),
                 (.activateRuntime, .activateRuntime),
                 (.tearDownRuntimeServices, .tearDownRuntimeServices):
                return true
            case (
                .scheduleResume(let lhsAttempt),
                .scheduleResume(let rhsAttempt)
            ):
                return lhsAttempt == rhsAttempt
            case (.stopTransport(let lhsTransport), .stopTransport(let rhsTransport)):
                return lhsTransport === rhsTransport
            case (.cleanupTransport(let lhsTransport), .cleanupTransport(let rhsTransport)):
                return lhsTransport === rhsTransport
            case (
                .releaseResources(let lhsPolicy, let lhsIdleTimerBaseline),
                .releaseResources(let rhsPolicy, let rhsIdleTimerBaseline)
            ):
                return lhsPolicy == rhsPolicy && lhsIdleTimerBaseline == rhsIdleTimerBaseline
            case (.cancelResume(let lhsAttempt), .cancelResume(let rhsAttempt)):
                return lhsAttempt == rhsAttempt
            default:
                return false
            }
        }
    }

    enum Rejection: Equatable, Sendable {
        case alreadyActive
        case alreadyStopped
        case alreadyStopping
        case notRunning
        case notSuspended
        case staleStartAttempt
        case staleSuspendAttempt
        case staleResumeAttempt
        case staleStopAttempt
    }

    @MainActor
    func reduce(_ state: State, event: Event) -> Transition {
        switch event {
        case .lifecycleSuspensionNotification:
            return .changed(to: state, effects: [.scheduleSuspend])
        case .foregroundNotification(let replacingExisting):
            return foreground(state, replacingExisting: replacingExisting)
        case .terminationNotification:
            return .changed(to: state, effects: [.scheduleStop])
        case .startRequested(let request):
            return startRequested(state, request: request)
        case .startSucceeded(let id, let resources):
            return startSucceeded(state, id: id, resources: resources)
        case .startFailed(let id):
            return startFailed(state, id: id)
        case .stopRequested(let attempt):
            return stopRequested(state, attempt: attempt)
        case .stopFinished(let id):
            return stopFinished(state, id: id)
        case .suspendRequested(let suspension):
            return suspendRequested(state, suspension: suspension)
        case .suspendFinished(let id):
            return suspendFinished(state, id: id)
        case .resumeRequested(let attempt):
            return resumeRequested(state, attempt: attempt)
        case .resumeTransportRequested(let request):
            return resumeTransportRequested(state, request: request)
        case .resumeSucceeded(let id, let resources):
            return resumeSucceeded(state, id: id, resources: resources)
        case .resumeFailed(let id):
            return resumeFailed(state, id: id)
        }
    }

    private func foreground(_ state: State, replacingExisting: Bool) -> Transition {
        switch state {
        case .suspended:
            return .changed(to: state, effects: [.scheduleResume(afterCancelling: nil)])
        case .resuming(let attempt) where replacingExisting:
            return .changed(to: state, effects: [.scheduleResume(afterCancelling: attempt)])
        case .stopped, .starting, .running, .suspending, .resuming, .stopping:
            return .changed(to: state)
        }
    }

    private func startRequested(
        _ state: State,
        request: TheInsideJob.InsideJobTransportStartRequest
    ) -> Transition {
        guard case .stopped = state else {
            return .rejected(.alreadyActive, stayingIn: state)
        }
        return .changed(to: .starting(request))
    }

    private func startSucceeded(
        _ state: State,
        id: UUID,
        resources: TheInsideJob.InsideJobRuntimeResources
    ) -> Transition {
        guard case .starting(let request) = state, request.id == id else {
            return .rejected(.staleStartAttempt, stayingIn: state)
        }
        return .changed(to: .running(resources), effects: [.activateRuntime])
    }

    private func startFailed(_ state: State, id: UUID) -> Transition {
        guard case .starting(let request) = state, request.id == id else {
            return .rejected(.staleStartAttempt, stayingIn: state)
        }
        return .changed(to: .stopped, effects: [.cleanupTransport(request.transport)])
    }

    private func stopRequested(
        _ state: State,
        attempt stopAttempt: TheInsideJob.InsideJobStopAttempt
    ) -> Transition {
        switch state {
        case .stopped:
            return .rejected(.alreadyStopped, stayingIn: state)
        case .stopping:
            return .rejected(.alreadyStopping, stayingIn: state)
        case .starting(let request):
            return .changed(
                to: .stopping(stopAttempt),
                effects: [.tearDownRuntimeServices, .cleanupTransport(request.transport)]
            )
        case .running(let resources):
            return stopRunning(resources, attempt: stopAttempt)
        case .suspending(let suspension):
            return stopRunning(suspension.resources, attempt: stopAttempt)
        case .suspended(let suspendedRuntime):
            return .changed(
                to: .stopping(stopAttempt),
                effects: [
                    .tearDownRuntimeServices,
                    .releaseResources(policy: .stop, idleTimerBaseline: suspendedRuntime.idleTimerBaseline),
                ]
            )
        case .resuming(let attempt):
            return .changed(
                to: .stopping(stopAttempt),
                effects: [
                    .cancelResume(attempt),
                    .tearDownRuntimeServices,
                    .releaseResources(
                        policy: .stop,
                        idleTimerBaseline: attempt.suspendedRuntime.idleTimerBaseline
                    ),
                ]
            )
        }
    }

    private func stopRunning(
        _ resources: TheInsideJob.InsideJobRuntimeResources,
        attempt stopAttempt: TheInsideJob.InsideJobStopAttempt
    ) -> Transition {
        .changed(
            to: .stopping(stopAttempt),
            effects: [
                .tearDownRuntimeServices,
                .stopTransport(resources.transport),
                .releaseResources(policy: .stop, idleTimerBaseline: resources.idleTimerBaseline),
            ]
        )
    }

    private func stopFinished(_ state: State, id: UUID) -> Transition {
        guard case .stopping(let attempt) = state, attempt.id == id else {
            return .rejected(.staleStopAttempt, stayingIn: state)
        }
        return .changed(to: .stopped)
    }

    private func suspendRequested(
        _ state: State,
        suspension: TheInsideJob.InsideJobSuspension?
    ) -> Transition {
        switch (state, suspension) {
        case (.running(let resources), .some(let suspension)):
            return .changed(
                to: .suspending(suspension),
                effects: [
                    .tearDownRuntimeServices,
                    .stopTransport(resources.transport),
                    .releaseResources(policy: .suspend, idleTimerBaseline: resources.idleTimerBaseline),
                ]
            )
        case (.resuming(let attempt), _):
            return .changed(to: state, effects: [.cancelResume(attempt)])
        case (.running, nil),
             (.stopped, _),
             (.starting, _),
             (.suspending, _),
             (.suspended, _),
             (.stopping, _):
            return .rejected(.notRunning, stayingIn: state)
        }
    }

    private func suspendFinished(_ state: State, id: UUID) -> Transition {
        guard case .suspending(let suspension) = state, suspension.id == id else {
            return .rejected(.staleSuspendAttempt, stayingIn: state)
        }
        return .changed(
            to: .suspended(
                TheInsideJob.InsideJobSuspendedRuntime(
                    idleTimerBaseline: suspension.resources.idleTimerBaseline
                )
            )
        )
    }

    private func resumeRequested(
        _ state: State,
        attempt: TheInsideJob.InsideJobResumeAttempt
    ) -> Transition {
        switch state {
        case .suspended:
            return .changed(to: .resuming(attempt))
        case .resuming:
            return .rejected(.alreadyActive, stayingIn: state)
        case .stopped, .starting, .running, .suspending, .stopping:
            return .rejected(.notSuspended, stayingIn: state)
        }
    }

    private func resumeTransportRequested(
        _ state: State,
        request: TheInsideJob.InsideJobTransportStartRequest
    ) -> Transition {
        guard case .resuming(let attempt) = state, attempt.id == request.id else {
            return .rejected(.staleResumeAttempt, stayingIn: state)
        }
        return .changed(to: state)
    }

    private func resumeSucceeded(
        _ state: State,
        id: UUID,
        resources: TheInsideJob.InsideJobRuntimeResources
    ) -> Transition {
        guard case .resuming(let attempt) = state, attempt.id == id else {
            return .rejected(.staleResumeAttempt, stayingIn: state)
        }
        return .changed(to: .running(resources), effects: [.activateRuntime])
    }

    private func resumeFailed(_ state: State, id: UUID) -> Transition {
        guard case .resuming(let attempt) = state, attempt.id == id else {
            return .rejected(.staleResumeAttempt, stayingIn: state)
        }
        return .changed(to: .suspended(attempt.suspendedRuntime))
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
