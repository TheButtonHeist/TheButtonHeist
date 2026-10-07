#if canImport(UIKit)
import XCTest

@testable import BHDemo
import ButtonHeistHostedTestSupport
import ButtonHeistTesting
@testable import TheInsideJob
@_spi(AdversarialLab) import ThePlans
@_spi(ButtonHeistInternals) @testable import TheScore

@MainActor
final class AdversarialNavigationTests: XCTestCase {

    func testStartupEnvironmentAdmitsOnlyCanonicalAdversarialRoutes() {
        let route = AdversarialRoute.parseStartupEnvironment([
            AdversarialRoute.startupEnvironmentKey: AdversarialScenarioCatalog.Route.nestedScroll.rawValue,
        ])

        XCTAssertEqual(route?.scenario, .nestedScroll)
        XCTAssertNil(AdversarialRoute.parseStartupEnvironment([
            AdversarialRoute.startupEnvironmentKey: "/unknown",
        ]))
        XCTAssertNil(AdversarialRoute.parseStartupEnvironment([:]))
    }

    func testModalReviewBecomesInteractiveOnlyAfterPresentationCompletes() async throws {
        let heist = try await runAdversarialScenario(
            .modalObstructionPass,
            opening: AdversarialLabRoute.open
        )
        XCTAssertNil(heist.result.firstFailedStep)
    }

    func testModalObstructionBlocksBackgroundActionSearch() async throws {
        let failure = try await runFailingAdversarialScenario(
            .modalObstructionBackgroundFails,
            opening: AdversarialLabRoute.open
        )
        let failedStep = try XCTUnwrap(failure.result.firstFailedStep)
        let actionResult = try XCTUnwrap(failedStep.actionEvidence?.result)
        XCTAssertEqual(failure.failedStepKind, .action)
        XCTAssertEqual(failedStep.failure?.category, .targetResolution)
        XCTAssertEqual(actionResult.outcome, .failure(.elementNotFound))
        XCTAssertNil(actionResult.subjectEvidence)

        let cleanup = try await runHeist("AdversarialModalObstructionCleanup") {
            If {
                Case(.exists(.label("Close"))) {
                    Activate(.label("Close"))
                        .expect(.missing(.label("Order review")), timeout: 4)
                }
                Case(.exists(.label("Modal Obstruction"))) {
                    WaitFor(.exists(.label("Modal Obstruction")), timeout: 1)
                }
                Else {
                    WaitFor(.exists(.label("ButtonHeist Demo")), timeout: 1)
                }
            }

            WaitFor(.exists(.element(.label("Archived orders"), .value("0"))), timeout: 2)
            WaitFor(.exists(.element(.label("Background archive actions"), .value("0"))), timeout: 2)
            WaitFor(.exists(.element(.label("Background scroll attempts"), .value("0"))), timeout: 2)
            WaitFor(.exists(.element(.label("Background scroll movements"), .value("0"))), timeout: 2)
        }
        XCTAssertNil(cleanup.result.firstFailedStep)
    }

    func testNestedScrollFindsDeepTargetAcrossBothAxes() async throws {
        let heist = try await runAdversarialScenario(
            .nestedScrollPass,
            opening: AdversarialLabRoute.open
        )
        XCTAssertNil(heist.result.firstFailedStep)
        let actionResult = try XCTUnwrap(
            heist.result.outputNodes.lazy
                .compactMap { $0.actionEvidence?.result }
                .first {
                    $0.subjectEvidence?.element.semantics.assertable.label
                        == "Verified by The Vibe Check"
                }
        )
        let subject = try XCTUnwrap(actionResult.subjectEvidence)
        XCTAssertEqual(subject.source, .resolvedSemanticTarget)
        XCTAssertEqual(
            subject.element.semantics.assertable.label,
            "Verified by The Vibe Check"
        )
        XCTAssertEqual(subject.resolution.origin, .discovered)
        XCTAssertTrue(subject.resolution.adjustments.contains(.semanticReveal))
        let activationTrace = try XCTUnwrap(actionResult.activationTrace)
        XCTAssertTrue(
            activationTrace.axActivateReturned == true
                || activationTrace.tapActivationSucceeded == true
        )
        let failure = try await runFailingAdversarialScenario(
            .nestedScrollImpossibleFails,
            opening: AdversarialLabRoute.open
        )
        XCTAssertEqual(failure.failedStepKind, .action)
    }

