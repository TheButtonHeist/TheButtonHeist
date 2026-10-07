#if canImport(UIKit)
import XCTest

@testable import TheInsideJob

@MainActor
final class InsideJobLifecycleReducerTests: XCTestCase {
    private let reducer = InsideJobLifecycleReducer()

    func testLifecycleNotificationsProduceOnlySchedulingEffects() {
        let fixture = Fixture()
        let state = TheInsideJob.ServerPhase.running(fixture.resources)

        XCTAssertEqual(
            reducer.reduce(state, event: .lifecycleSuspensionNotification),
            .changed(to: state, effects: [.scheduleSuspend])
        )
        XCTAssertEqual(
            reducer.reduce(state, event: .terminationNotification),
            .changed(to: state, effects: [.scheduleStop])
        )
        XCTAssertEqual(
            reducer.reduce(
                .suspended(fixture.suspendedRuntime),
                event: .foregroundNotification(replacingExisting: false)
            ),
            .changed(
                to: .suspended(fixture.suspendedRuntime),
                effects: [.scheduleResume(afterCancelling: nil)]
            )
        )
        XCTAssertEqual(
            reducer.reduce(
                .resuming(fixture.resumeAttempt),
                event: .foregroundNotification(replacingExisting: true)
            ),
            .changed(
                to: .resuming(fixture.resumeAttempt),
                effects: [.scheduleResume(afterCancelling: fixture.resumeAttempt)]
            )
        )

        let noOpStates: [TheInsideJob.ServerPhase] = [
            .stopped,
            .starting(fixture.startRequest),
            .running(fixture.resources),
            .suspending(fixture.suspension),
            .resuming(fixture.resumeAttempt),
            .stopping(fixture.stopAttempt),
        ]
        for noOpState in noOpStates {
            XCTAssertEqual(
                reducer.reduce(
                    noOpState,
                    event: .foregroundNotification(replacingExisting: false)
                ),
                .changed(to: noOpState)
            )
        }
    }

    func testStartTransitionsAndRejections() {
        let fixture = Fixture()

        XCTAssertEqual(
            reducer.reduce(
                .stopped,
                event: .startRequested(fixture.startRequest)
            ),
            .changed(to: .starting(fixture.startRequest))
        )
        XCTAssertEqual(
            reducer.reduce(
                .starting(fixture.startRequest),
                event: .startSucceeded(fixture.id, fixture.resources)
            ),
            .changed(
                to: .running(fixture.resources),
                effects: [.activateRuntime]
            )
        )
        XCTAssertEqual(
            reducer.reduce(
                .starting(fixture.startRequest),
                event: .startFailed(fixture.id)
            ),
            .changed(to: .stopped, effects: [.cleanupTransport(fixture.transport)])
        )
        XCTAssertEqual(
            reducer.reduce(
                .running(fixture.resources),
                event: .startRequested(fixture.startRequest)
            ),
            .rejected(.alreadyActive, stayingIn: .running(fixture.resources))
        )
        XCTAssertEqual(
            reducer.reduce(
                .starting(fixture.startRequest),
                event: .startSucceeded(fixture.otherID, fixture.resources)
            ),
            .rejected(.staleStartAttempt, stayingIn: .starting(fixture.startRequest))
        )
        XCTAssertEqual(
            reducer.reduce(
                .starting(fixture.startRequest),
                event: .startFailed(fixture.otherID)
            ),
            .rejected(.staleStartAttempt, stayingIn: .starting(fixture.startRequest))
        )
    }

