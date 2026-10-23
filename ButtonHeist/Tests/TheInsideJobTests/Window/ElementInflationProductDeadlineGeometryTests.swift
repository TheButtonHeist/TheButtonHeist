#if canImport(UIKit)
import XCTest
import ThePlans

@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

@MainActor
extension ElementInflationProductTests {

    // MARK: - Deadline and Geometry

    func testCommittedTargetRefreshPreservesSuppliedLeafDeadline() async throws {
        let heistId: HeistId = "committed_refresh_target"
        let element = makeElement(
            label: "Committed Refresh Target",
            identifier: heistId.rawValue
        )
        let refreshObservationSource = VisibleObservationSourceFixture(observation: nil)
        let tripwire = TheTripwire()
        let refreshBrains = TheBrains(
            tripwire: tripwire,
            visibleObservationSource: refreshObservationSource.capture,
            notificationIngress: .injected,
            pulseIngress: .injected
        )
        refreshBrains.vault.semanticObservationStream.start()
        let stream = refreshBrains.vault.semanticObservationStream
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                if stream.observationWaiterCount > 0 {
                    stream.deliver(TheTripwire.PulseReading(
                        frameDuration: .milliseconds(16),
                        tripwireSignal: .empty
                    ))
                }
                await Task.yield()
            }
        }
        defer {
            ticker.cancel()
            refreshBrains.vault.semanticObservationStream.stop()
        }
        let staleObject = UIButton(frame: CGRect(x: 20, y: 20, width: 160, height: 44))
        await refreshBrains.vault.installObservationForTesting(.makeForTests([
            .init(element, heistId: heistId, object: staleObject),
        ]))
        let treeElement = try XCTUnwrap(refreshBrains.vault.interfaceElement(heistId: heistId))
        let staleResolution = refreshBrains.vault.resolveLiveActionTarget(for: treeElement)
        guard case .resolved(let liveTarget) = staleResolution else {
            return XCTFail("Expected committed refresh fixture to have a live target, got \(staleResolution)")
        }
        let completedInflation = ElementInflation.InflatedElementTarget(
            target: try AccessibilityTarget.identifier(heistId.rawValue).resolve(in: .empty),
            treeElement: treeElement,
            liveTarget: liveTarget,
            deadline: SemanticObservationDeadline(start: RuntimeElapsed.now, timeoutSeconds: 0),
            resolution: ActionSubjectResolution(origin: .visible)
        )
        let replacementObject = UIButton(frame: CGRect(x: 20, y: 20, width: 160, height: 44))
        refreshObservationSource.observation = .makeForTests([
            .init(element, heistId: heistId, object: replacementObject),
        ])
        let deadline = SemanticObservationDeadline(
            start: RuntimeElapsed.now,
            timeoutSeconds: 7
        )

        let result = await refreshBrains.navigation.elementInflation.refreshCommittedTarget(
            completedInflation.committedTarget,
            method: .activate,
            activationPointPolicy: .requireOnscreen,
            deadline: deadline
        )

        guard case .inflated(let refreshedTarget) = result else {
            return XCTFail("Expected a refreshed target, got \(result)")
        }
        XCTAssertEqual(refreshedTarget.treeElement.heistId, heistId)
        XCTAssertTrue(refreshedTarget.liveTarget.object === replacementObject)
        XCTAssertFalse(refreshedTarget.liveTarget.object === staleObject)
        XCTAssertEqual(refreshedTarget.deadline, deadline)
    }

    func testMovingGeometryRequiresOneMatchingQuietSample() async {
        let initial = geometrySample(x: 20)
        let moved = geometrySample(x: 44)
        let stabilization = ElementInflation.LiveGeometryStabilization(
            initial: initial,
            requiresOnscreen: true
        )

        guard case .awaiting(let movedStabilization) = stabilization.reduce(
            .sample(moved, viewport: geometryViewport)
        ) else {
            return XCTFail("Moving geometry must restart the quiet window")
        }
        guard case .stable = movedStabilization.reduce(.sample(moved, viewport: geometryViewport)) else {
            return XCTFail("One unchanged sample must complete the quiet window")
        }
    }

    func testOffscreenActivationPointAfterPlacementIsTerminal() async {
        let sample = geometrySample(x: 20)
        let stabilization = ElementInflation.LiveGeometryStabilization(
            initial: sample,
            requiresOnscreen: true
        )

        guard case .offscreen = stabilization.reduce(.sample(sample, viewport: .zero)) else {
            return XCTFail("An offscreen activation point must fail after placement")
        }
    }

    func testGeometryStabilizationDeadlineIsTerminal() async {
        let stabilization = ElementInflation.LiveGeometryStabilization(
            initial: geometrySample(x: 20),
            requiresOnscreen: true
        )

        guard case .timedOut = stabilization.reduce(.deadlineExpired) else {
            return XCTFail("The operation deadline must terminate geometry stabilization")
        }
    }

    func testGeometryStabilizationCancellationIsTerminal() async {
        let stabilization = ElementInflation.LiveGeometryStabilization(
            initial: geometrySample(x: 20),
            requiresOnscreen: true
        )

        guard case .cancelled = stabilization.reduce(.cancelled) else {
            return XCTFail("Cancellation must terminate geometry stabilization")
        }
    }

    private func geometrySample(x: CGFloat) -> ElementInflation.LiveGeometrySample {
        ElementInflation.LiveGeometrySample(
            frame: CGRect(x: x, y: 40, width: 100, height: 44),
            activationPoint: CGPoint(x: x + 50, y: 62)
        )
    }

    private var geometryViewport: CGRect {
        CGRect(x: 0, y: 0, width: 320, height: 640)
    }
    func testMissingRevealPathIsBoundedByActionDeadline() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "live_decoy_unrevealable_submit",
            label: "Live Decoy"
        )
        try await seedOffViewportTarget(
            fixture,
            semanticIdentifier: "unrevealable_submit",
            semanticLabel: "Submit Order",
            scrollContainerPathOverride: TreePath([99]),
            refreshesFromUIKit: false
        )

        let result = await brains.executeRuntimeAction(
            .activate(
                .element(.identifier("unrevealable_submit"), traits: [.button])
            )
        )

        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(result.outcome.failureKind, .timeout)
        XCTAssertDiagnostic(result.message, contains: ["timed out"])
        XCTAssertFalse(result.message?.localizedCaseInsensitiveContains("scroll first") ?? false)
        XCTAssertFalse(result.message?.contains("get_interface") ?? false)
        XCTAssertEqual(fixture.target.activationCount, 0)
    }

}

#endif // canImport(UIKit)
