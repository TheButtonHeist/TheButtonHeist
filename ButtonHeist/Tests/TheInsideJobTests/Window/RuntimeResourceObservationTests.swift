#if canImport(UIKit)
import XCTest
import UIKit
import ThePlans

@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

@MainActor
final class RuntimeResourceObservationTests: XCTestCase {

    private var job: TheInsideJob!
    private var resources: TheInsideJob.InsideJobRuntimeResources!
    private var originalIdleTimerDisabled = false

    override func setUp() async throws {
        try await super.setUp()
        originalIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        job = try TheInsideJob(token: "runtime-resource-test-token")
        resources = TheInsideJob.InsideJobRuntimeResources(
            transport: ServerTransport(token: "runtime-resource-test-token"),
            actualPort: 0,
            bonjourServiceName: nil,
            idleTimerBaseline: UIApplication.shared.isIdleTimerDisabled
        )
    }

    override func tearDown() async throws {
        if let job {
            await job.stop()
        }
        job = nil
        resources = nil
        UIApplication.shared.isIdleTimerDisabled = originalIdleTimerDisabled
        try await super.tearDown()
    }

    func testRuntimeActivationIsIdempotent() async {
        let idleTimerBaseline = UIApplication.shared.isIdleTimerDisabled
        XCTAssertFalse(job.brains.semanticObservationIsActive)
        XCTAssertFalse(job.brains.vault.semanticObservationStream.isActive)
        XCTAssertFalse(job.tripwire.isPulseRunning)
        XCTAssertFalse(job.lifecycleObservationIsInstalled)

        await activateRuntime()

        XCTAssertTrue(job.brains.semanticObservationIsActive)
        XCTAssertTrue(job.brains.vault.semanticObservationStream.isActive)
        XCTAssertTrue(job.tripwire.isPulseRunning)
        XCTAssertTrue(job.lifecycleObservationIsInstalled)
        assertIdleTimerProtection(on: job, retainedBaseline: idleTimerBaseline)

        await job.performLifecycleEffect(.activateRuntime)

        XCTAssertTrue(job.brains.semanticObservationIsActive)
        XCTAssertTrue(job.brains.vault.semanticObservationStream.isActive)
        XCTAssertTrue(job.tripwire.isPulseRunning)
        XCTAssertTrue(job.lifecycleObservationIsInstalled)
        assertIdleTimerProtection(on: job, retainedBaseline: idleTimerBaseline)
    }

    func testSuspendStopsRuntimeOwnedObservationButPreservesLifecycleObservation() async {
        let idleTimerBaseline = UIApplication.shared.isIdleTimerDisabled
        await activateRuntime()
        XCTAssertTrue(job.brains.semanticObservationIsActive)
        XCTAssertTrue(job.brains.vault.semanticObservationStream.isActive)
        XCTAssertTrue(job.tripwire.isPulseRunning)
        XCTAssertTrue(job.lifecycleObservationIsInstalled)

        await job.suspend()

        XCTAssertFalse(job.brains.semanticObservationIsActive)
        XCTAssertFalse(job.brains.vault.semanticObservationStream.isActive)
        XCTAssertFalse(job.tripwire.isPulseRunning)
        XCTAssertTrue(job.lifecycleObservationIsInstalled)
        assertIdleTimerProtection(on: job, retainedBaseline: idleTimerBaseline)
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, idleTimerBaseline)
    }

    func testRuntimeReactivationRestartsThePulse() async {
        await activateRuntime()
        XCTAssertTrue(job.tripwire.isPulseRunning)

        job.releaseRuntimeOwnedResources(
            policy: .suspend,
            idleTimerBaseline: resources.idleTimerBaseline
        )
        XCTAssertFalse(job.tripwire.isPulseRunning)

        job.activateRuntime()
        XCTAssertTrue(job.tripwire.isPulseRunning)
    }

    func testStopClearsLifecycleObservationAndIdleTimerBaseline() async {
        let idleTimerBaseline = UIApplication.shared.isIdleTimerDisabled
        await activateRuntime()
        XCTAssertTrue(job.lifecycleObservationIsInstalled)
        assertIdleTimerProtection(on: job, retainedBaseline: idleTimerBaseline)

        await job.stop()

        XCTAssertFalse(job.brains.semanticObservationIsActive)
        XCTAssertFalse(job.brains.vault.semanticObservationStream.isActive)
        XCTAssertFalse(job.tripwire.isPulseRunning)
        XCTAssertFalse(job.lifecycleObservationIsInstalled)
        assertIdleTimerProtectionIsCleared(on: job)
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, idleTimerBaseline)
    }

    func testInactiveCommandFailsWithoutStartingObservation() async {
        let result = await job.brains.executeRuntimeAction(.activate(.label("Save")))

        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(result.outcome.failureKind, .actionFailed)
        XCTAssertEqual(result.message, TheBrains.runtimeInactiveMessage)
        XCTAssertFalse(job.brains.semanticObservationIsActive)
        XCTAssertFalse(job.brains.vault.semanticObservationStream.isActive)
    }

    private func activateRuntime() async {
        let request = TheInsideJob.InsideJobTransportStartRequest(
            id: UUID(),
            transport: resources.transport,
            idleTimerBaseline: resources.idleTimerBaseline
        )
        _ = job.applyLifecycleEvent(.startRequested(request))
        let change = job.applyLifecycleEvent(.startSucceeded(request.id, resources))
        await job.performLifecycleEffects(change.effects)
    }
}

@MainActor
private func assertIdleTimerProtection(
    on job: TheInsideJob,
    retainedBaseline expectedBaseline: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(job.retainedIdleTimerBaseline, expectedBaseline, file: file, line: line)
    XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, file: file, line: line)
}

@MainActor
private func assertIdleTimerProtectionIsCleared(
    on job: TheInsideJob,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertNil(job.retainedIdleTimerBaseline, file: file, line: line)
}

#endif // canImport(UIKit)