    func testStopTransitionsUseOneAttemptThroughResumeCancellation() {
        let fixture = Fixture()
        let stopping = TheInsideJob.ServerPhase.stopping(fixture.stopAttempt)

        XCTAssertEqual(
            reducer.reduce(
                .starting(fixture.startRequest),
                event: .stopRequested(fixture.stopAttempt)
            ),
            .changed(
                to: stopping,
                effects: [.tearDownRuntimeServices, .cleanupTransport(fixture.transport)]
            )
        )
        XCTAssertEqual(
            reducer.reduce(
                .running(fixture.resources),
                event: .stopRequested(fixture.stopAttempt)
            ),
            .changed(
                to: stopping,
                effects: [
                    .tearDownRuntimeServices,
                    .stopTransport(fixture.transport),
                    .releaseResources(policy: .stop, idleTimerBaseline: false),
                ]
            )
        )
        XCTAssertEqual(
            reducer.reduce(
                .suspending(fixture.suspension),
                event: .stopRequested(fixture.stopAttempt)
            ),
            .changed(
                to: stopping,
                effects: [
                    .tearDownRuntimeServices,
                    .stopTransport(fixture.transport),
                    .releaseResources(policy: .stop, idleTimerBaseline: false),
                ]
            )
        )
        XCTAssertEqual(
            reducer.reduce(
                .suspended(fixture.suspendedRuntime),
                event: .stopRequested(fixture.stopAttempt)
            ),
            .changed(
                to: stopping,
                effects: [
                    .tearDownRuntimeServices,
                    .releaseResources(policy: .stop, idleTimerBaseline: false),
                ]
            )
        )
        XCTAssertEqual(
            reducer.reduce(
                .resuming(fixture.resumeAttempt),
                event: .stopRequested(fixture.stopAttempt)
            ),
            .changed(
                to: stopping,
                effects: [
                    .cancelResume(fixture.resumeAttempt),
                    .tearDownRuntimeServices,
                    .releaseResources(policy: .stop, idleTimerBaseline: false),
                ]
            )
        )
        XCTAssertEqual(
            reducer.reduce(stopping, event: .stopFinished(fixture.stopAttempt.id)),
            .changed(to: .stopped)
        )
    }

    func testStopRejectionsKeepTheCurrentPhase() {
        let fixture = Fixture()
        let stopping = TheInsideJob.ServerPhase.stopping(fixture.stopAttempt)

        XCTAssertEqual(
            reducer.reduce(.stopped, event: .stopRequested(fixture.stopAttempt)),
            .rejected(.alreadyStopped, stayingIn: .stopped)
        )
        XCTAssertEqual(
            reducer.reduce(stopping, event: .stopRequested(fixture.stopAttempt)),
            .rejected(.alreadyStopping, stayingIn: stopping)
        )
        XCTAssertEqual(
            reducer.reduce(stopping, event: .stopFinished(fixture.otherID)),
            .rejected(.staleStopAttempt, stayingIn: stopping)
        )
        XCTAssertEqual(
            reducer.reduce(
                .running(fixture.resources),
                event: .stopFinished(fixture.stopAttempt.id)
            ),
            .rejected(.staleStopAttempt, stayingIn: .running(fixture.resources))
        )
    }

    func testSuspendTransitionsAndRejections() {
        let fixture = Fixture()

        XCTAssertEqual(
            reducer.reduce(
                .running(fixture.resources),
                event: .suspendRequested(fixture.suspension)
            ),
            .changed(
                to: .suspending(fixture.suspension),
                effects: [
                    .tearDownRuntimeServices,
                    .stopTransport(fixture.transport),
                    .releaseResources(policy: .suspend, idleTimerBaseline: false),
                ]
            )
        )
        XCTAssertEqual(
            reducer.reduce(
                .resuming(fixture.resumeAttempt),
                event: .suspendRequested(nil)
            ),
            .changed(
                to: .resuming(fixture.resumeAttempt),
                effects: [.cancelResume(fixture.resumeAttempt)]
            )
        )
        XCTAssertEqual(
            reducer.reduce(
                .suspending(fixture.suspension),
                event: .suspendFinished(fixture.suspension.id)
            ),
            .changed(to: .suspended(fixture.suspendedRuntime))
        )
        XCTAssertEqual(
            reducer.reduce(
                .running(fixture.resources),
                event: .suspendRequested(nil)
            ),
            .rejected(.notRunning, stayingIn: .running(fixture.resources))
        )
        XCTAssertEqual(
            reducer.reduce(.stopped, event: .suspendRequested(fixture.suspension)),
            .rejected(.notRunning, stayingIn: .stopped)
        )
        XCTAssertEqual(
            reducer.reduce(
                .suspending(fixture.suspension),
                event: .suspendFinished(fixture.otherID)
            ),
            .rejected(.staleSuspendAttempt, stayingIn: .suspending(fixture.suspension))
        )
    }

