#if canImport(UIKit)
import XCTest
import ThePlans

@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

@MainActor
extension ElementInflationProductTests {

    // MARK: - Reveal and Nested Scrolling

    func testObservationInflationRestoresOriginAfterRevealingKnownElement() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "observation_inflation_target",
            label: "Observation Inflation Target"
        )
        try await seedOffViewportTarget(fixture)

        let outcome = await brains.navigation.elementInflation.inflateForObservation(
            for: try AccessibilityTarget.identifier(fixture.identifier).resolve(in: .empty),
            deadline: SemanticObservationDeadline(start: RuntimeElapsed.now, timeoutSeconds: 10)
        )

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)
        XCTAssertGreaterThan(fixture.scrollView.revealRequestCount, 0)
    }

    func testObservationInflationRejectsRemovedRememberedElementAndRestoresOriginOnce() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "removed_observation_target",
            label: "Removed Observation Target"
        )
        try await rememberTargetOutsideViewport(fixture)
        fixture.target.removeFromSuperview()
        let target = try AccessibilityTarget.label(fixture.label).resolve(in: .empty)
        guard case .resolved(.element) = brains.vault.resolveTarget(target) else {
            return XCTFail("The removed target must still be remembered before inflation")
        }
        let revealCount = fixture.scrollView.revealRequestCount
        let moveViewport = brains.navigation.elementInflation.exploration.moveViewport
        var restorationAttempts = 0
        brains.navigation.elementInflation.exploration.moveViewport = { intent, deadline in
            if case .restoreVisualOrigin = intent {
                restorationAttempts += 1
            }
            return await moveViewport(intent, deadline)
        }

        let outcome = await brains.navigation.elementInflation.inflateForObservation(
            for: target,
            deadline: SemanticObservationDeadline(start: RuntimeElapsed.now, timeoutSeconds: 10)
        )

        XCTAssertEqual(outcome, .restored)
        XCTAssertGreaterThan(fixture.scrollView.revealRequestCount, revealCount)
        XCTAssertEqual(restorationAttempts, 1)
        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)

        // Assertions refresh their evidence; retained discovery memory is not a fresh verdict.
        let plan = try HeistPlan(body: [
            .wait(WaitStep(predicate: .missing(.label(fixture.label)), timeout: 5)),
        ])
        let result = try await brains.executeHeistPlan(plan).get()
        let step = try XCTUnwrap(result.steps.first)
        let evidence = try XCTUnwrap(step.waitEvidence?.observation)
        let exists = try AccessibilityPredicate.exists(.label(fixture.label)).resolve(in: .empty)
        XCTAssertEqual(step.status, .passed)
        XCTAssertEqual(evidence.coverage, .complete)
        XCTAssertFalse(try exists.evaluate(in: evidence).met)
    }

    func testExistenceWaitRevealsRememberedElementBeforeSuccess() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "remembered_existence_target",
            label: "Remembered Existence Target"
        )
        try await rememberTargetOutsideViewport(fixture)
        let revealCount = fixture.scrollView.revealRequestCount
        let plan = try HeistPlan(body: [
            .wait(WaitStep(predicate: .exists(.label(fixture.label)), timeout: 5)),
        ])

        let result = try await brains.executeHeistPlan(plan).get()

        XCTAssertEqual(result.steps.first?.status, .passed)
        XCTAssertGreaterThan(fixture.scrollView.revealRequestCount, revealCount)
        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)
    }

    func testAbsenceWaitRechecksRemovedRememberedElement() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "remembered_absence_target",
            label: "Remembered Absence Target"
        )
        try await rememberTargetOutsideViewport(fixture)
        fixture.target.removeFromSuperview()
        let revealCount = fixture.scrollView.revealRequestCount
        let plan = try HeistPlan(body: [
            .wait(WaitStep(predicate: .missing(.label(fixture.label)), timeout: 5)),
        ])

        let result = try await brains.executeHeistPlan(plan).get()

        XCTAssertEqual(result.steps.first?.status, .passed)
        XCTAssertGreaterThan(fixture.scrollView.revealRequestCount, revealCount)
        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)
    }

    func testExistenceWaitSearchesAfterMissingRememberedLocation() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "relocated_existence_target",
            label: "Relocated Existence Target"
        )
        try await rememberTargetOutsideViewport(fixture)
        fixture.target.frame.origin.y = 1_200
        fixture.scrollView.revealThreshold = 1_100
        let target = try AccessibilityTarget.label(fixture.label).resolve(in: .empty)
        let vault = brains.vault
        let moveViewport = brains.navigation.elementInflation.exploration.moveViewport
        var missedRememberedLocation = false
        brains.navigation.elementInflation.exploration.moveViewport = { intent, deadline in
            let transition = await moveViewport(intent, deadline)
            if case .revealViewPoint = intent,
               case .notFound = vault.resolveVisibleTarget(target) {
                missedRememberedLocation = true
            }
            return transition
        }
        let plan = try HeistPlan(body: [
            .wait(WaitStep(predicate: .exists(.label(fixture.label)), timeout: 5)),
        ])

        let result = try await brains.executeHeistPlan(plan).get()

        XCTAssertTrue(missedRememberedLocation)
        XCTAssertEqual(result.steps.first?.status, .passed)
        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)
    }

    func testAbsenceWaitSearchesAfterMissingRememberedLocation() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "relocated_absence_target",
            label: "Relocated Absence Target"
        )
        try await rememberTargetOutsideViewport(fixture)
        fixture.target.frame.origin.y = 1_200
        fixture.scrollView.revealThreshold = 1_100
        let target = try AccessibilityTarget.label(fixture.label).resolve(in: .empty)
        guard case .resolved(.element) = brains.vault.resolveTarget(target) else {
            return XCTFail("The moved target must remain remembered before the wait")
        }
        let plan = try HeistPlan(body: [
            .wait(WaitStep(predicate: .missing(.label(fixture.label)), timeout: 5)),
        ])

        let result = try await brains.executeHeistPlan(plan).get()

        let step = try XCTUnwrap(result.steps.first)
        XCTAssertEqual(step.status, .failed)
        XCTAssertEqual(step.failure?.category, .timeout)
        guard case .resolved(.element(let found)) = brains.vault.resolveTarget(target),
              case .available(let geometry) = found.geometry.view else {
            return XCTFail("Search must find the moved target after missing its old location")
        }
        XCTAssertEqual(geometry.frame.cgRect.minY, 1_200)
        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)
    }

    func testExistenceWaitRejectsRemovedRememberedElement() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "removed_existence_target",
            label: "Removed Existence Target"
        )
        try await rememberTargetOutsideViewport(fixture)
        fixture.target.removeFromSuperview()
        let revealCount = fixture.scrollView.revealRequestCount
        let plan = try HeistPlan(body: [
            .wait(WaitStep(predicate: .exists(.label(fixture.label)), timeout: 2)),
        ])

        let result = try await brains.executeHeistPlan(plan).get()

        let step = try XCTUnwrap(result.steps.first)
        XCTAssertEqual(step.status, .failed)
        XCTAssertEqual(step.failure?.category, .timeout)
        let evidence = try XCTUnwrap(step.waitEvidence?.observation)
        let exists = try AccessibilityPredicate.exists(.label(fixture.label)).resolve(in: .empty)
        XCTAssertFalse(try exists.evaluate(in: evidence).met)
        XCTAssertGreaterThan(fixture.scrollView.revealRequestCount, revealCount)
        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)
    }

    func testObservationInflationReportsFailedOriginRestoration() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "observation_restore_failure",
            label: "Observation Restore Failure"
        )
        try await seedOffViewportTarget(fixture)
        let moveViewport = brains.navigation.elementInflation.exploration.moveViewport
        var restorationAttempts = 0
        brains.navigation.elementInflation.exploration.moveViewport = { intent, deadline in
            if case .restoreVisualOrigin = intent {
                restorationAttempts += 1
                return .unavailable()
            }
            return await moveViewport(intent, deadline)
        }

        let outcome = await brains.navigation.elementInflation.inflateForObservation(
            for: try AccessibilityTarget.identifier(fixture.identifier).resolve(in: .empty),
            deadline: SemanticObservationDeadline(start: RuntimeElapsed.now, timeoutSeconds: 10)
        )

        XCTAssertEqual(outcome, .failed(.originUnavailable))
        XCTAssertEqual(restorationAttempts, 1)
        XCTAssertGreaterThan(fixture.scrollView.revealRequestCount, 0)
    }

    func testCapturePreservesRemovedTargetOutsideReadViewport() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "unvisited_removed_target",
            label: "Unvisited Removed Target"
        )
        try await rememberTargetOutsideViewport(fixture)
        fixture.target.removeFromSuperview()
        let target = try AccessibilityTarget.label(fixture.label).resolve(in: .empty)
        guard case .resolved(.element) = brains.vault.resolveTarget(target) else {
            return XCTFail("The fixture must retain the unvisited target")
        }

        let capture = try XCTUnwrap(TheVault.captureVisibleObservation(from: brains.vault))

        XCTAssertTrue(brains.vault.confirmedMissingElements(in: capture).isEmpty)
    }

    func testCapturePreservesTargetWithInvalidatedStoredGeometry() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "invalidated_removed_target",
            label: "Invalidated Removed Target"
        )
        try await rememberTargetOutsideViewport(fixture)
        fixture.target.removeFromSuperview()
        let target = try AccessibilityTarget.label(fixture.label).resolve(in: .empty)
        guard case .resolved(.element(let remembered)) = brains.vault.resolveTarget(target) else {
            return XCTFail("The fixture must retain the target before geometry invalidation")
        }
        let observation = brains.vault.currentInterfaceObservation
        fixture.scrollView.setContentOffset(CGPoint(x: 0, y: 800), animated: false)
        let capture = try XCTUnwrap(TheVault.captureVisibleObservation(from: brains.vault))
        XCTAssertEqual(brains.vault.confirmedMissingElements(in: capture), [remembered.heistId])
        let invalidated = try observation.replacingTreeWithCurrentCapture(
            observation.tree.invalidatingParentSpaceGeometry()
        )
        await brains.vault.semanticObservationStream.commitDiscoveryObservationForTesting(invalidated)

        XCTAssertTrue(brains.vault.confirmedMissingElements(in: capture).isEmpty)
    }

    func testCancelledObservationInflationRestoresOrigin() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "cancelled_observation_inflation",
            label: "Cancelled Observation Inflation"
        )
        try await seedOffViewportTarget(fixture)
        let target = try AccessibilityTarget.identifier(fixture.identifier).resolve(in: .empty)
        var inflationTask: Task<Navigation.ViewportExit.Outcome, Never>?
        fixture.scrollView.onFirstRevealRequest = { inflationTask?.cancel() }
        let task = Task { @MainActor in
            await self.brains.navigation.elementInflation.inflateForObservation(
                for: target,
                deadline: SemanticObservationDeadline(start: RuntimeElapsed.now, timeoutSeconds: 10)
            )
        }
        inflationTask = task

        let outcome = await task.value

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)
        XCTAssertGreaterThan(fixture.scrollView.revealRequestCount, 0)
    }

    func testWaitFastPathStopsBeforeCachedTargetInflation() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "wait_fast_path_target",
            label: "Wait Fast Path"
        )
        try await seedOffViewportTarget(fixture)

        let outcome = await brains.navigation.exploreForWait(
            target: try AccessibilityTarget.identifier(fixture.identifier).resolve(in: .empty),
            deadline: SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 10
            ),
            stopWhen: { true }
        )

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)
        XCTAssertEqual(fixture.scrollView.revealRequestCount, 0)
    }

    func testWaitRestoresOriginEquallyAfterCachedAndExhaustiveDiscovery() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "wait_cached_exhaustive_target",
            label: "Wait Cached Exhaustive"
        )
        try await seedOffViewportTarget(fixture)
        let stopWhenRevealed: @MainActor @Sendable () -> Bool = {
            fixture.scrollView.contentOffset.y >= 500
        }

        let cachedOutcome = await brains.navigation.exploreForWait(
            target: try AccessibilityTarget.identifier(fixture.identifier).resolve(in: .empty),
            deadline: SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 10
            ),
            stopWhen: stopWhenRevealed
        )
        let revealCountAfterCachedPath = fixture.scrollView.revealRequestCount
        let cachedOffset = fixture.scrollView.contentOffset

        let exhaustiveOutcome = await brains.navigation.exploreForWait(
            target: nil,
            deadline: SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 10
            ),
            stopWhen: stopWhenRevealed
        )

        XCTAssertEqual(cachedOutcome, .restored)
        XCTAssertEqual(exhaustiveOutcome, cachedOutcome)
        XCTAssertEqual(cachedOffset, .zero)
        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)
        XCTAssertGreaterThan(revealCountAfterCachedPath, 0)
        XCTAssertGreaterThan(fixture.scrollView.revealRequestCount, revealCountAfterCachedPath)
    }

    func testCancelledWaitInflationRestoresOrigin() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "cancelled_wait_inflation_target",
            label: "Cancelled Wait Inflation"
        )
        try await seedOffViewportTarget(fixture)
        let target = try AccessibilityTarget.identifier(fixture.identifier).resolve(in: .empty)
        var waitTask: Task<Navigation.ViewportExit.Outcome, Never>?
        fixture.scrollView.onFirstRevealRequest = {
            waitTask?.cancel()
        }
        let task = Task { @MainActor in
            await self.brains.navigation.exploreForWait(
                target: target,
                deadline: SemanticObservationDeadline(
                    start: RuntimeElapsed.now,
                    timeoutSeconds: 10
                ),
                stopWhen: { false }
            )
        }
        waitTask = task

        let outcome = await task.value

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)
        XCTAssertGreaterThan(fixture.scrollView.revealRequestCount, 0)
    }

    func testRevealRollbackRestoresOriginalViewAfterSemanticContainerBecomesUnavailable() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "rollback_original_view",
            label: "Rollback Original View"
        )
        _ = try await publishedVisibleObservation()
        let transaction = ElementInflation.RevealTransaction(vault: brains.vault)
        transaction.captureScrollableHierarchy()
        fixture.scrollView.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
        await brains.vault.semanticObservationStream
            .commitVisibleObservationForTesting(.empty)
        var restoredOriginalView = false

        let outcome = await transaction.rollBack(
            using: { intent, _ in
                guard case .restoreVisualOrigin(
                    let origin,
                    .original(let scrollView)
                ) = intent else {
                    return .unavailable()
                }
                restoredOriginalView = scrollView === fixture.scrollView
                scrollView.setContentOffset(origin, animated: false)
                return Navigation.ViewportTransition(
                    outcome: .moved,
                    previousVisibleIds: [],
                    current: nil
                )
            },
            deadline: SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 10
            )
        )

        XCTAssertEqual(outcome, .restored)
        XCTAssertTrue(restoredOriginalView)
        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)
    }

    func testRevealRollbackIgnoresUnadmittedDescendantScrollView() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "rollback_ignores_unadmitted",
            label: "Rollback Ignores Unadmitted"
        )
        _ = try await publishedVisibleObservation()
        let unadmittedScrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        unadmittedScrollView.contentSize = CGSize(width: 100, height: 300)
        fixture.scrollView.addSubview(unadmittedScrollView)
        let transaction = ElementInflation.RevealTransaction(vault: brains.vault)
        transaction.captureScrollableHierarchy()
        unadmittedScrollView.contentOffset = CGPoint(x: 0, y: 100)
        var requestedRestore = false

        let outcome = await transaction.rollBack(
            using: { _, _ in
                requestedRestore = true
                return .unavailable()
            },
            deadline: SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 10
            )
        )

        XCTAssertEqual(outcome, .restored)
        XCTAssertFalse(requestedRestore)
    }

    func testSemanticActivateRevealsOffscreenScrollTargetWithoutManualPreScroll() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "semantic_checkout_submit",
            label: "Submit Order"
        )
        try await seedOffViewportTarget(fixture)

        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)

        let result = await brains.executeRuntimeAction(
            .activate(
                .element(.identifier("semantic_checkout_submit"), traits: [.button])
            )
        )

        XCTAssertTrue(result.outcome.isSuccess, result.message ?? "semantic activate failed")
        guard result.outcome.isSuccess else { return }
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(result.subjectEvidence?.source, .resolvedSemanticTarget)
        XCTAssertEqual(
            result.subjectEvidence?.element.semantics.assertable.identifier,
            fixture.knownHeistId.rawValue
        )
        XCTAssertEqual(
            result.subjectEvidence?.resolution,
            ActionSubjectResolution(origin: .known, adjustments: [.semanticReveal])
        )
        XCTAssertEqual(fixture.target.activationCount, 1)
        XCTAssertTrue(fixture.scrollView.didReceiveRevealRequest)
    }

    func testLiveCaptureUsesDirectScrollContainerAsMovementOwner() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "direct_scroll_owner",
            label: "Direct Scroll Owner"
        )

        let screen = try await publishedVisibleObservation()
        let paths = screen.liveCapture.dispatchReferences.scrollableContainerViewsByPath.compactMap { path, reference in
            reference.view === fixture.scrollView ? path : nil
        }

        XCTAssertEqual(paths.count, 1)
        let path = try XCTUnwrap(paths.first)
        XCTAssertTrue(screen.liveCapture.containerObject(forPath: path) === fixture.scrollView)
    }

    func testSemanticActivateRevealsNestedContainerTarget() async throws {
        let fixture = try installOffscreenActivationFixture(
            identifier: "nested_semantic_checkout_submit",
            label: "Confirm Payment",
            nestedInGroup: true
        )
        try await seedOffViewportTarget(fixture)

        let result = await brains.executeRuntimeAction(
            .activate(
                .element(.identifier("nested_semantic_checkout_submit"), traits: [.button])
            )
        )

        XCTAssertTrue(result.outcome.isSuccess, result.message ?? "nested semantic activate failed")
        guard result.outcome.isSuccess else { return }
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(fixture.target.activationCount, 1)
        XCTAssertTrue(fixture.scrollView.didReceiveRevealRequest)
    }

    func testSemanticTypeTextRevealsOffscreenTextTargetWithoutManualPreScroll() async throws {
        let fixture = try installOffscreenTextInputFixture(
            identifier: "semantic_delivery_note",
            label: "Delivery Note"
        )
        defer { fixture.cleanup() }

        let invalidation = TripwireInvalidationFixture(vault: brains.vault)
        let keyboardImpl = ProductTextInputKeyboardImpl(textField: fixture.target) {
            invalidation.signal()
        }
        keyboardInput = SafecrackerKeyboardInput(
            keyboardBridgeProvider: { keyboardImpl.bridge() }
        )
        try await restartRuntime()
        try await seedOffViewportTextInputTarget(fixture)

        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)
        XCTAssertFalse(fixture.target.isFirstResponder)

        let result = await brains.executeRuntimeAction(
            .typeText(
                text: "leave at desk",
                target: .identifier(fixture.identifier)
            )
        )
        await invalidation.wait()

        XCTAssertTrue(result.outcome.isSuccess, result.message ?? "semantic type_text failed")
        guard result.outcome.isSuccess else { return }
        XCTAssertEqual(result.method, .typeText)
        XCTAssertEqual(result.subjectEvidence?.source, .textInputTarget)
        XCTAssertEqual(
            result.subjectEvidence?.element.semantics.assertable.identifier,
            fixture.knownHeistId.rawValue
        )
        XCTAssertEqual(fixture.target.text, "leave at desk")
        XCTAssertTrue(fixture.target.isFirstResponder)
        XCTAssertTrue(fixture.scrollView.didReceiveRevealRequest)
        guard case .typeText(let value?) = result.payload else {
            return XCTFail("Expected final text value payload, got \(String(describing: result.payload))")
        }
        XCTAssertEqual(value, "leave at desk")
    }

    func testActivateVisibleTextFieldFallsBackToTapWithoutDiscoveryScroll() async throws {
        let fixture = try installVisibleTextInputFixture(
            identifier: "visible_activation_text_field",
            label: "Customer Name"
        )
        defer { fixture.cleanup() }
        let keyboardImpl = ProductTextInputKeyboardImpl(textField: fixture.target) {}
        keyboardInput = SafecrackerKeyboardInput(
            keyboardBridgeProvider: { keyboardImpl.bridge() }
        )
        try await restartRuntime()
        _ = try await publishedVisibleObservation()

        XCTAssertEqual(fixture.scrollView.contentOffset, .zero)
        XCTAssertFalse(fixture.target.isFirstResponder)

        let result = await brains.executeRuntimeAction(
            .activate(
                .element(.identifier(fixture.identifier), traits: [.textEntry])
            )
        )

        XCTAssertTrue(result.outcome.isSuccess, result.message ?? "visible text field activate failed")
        XCTAssertEqual(
            result.subjectEvidence?.element.semantics.assertable.identifier,
            fixture.knownHeistId.rawValue
        )
        XCTAssertEqual(
            result.subjectEvidence?.resolution,
            ActionSubjectResolution(origin: .visible)
        )
        XCTAssertTrue(fixture.target.isFirstResponder)
        XCTAssertEqual(fixture.touchReceiver.completedTouchCount, 1)
        XCTAssertEqual(fixture.scrollView.revealRequestCount, 0)
        XCTAssertEqual(result.activationTrace?.axActivateReturned, false)
        XCTAssertEqual(result.activationTrace?.tapActivationDispatched, true)
        XCTAssertEqual(result.activationTrace?.tapActivationSucceeded, true)
    }

    func testSemanticActivateRevealsTargetInsideNestedOffscreenScrollContainer() async throws {
        let fixture = try installNestedScrollActivationFixture(
            identifier: "nested_scroll_checkout_submit",
            label: "Confirm Nested Payment"
        )
        try await seedKnownNestedScrollTarget(fixture)
        var revealOrder: [ObjectIdentifier] = []
        fixture.outerScrollView.onFirstRevealRequest = {
            revealOrder.append(ObjectIdentifier(fixture.outerScrollView))
        }
        fixture.innerScrollView.onFirstRevealRequest = {
            revealOrder.append(ObjectIdentifier(fixture.innerScrollView))
        }

        XCTAssertEqual(fixture.outerScrollView.contentOffset, .zero)
        XCTAssertEqual(fixture.innerScrollView.contentOffset, .zero)

        let result = await brains.executeRuntimeAction(
            .activate(
                .element(.identifier("nested_scroll_checkout_submit"), traits: [.button])
            )
        )

        XCTAssertTrue(
            result.outcome.isSuccess,
            nestedScrollFailureDescription(result, fixture: fixture)
        )
        guard result.outcome.isSuccess else { return }
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(
            result.subjectEvidence?.element.semantics.assertable.identifier,
            fixture.knownHeistId.rawValue
        )
        XCTAssertEqual(fixture.target.activationCount, 1)
        XCTAssertEqual(revealOrder, [
            ObjectIdentifier(fixture.outerScrollView),
            ObjectIdentifier(fixture.innerScrollView),
        ])
        XCTAssertTrue(fixture.outerScrollView.didReceiveRevealRequest)
        XCTAssertTrue(fixture.innerScrollView.didReceiveRevealRequest)
    }

    func testSemanticActivateRevealsNestedScrollTargetWhenOtherWindowHasSameSizedScrollView() async throws {
        let fixture = try installNestedScrollActivationFixture(
            identifier: "nested_scroll_with_decoy_submit",
            label: "Confirm Decoy Payment"
        )
        let decoy = try installScrollDecoyWindow(contentSize: fixture.innerScrollView.contentSize)
        try await seedKnownNestedScrollTarget(fixture, decoy: .separate(decoy.scrollView))
        XCTAssertTrue(brains.vault.scrollableContainerViewsByPath.values.contains { $0 === decoy.scrollView })
        let decoyRevealCount = decoy.scrollView.revealRequestCount
        let decoyOffset = decoy.scrollView.contentOffset

        let result = await brains.executeRuntimeAction(
            .activate(
                .element(.identifier("nested_scroll_with_decoy_submit"), traits: [.button])
            )
        )

        XCTAssertTrue(
            result.outcome.isSuccess,
            nestedScrollFailureDescription(result, fixture: fixture)
        )
        guard result.outcome.isSuccess else { return }
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(fixture.target.activationCount, 1)
        XCTAssertTrue(fixture.outerScrollView.didReceiveRevealRequest)
        XCTAssertTrue(fixture.innerScrollView.didReceiveRevealRequest)
        XCTAssertEqual(decoy.scrollView.contentOffset, decoyOffset)
        XCTAssertEqual(decoy.scrollView.revealRequestCount, decoyRevealCount)
    }

    func testNestedRevealDoesNotTreatDuplicateOuterScrollViewPathAsInnerAlias() async throws {
        let fixture = try installNestedScrollActivationFixture(
            identifier: "nested_scroll_duplicate_outer_path_submit",
            label: "Confirm Duplicate Path Payment"
        )
        let decoy = try installScrollDecoyWindow(contentSize: fixture.innerScrollView.contentSize)
        try await seedKnownNestedScrollTarget(
            fixture,
            decoy: .duplicateOuterReferenceAtDecoyPath(decoy.scrollView)
        )
        XCTAssertGreaterThanOrEqual(
            brains.vault.scrollableContainerViewsByPath.values.filter { $0 === fixture.outerScrollView }.count,
            2
        )

        let result = await brains.executeRuntimeAction(
            .activate(
                .element(.identifier(fixture.identifier), traits: [.button])
            )
        )

        XCTAssertTrue(
            result.outcome.isSuccess,
            nestedScrollFailureDescription(result, fixture: fixture)
        )
        guard result.outcome.isSuccess else { return }
        XCTAssertEqual(
            result.subjectEvidence?.element.semantics.assertable.identifier,
            fixture.knownHeistId.rawValue
        )
        XCTAssertEqual(fixture.target.activationCount, 1)
        XCTAssertTrue(fixture.outerScrollView.didReceiveRevealRequest)
        XCTAssertTrue(fixture.innerScrollView.didReceiveRevealRequest)
        XCTAssertEqual(decoy.scrollView.contentOffset, .zero)
    }

    private func nestedScrollFailureDescription(
        _ result: ActionResult,
        fixture: NestedScrollRevealFixture
    ) -> String {
        [
            result.message ?? "nested scroll semantic activate failed",
            "outerOffset=\(fixture.outerScrollView.contentOffset)",
            "innerOffset=\(fixture.innerScrollView.contentOffset)",
            "outerReveals=\(fixture.outerScrollView.revealRequestCount)",
            "innerReveals=\(fixture.innerScrollView.revealRequestCount)",
            "targetHidden=\(fixture.target.isHidden)",
            "targetAccessible=\(fixture.target.isAccessibilityElement)",
            "liveIds=\(brains.vault.viewportElementIDs.map(\.rawValue).sorted())",
            "semanticPath=\(brains.vault.interfaceElement(heistId: fixture.knownHeistId)?.scrollContainerPath?.indices ?? [])",
            brains.vault.liveScrollContainerDiagnostics(),
        ].joined(separator: "; ")
    }
    private func installOffscreenTextInputFixture(
        identifier: String,
        label: String
    ) throws -> TextInputRevealFixture {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .white
        viewController.view.accessibilityViewIsModal = true

        let scrollView = RevealingScrollView(frame: CGRect(x: 24, y: 80, width: 320, height: 280))
        scrollView.contentSize = CGSize(width: 320, height: 1_400)
        scrollView.backgroundColor = .white
        scrollView.isAccessibilityElement = false

        let anchor = UILabel(frame: CGRect(x: 24, y: 24, width: 240, height: 44))
        anchor.text = "Visible Anchor \(identifier)"
        anchor.accessibilityLabel = anchor.text
        anchor.accessibilityIdentifier = "visible_anchor_\(identifier)"
        anchor.isAccessibilityElement = true
        scrollView.addSubview(anchor)

        let target = ActivatingTextField(frame: CGRect(x: 40, y: 900, width: 220, height: 44))
        target.borderStyle = .roundedRect
        target.accessibilityLabel = label
        target.accessibilityIdentifier = identifier
        target.accessibilityValue = ""
        target.isAccessibilityElement = true
        scrollView.addSubview(target)

        scrollView.revealedElements = [target]
        scrollView.updateAccessibilityVisibility()
        viewController.view.addSubview(scrollView)

        present(viewController, above: true)

        return TextInputRevealFixture(
            viewController: viewController,
            scrollView: scrollView,
            target: target,
            identifier: identifier,
            label: label,
            knownHeistId: HeistId(rawValue: identifier),
            frameOrigin: target.frame.origin
        )
    }

    private func installVisibleTextInputFixture(
        identifier: String,
        label: String
    ) throws -> VisibleTextInputFixture {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .white
        viewController.view.accessibilityViewIsModal = true

        let scrollView = RevealingScrollView(frame: CGRect(x: 24, y: 80, width: 320, height: 280))
        scrollView.contentSize = CGSize(width: 320, height: 1_400)
        scrollView.backgroundColor = .white
        scrollView.isAccessibilityElement = false

        let target = RefusingActivationTextField(frame: CGRect(x: 40, y: 24, width: 220, height: 44))
        target.borderStyle = .roundedRect
        target.accessibilityLabel = label
        target.accessibilityIdentifier = identifier
        target.accessibilityValue = ""
        target.accessibilityTraits = target.accessibilityTraits.union(.textEntry)
        target.isAccessibilityElement = true
        scrollView.addSubview(target)
        let touchReceiver = DeterministicTouchReceiver(frame: target.frame) {
            _ = target.becomeFirstResponder()
        }
        scrollView.addSubview(touchReceiver)

        viewController.view.addSubview(scrollView)

        present(viewController, above: true)

        return VisibleTextInputFixture(
            viewController: viewController,
            scrollView: scrollView,
            target: target,
            touchReceiver: touchReceiver,
            identifier: identifier,
            label: label,
            knownHeistId: HeistId(rawValue: identifier),
            frameOrigin: target.frame.origin
        )
    }

    private func installNestedScrollActivationFixture(
        identifier: String,
        label: String
    ) throws -> NestedScrollRevealFixture {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .white
        viewController.view.accessibilityViewIsModal = true

        let outerScrollView = RevealingScrollView(frame: CGRect(x: 24, y: 80, width: 320, height: 280))
        outerScrollView.contentSize = CGSize(width: 320, height: 1_400)
        outerScrollView.backgroundColor = .white
        outerScrollView.isAccessibilityElement = false

        let anchor = UILabel(frame: CGRect(x: 24, y: 24, width: 240, height: 44))
        anchor.text = "Visible Nested Anchor \(identifier)"
        anchor.accessibilityLabel = anchor.text
        anchor.accessibilityIdentifier = "visible_nested_anchor_\(identifier)"
        anchor.isAccessibilityElement = true
        outerScrollView.addSubview(anchor)

        let innerScrollView = RevealingScrollView(frame: CGRect(x: 20, y: 820, width: 280, height: 200))
        innerScrollView.contentSize = CGSize(width: 280, height: 900)
        innerScrollView.backgroundColor = .white
        innerScrollView.isAccessibilityElement = false

        let innerAnchor = UILabel(frame: CGRect(x: 20, y: 20, width: 220, height: 44))
        innerAnchor.text = "Visible Inner Anchor \(identifier)"
        innerAnchor.accessibilityLabel = innerAnchor.text
        innerAnchor.accessibilityIdentifier = "visible_inner_anchor_\(identifier)"
        innerAnchor.isAccessibilityElement = true
        innerScrollView.addSubview(innerAnchor)

        let target = SemanticActivationView(frame: CGRect(x: 20, y: 640, width: 220, height: 44))
        target.accessibilityLabel = label
        target.accessibilityIdentifier = identifier
        target.accessibilityTraits = .button
        innerScrollView.addSubview(target)
        innerScrollView.revealedElements = [target]
        innerScrollView.updateAccessibilityVisibility()

        outerScrollView.addSubview(innerScrollView)
        outerScrollView.revealedContainers = [innerScrollView]
        outerScrollView.updateAccessibilityVisibility()
        viewController.view.addSubview(outerScrollView)

        present(viewController, above: true)

        return NestedScrollRevealFixture(
            viewController: viewController,
            outerScrollView: outerScrollView,
            innerScrollView: innerScrollView,
            target: target,
            identifier: identifier,
            label: label,
            knownHeistId: HeistId(rawValue: identifier),
            innerFrameOrigin: innerScrollView.frame.origin,
            targetFrameOrigin: target.frame.origin
        )
    }

    private func installScrollDecoyWindow(contentSize: CGSize) throws -> ScrollDecoyFixture {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .clear

        let scrollView = RevealingScrollView(frame: CGRect(x: 12, y: 120, width: 280, height: 200))
        scrollView.contentSize = contentSize
        scrollView.backgroundColor = .clear
        scrollView.isAccessibilityElement = false
        let anchor = UILabel(frame: CGRect(x: 20, y: 20, width: 220, height: 44))
        anchor.text = "Separate Window Scroll Decoy"
        anchor.accessibilityLabel = anchor.text
        anchor.isAccessibilityElement = true
        scrollView.addSubview(anchor)
        viewController.view.addSubview(scrollView)

        present(viewController, above: true)
        return ScrollDecoyFixture(viewController: viewController, scrollView: scrollView)
    }

    private func seedOffViewportTextInputTarget(
        _ fixture: TextInputRevealFixture
    ) async throws {
        let screen = try await publishedVisibleObservation()
        let scrollContainerPath = try XCTUnwrap(
            firstLiveScrollableContainerPath(in: screen),
            "Expected fixture to expose a live scroll container. \(scrollContainerDiagnostics(in: screen))"
        )
        let element = makeElement(
            label: fixture.label,
            identifier: fixture.identifier,
            traits: UIAccessibilityTraits.fromNames(["textEntry"]),
            frame: CGRect(
                origin: fixture.frameOrigin,
                size: fixture.target.bounds.size
            )
        )
        let viewSpace = try viewSpace(
            origin: fixture.frameOrigin,
            size: fixture.target.bounds.size,
            ownerPath: scrollContainerPath
        )
        let entry = InterfaceTree.Element(
            heistId: fixture.knownHeistId,
            scrollMembership: InterfaceTree.ScrollMembership(containerPath: scrollContainerPath, index: nil),
            geometry: HeistElement.Geometry(screen: .offscreen, view: viewSpace),
            element: element
        )
        var elements = screen.tree.elements
        elements[entry.heistId] = entry

        let discoveryObservation = InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: elements,
                containers: screen.tree.containers,
                viewportCapture: screen.tree.viewportCapture
            ),
            liveCapture: screen.liveCapture
        )
        await brains.vault.semanticObservationStream.commitDiscoveryObservationForTesting(discoveryObservation)
        visibleObservationSource.useLiveCapture()
    }
    private func seedKnownNestedScrollTarget(
        _ fixture: NestedScrollRevealFixture,
        decoy: NestedScrollDecoy = .absent
    ) async throws {
        let screen = try await publishedVisibleObservation()
        let outerContainerPath = try XCTUnwrap(
            liveScrollableContainerPath(for: fixture.outerScrollView, in: screen),
            "Expected nested fixture to expose the live outer scroll view. \(scrollContainerDiagnostics(in: screen))"
        )
        let decoyContainerPath: TreePath?
        switch decoy {
        case .absent:
            decoyContainerPath = nil
        case .separate(let scrollView), .duplicateOuterReferenceAtDecoyPath(let scrollView):
            decoyContainerPath = try XCTUnwrap(
                liveScrollableContainerPath(for: scrollView, in: screen),
                "Expected separate-window decoy in the parser capture. \(scrollContainerDiagnostics(in: screen))"
            )
        }
        let innerContainerPath = nestedInnerScrollContainerPath(
            for: fixture.innerScrollView,
            below: outerContainerPath,
            in: screen
        )
        let capturedInnerContainer = screen.tree.containers[innerContainerPath]
        let innerContainer = capturedInnerContainer?.container ?? AccessibilityContainer(
            type: .none, scrollableContentSize: AccessibilitySize(fixture.innerScrollView.contentSize),
            frame: AccessibilityRect(fixture.innerScrollView.frame)
        )
        let innerContainerName: ContainerName
        if let capturedName = capturedInnerContainer?.containerName {
            innerContainerName = capturedName
        } else {
            innerContainerName = TheVault.containerName(for: innerContainer)
        }
        let element = makeElement(
            label: fixture.label,
            identifier: fixture.identifier,
            frame: CGRect(
                origin: fixture.targetFrameOrigin,
                size: fixture.target.bounds.size
            )
        )
        let targetViewSpace = try viewSpace(
            origin: fixture.targetFrameOrigin,
            size: fixture.target.bounds.size,
            ownerPath: innerContainerPath
        )
        let entry = InterfaceTree.Element(
            heistId: fixture.knownHeistId,
            scrollMembership: InterfaceTree.ScrollMembership(containerPath: innerContainerPath, index: nil),
            geometry: HeistElement.Geometry(screen: .offscreen, view: targetViewSpace),
            element: element
        )
        var elements = screen.tree.elements
        elements[entry.heistId] = entry

        var containers = screen.tree.containers
        let containerViewSpace = try capturedInnerContainer?.viewSpace
            ?? viewSpace(
            origin: fixture.innerFrameOrigin,
            size: fixture.innerScrollView.frame.size,
            ownerPath: outerContainerPath
        )
        containers[innerContainerPath] = InterfaceTree.Container(
            container: innerContainer,
            path: innerContainerPath,
            containerName: innerContainerName,
            viewSpace: containerViewSpace,
            scrollMembership: capturedInnerContainer?.scrollMembership
                ?? InterfaceTree.ScrollMembership(containerPath: outerContainerPath, index: nil),
            scrollInventory: capturedInnerContainer?.scrollInventory
        )

        let updatedTree = InterfaceTree(
            elements: elements,
            containers: containers,
            viewportCapture: screen.tree.viewportCapture
        )
        let liveCapture: LiveCapture
        switch decoy {
        case .absent, .separate:
            liveCapture = screen.liveCapture
        case .duplicateOuterReferenceAtDecoyPath:
            var scrollableViews = screen.liveCapture.dispatchReferences.scrollableContainerViewsByPath
            scrollableViews[try XCTUnwrap(decoyContainerPath)] = .init(view: fixture.outerScrollView)
            liveCapture = LiveCapture.makeForTests(
                tree: updatedTree,
                dispatchReferences: .init(
                    elementRefs: screen.liveCapture.dispatchReferences.elementRefs,
                    containerRefsByPath: screen.liveCapture.dispatchReferences.containerRefsByPath,
                    scrollableContainerViewsByPath: scrollableViews
                )
            )
        }

        await brains.vault.semanticObservationStream
            .commitDiscoveryObservationForTesting(InterfaceObservation.makeForTests(
                tree: updatedTree,
                liveCapture: liveCapture
            ))
        visibleObservationSource.useLiveCapture()
    }
    private func nestedInnerScrollContainerPath(
        for scrollView: UIScrollView,
        below outerContainerPath: TreePath,
        in observation: InterfaceObservation
    ) -> TreePath {
        if let path = liveScrollableContainerPath(for: scrollView, in: observation) {
            return path
        }

        // Hidden nested scroll views are absent before reveal; the parser assigns
        // the revealed inner scroll view as the first child container.
        return outerContainerPath.appending(0)
    }
}