    func testNestedScrollCancellationRestoresBothOriginalOffsetsBeforeReturningResult() async throws {
        try await AdversarialLabRoute.open(.nestedScroll)

        let job = TheInsideJob.shared
        let brains = job.brains
        let ownsObservationRuntime = !brains.semanticObservationIsActive
        if ownsObservationRuntime {
            job.tripwire.startPulse()
            brains.vault.semanticObservationStream.start()
        }
        defer {
            if ownsObservationRuntime {
                brains.vault.semanticObservationStream.stop()
                job.tripwire.stopPulse()
            }
        }
        await brains.vault.resetInterfaceForLifecycle()

        let evidence = NestedScrollScenarioInstrumentation.prepare()
        let movementBoundary = Task { @MainActor in
            var iterator = evidence.makeAsyncIterator()
            return await iterator.next()
        }
        let discovery = Task { @MainActor in
            await brains.navigation.fullGraph()
        }

        let movementOutcome = await withTaskGroup(of: NestedScrollDiscoveryRace.self) { group in
            group.addTask { .movement(await movementBoundary.value) }
            group.addTask {
                _ = await discovery.value
                return .discoveryCompleted
            }
            let outcome = await group.next() ?? .discoveryCompleted
            switch outcome {
            case .movement:
                discovery.cancel()
            case .discoveryCompleted:
                movementBoundary.cancel()
            }
            group.cancelAll()
            return outcome
        }
        guard case .movement(let moved?) = movementOutcome else {
            _ = await discovery.value
            NestedScrollScenarioInstrumentation.finish()
            return XCTFail("Nested discovery ended before both live scroll containers moved")
        }
        XCTAssertGreaterThan(moved.outerMovementCount, 0)
        XCTAssertGreaterThan(moved.innerMovementCount, 0)
        XCTAssertEqual(moved.activationCount, 0)

        let restorationBoundary = Task { @MainActor in
            var iterator = evidence.makeAsyncIterator()
            return await iterator.next()
        }
        let completedDiscovery = await discovery.value
        NestedScrollScenarioInstrumentation.finish()
        guard let restored = await restorationBoundary.value else {
            return XCTFail("Nested-scroll fixture ended before reporting cancellation restoration")
        }
        XCTAssertEqual(restored.outerOffset, "0.00, 0.00")
        XCTAssertEqual(restored.innerOffset, "0.00, 0.00")
        XCTAssertEqual(restored.outerRestorationCount, 1)
        XCTAssertEqual(restored.innerRestorationCount, 1)
        XCTAssertEqual(restored.activationCount, 0)

        let result = try XCTUnwrap(completedDiscovery)
        XCTAssertEqual(result.viewportExit, .restored)
        let terminalInterface = result.current.snapshot.interface
        XCTAssertTrue(terminalInterface.containsElement(
            label: "Nested restoration state",
            value: "Restored"
        ))
        XCTAssertTrue(terminalInterface.containsElement(
            label: "Nested outer restorations",
            value: "1"
        ))
        XCTAssertTrue(terminalInterface.containsElement(
            label: "Nested inner restorations",
            value: "1"
        ))
        XCTAssertTrue(terminalInterface.containsElement(
            label: "Nested target activations",
            value: "0"
        ))
    }

    func testNestedScrollReplacementSupersedesRestorationWithoutMovingReplacementViewport() async throws {
        try await AdversarialLabRoute.open(.nestedScroll)
        _ = try await runHeist("AdversarialNestedScroll.armReplacement") {
            Activate(.label("Replace nested screen after scroll"))
                .expect(.exists(.element(
                    .label("Nested replacement mode"),
                    .value("Armed")
                )), timeout: 2)
        }

        let job = TheInsideJob.shared
        let brains = job.brains
        let ownsObservationRuntime = !brains.semanticObservationIsActive
        if ownsObservationRuntime {
            job.tripwire.startPulse()
            brains.vault.semanticObservationStream.start()
        }
        defer {
            if ownsObservationRuntime {
                brains.vault.semanticObservationStream.stop()
                job.tripwire.stopPulse()
            }
        }
        await brains.vault.resetInterfaceForLifecycle()

        let evidence = NestedScrollScenarioInstrumentation.prepare()
        let completedExploration = await brains.navigation.fullGraph()
        let exploration = try XCTUnwrap(completedExploration)
        XCTAssertEqual(exploration.viewportExit, .superseded)
        var iterator = evidence.makeAsyncIterator()
        guard let moved = await iterator.next() else {
            return XCTFail("Expected replacement only after both original live scroll containers moved")
        }
        XCTAssertGreaterThan(moved.outerMovementCount, 0)
        XCTAssertGreaterThan(moved.innerMovementCount, 0)
        XCTAssertEqual(moved.activationCount, 0)

        let terminalInterface = exploration.current.snapshot.interface
        XCTAssertTrue(terminalInterface.containsElement(label: "Nested replacement screen"))
        XCTAssertTrue(terminalInterface.containsElement(
            label: "Original outer restorations",
            value: String(moved.outerRestorationCount)
        ))
        XCTAssertTrue(terminalInterface.containsElement(
            label: "Original inner restorations",
            value: String(moved.innerRestorationCount)
        ))
        XCTAssertTrue(terminalInterface.containsElement(
            label: "Nested target activations",
            value: "0"
        ))
        XCTAssertTrue(terminalInterface.containsElement(
            label: "Replacement scroll movements",
            value: "0"
        ))
    }

    func testDuplicateLabelIdentitySurvivesBothViewportDirectionsAndCandidateReordering() async throws {
        let heist = try await runAdversarialScenario(
            .duplicateLabelIdentityPass,
            opening: AdversarialLabRoute.open
        )
        XCTAssertNil(heist.result.firstFailedStep)
    }

}

private enum NestedScrollDiscoveryRace: Sendable {
    case movement(NestedScrollScenarioEvidence?)
    case discoveryCompleted
}
#endif // canImport(UIKit)