    func testResumeTransitionsAndRejections() {
        let fixture = Fixture()

        XCTAssertEqual(
            reducer.reduce(
                .suspended(fixture.suspendedRuntime),
                event: .resumeRequested(fixture.resumeAttempt)
            ),
            .changed(to: .resuming(fixture.resumeAttempt))
        )
        XCTAssertEqual(
            reducer.reduce(
                .resuming(fixture.resumeAttempt),
                event: .resumeTransportRequested(fixture.resumeRequest)
            ),
            .changed(to: .resuming(fixture.resumeAttempt))
        )
        XCTAssertEqual(
            reducer.reduce(
                .resuming(fixture.resumeAttempt),
                event: .resumeSucceeded(fixture.id, fixture.resources)
            ),
            .changed(
                to: .running(fixture.resources),
                effects: [.activateRuntime]
            )
        )
        XCTAssertEqual(
            reducer.reduce(
                .resuming(fixture.resumeAttempt),
                event: .resumeFailed(fixture.id)
            ),
            .changed(to: .suspended(fixture.suspendedRuntime))
        )
        XCTAssertEqual(
            reducer.reduce(
                .resuming(fixture.resumeAttempt),
                event: .resumeRequested(fixture.resumeAttempt)
            ),
            .rejected(.alreadyActive, stayingIn: .resuming(fixture.resumeAttempt))
        )
        XCTAssertEqual(
            reducer.reduce(.stopped, event: .resumeRequested(fixture.resumeAttempt)),
            .rejected(.notSuspended, stayingIn: .stopped)
        )

        let staleRequest = TheInsideJob.InsideJobTransportStartRequest(
            id: fixture.otherID,
            transport: fixture.transport,
            idleTimerBaseline: false
        )
        XCTAssertEqual(
            reducer.reduce(
                .resuming(fixture.resumeAttempt),
                event: .resumeTransportRequested(staleRequest)
            ),
            .rejected(.staleResumeAttempt, stayingIn: .resuming(fixture.resumeAttempt))
        )
        XCTAssertEqual(
            reducer.reduce(
                .resuming(fixture.resumeAttempt),
                event: .resumeSucceeded(fixture.otherID, fixture.resources)
            ),
            .rejected(.staleResumeAttempt, stayingIn: .resuming(fixture.resumeAttempt))
        )
        XCTAssertEqual(
            reducer.reduce(
                .resuming(fixture.resumeAttempt),
                event: .resumeFailed(fixture.otherID)
            ),
            .rejected(.staleResumeAttempt, stayingIn: .resuming(fixture.resumeAttempt))
        )
    }

    func testLifecycleObservationTransitionsOnlyOnce() {
        var state = TheInsideJob.LifecycleObservationState.uninstalled

        XCTAssertTrue(state.installIfNeeded())
        XCTAssertEqual(state, .installed)
        XCTAssertFalse(state.installIfNeeded())
        XCTAssertTrue(state.uninstallIfNeeded())
        XCTAssertEqual(state, .uninstalled)
        XCTAssertFalse(state.uninstallIfNeeded())
    }

}

private struct Fixture {
    let id: UUID
    let otherID: UUID
    let transport: ServerTransport
    let resources: TheInsideJob.InsideJobRuntimeResources
    let startRequest: TheInsideJob.InsideJobTransportStartRequest
    let suspension: TheInsideJob.InsideJobSuspension
    let suspendedRuntime: TheInsideJob.InsideJobSuspendedRuntime
    let resumeAttempt: TheInsideJob.InsideJobResumeAttempt
    let stopAttempt: TheInsideJob.InsideJobStopAttempt
    let resumeRequest: TheInsideJob.InsideJobTransportStartRequest

    @MainActor
    init() {
        let id = UUID()
        let transport = ServerTransport(token: "lifecycle-fixture-token")
        let resources = TheInsideJob.InsideJobRuntimeResources(
            transport: transport,
            actualPort: 2468,
            bonjourServiceName: "Fixture",
            idleTimerBaseline: false
        )
        let suspendedRuntime = TheInsideJob.InsideJobSuspendedRuntime(idleTimerBaseline: false)

        self.id = id
        self.otherID = UUID()
        self.transport = transport
        self.resources = resources
        self.startRequest = TheInsideJob.InsideJobTransportStartRequest(
            id: id,
            transport: transport,
            idleTimerBaseline: false
        )
        self.suspension = TheInsideJob.InsideJobSuspension(id: id, resources: resources)
        self.suspendedRuntime = suspendedRuntime
        self.resumeAttempt = TheInsideJob.InsideJobResumeAttempt(
            id: id,
            suspendedRuntime: suspendedRuntime,
            task: Task { @MainActor in }
        )
        self.stopAttempt = TheInsideJob.InsideJobStopAttempt(id: id)
        self.resumeRequest = TheInsideJob.InsideJobTransportStartRequest(
            id: id,
            transport: transport,
            idleTimerBaseline: false
        )
    }
}
#endif