private struct TextInputRevealFixture {
    let viewController: UIViewController
    let scrollView: RevealingScrollView
    let target: UITextField
    let identifier: String
    let label: String
    let knownHeistId: HeistId
    let frameOrigin: CGPoint

    /// Gives the keyboard back before the test ends.
    ///
    /// Focus is the app's, not the window's, so closing the window is not what
    /// releases it.
    @MainActor
    func cleanup() {
        _ = target.resignFirstResponder()
    }
}

private struct VisibleTextInputFixture {
    let viewController: UIViewController
    let scrollView: RevealingScrollView
    let target: RefusingActivationTextField
    let touchReceiver: DeterministicTouchReceiver
    let identifier: String
    let label: String
    let knownHeistId: HeistId
    let frameOrigin: CGPoint

    @MainActor
    func cleanup() {
        _ = target.resignFirstResponder()
    }
}

private struct NestedScrollRevealFixture {
    let viewController: UIViewController
    let outerScrollView: RevealingScrollView
    let innerScrollView: RevealingScrollView
    let target: SemanticActivationView
    let identifier: String
    let label: String
    let knownHeistId: HeistId
    let innerFrameOrigin: CGPoint
    let targetFrameOrigin: CGPoint
}

private enum NestedScrollDecoy {
    case absent
    case separate(RevealingScrollView)
    case duplicateOuterReferenceAtDecoyPath(RevealingScrollView)
}

private struct ScrollDecoyFixture {
    let viewController: UIViewController
    let scrollView: RevealingScrollView
}
private final class RefusingActivationTextField: DeterministicTextField {
    override func accessibilityActivate() -> Bool {
        false
    }
}

private final class ActivatingTextField: DeterministicTextField {
    override func accessibilityActivate() -> Bool {
        becomeFirstResponder()
    }
}

@MainActor
private final class ProductTextInputKeyboardImpl: NSObject {
    private final class TextInputDelegate: NSObject, UIKeyInput {
        var hasText: Bool { false }
        func insertText(_ text: String) {}
        func deleteBackward() {}
    }

    private let inputDelegate = TextInputDelegate()
    private weak var textField: UITextField?
    private let onInput: @MainActor () -> Void

    init(textField: UITextField, onInput: @escaping @MainActor () -> Void) {
        self.textField = textField
        self.onInput = onInput
    }

    @objc(delegate)
    func delegate() -> AnyObject? {
        guard textField?.isFirstResponder == true else { return nil }
        return inputDelegate
    }

    @objc(addInputString:withFlags:)
    func addInputString(_ text: NSString, flags: UInt) {
        guard textField?.isFirstResponder == true else { return }
        let nextValue = (textField?.text ?? "") + (text as String)
        textField?.text = nextValue
        textField?.accessibilityValue = nextValue
        onInput()
    }

    @objc(taskQueue)
    func taskQueue() -> AnyObject? {
        self
    }

    @objc(waitUntilAllTasksAreFinished)
    func waitUntilAllTasksAreFinished() {}

    func bridge() -> KeyboardBridge {
        KeyboardBridge(
            impl: self,
            textInjection: UIKeyboardImplTextInjection(impl: self)
        )
    }
}

#endif // canImport(UIKit)
