#if canImport(UIKit)
import ButtonHeistSupport
import ButtonHeistTestSupport
import XCTest
@testable import AccessibilitySnapshotParser
@_spi(ButtonHeistInternals) @testable import ThePlans
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

@MainActor
extension TheBrainsActionTests {

    func testDispatchRejectsCancelledActionBeforeActivationSideEffect() async throws {
        let liveObject = ActionActivationOverrideView()
        await registerScreenElement(
            heistId: "cancelled_dispatch_target",
            element: makeElement(label: "Cancelled Dispatch", traits: .button),
            object: liveObject
        )
        let command = try HeistActionCommand
            .activate(.label("Cancelled Dispatch"))
            .resolve(in: .empty)
        let task = Task { @MainActor in
            await brains.dispatchRuntimeAction(
                command,
                deadline: actionDeadline()
            )
        }

        task.cancel()
        let result = await task.value

        XCTAssertFalse(result.success)
        XCTAssertEqual(
            try XCTUnwrap(result.failureKind),
            ActionFailure.Kind.actionFailed
        )
        XCTAssertEqual(liveObject.activationCount, 0)
    }

    func testDispatchRejectsExpiredActionBeforeActivationSideEffect() async throws {
        let liveObject = ActionActivationOverrideView()
        await registerScreenElement(
            heistId: "expired_dispatch_target",
            element: makeElement(label: "Expired Dispatch", traits: .button),
            object: liveObject
        )
        let command = try HeistActionCommand
            .activate(.label("Expired Dispatch"))
            .resolve(in: .empty)

        let result = await brains.dispatchRuntimeAction(
            command,
            deadline: SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 0
            )
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(
            try XCTUnwrap(result.failureKind),
            ActionFailure.Kind.timeout
        )
        XCTAssertEqual(liveObject.activationCount, 0)
    }

    func testObservationStreamDoesNotReuseInvalidatedSettledObservation() async {
        await installScreen(elements: [(makeElement(label: "Title", traits: .header), "header_title")])
        brains.vault.semanticObservationStream.invalidateCurrentAdmission()
        visibleObservationSource.observation = nil

        let current = await withNoTraversableWindows {
            await brains.vault.semanticObservationStream
                .admittedVisibleObservation(
                    boundary: .externalDeadline(SemanticObservationDeadline(
                        start: RuntimeElapsed.now,
                        timeoutSeconds: 0.001
                    ))
                )
        }

        XCTAssertNil(
            current,
            "invalidated settled observation must not be returned when no live tree is readable"
        )
    }

    func testExecuteIncrementFailsWhenElementIsNotAdjustable() async throws {
        let heistId: HeistId = "live_button"
        let liveObject = UIButton(type: .system)
        await registerScreenElement(
            heistId: heistId,
            element: makeElement(label: "Live", traits: .button),
            object: liveObject
        )

        let target = try AccessibilityTarget.label("Live").resolve(in: .empty)
        var timing = ActionTiming()
        let result = await brains.actions.executeIncrement(
            target,
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .increment)
        XCTAssertDiagnostic(result.message, contains: [
            "adjustable action failed",
            "label=\"Live\"",
            "traits=[button]",
            "actions=[activate]",
            "try target an element with trait adjustable",
        ])
    }

    func testExecuteDecrementFailsWhenElementIsNotAdjustable() async throws {
        let heistId: HeistId = "live_button"
        let liveObject = UIButton(type: .system)
        await registerScreenElement(
            heistId: heistId,
            element: makeElement(label: "Live", traits: .button),
            object: liveObject
        )

        let target = try AccessibilityTarget.label("Live").resolve(in: .empty)
        var timing = ActionTiming()
        let result = await brains.actions.executeDecrement(
            target,
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .decrement)
        XCTAssertDiagnostic(result.message, contains: [
            "adjustable action failed",
            "label=\"Live\"",
            "traits=[button]",
            "actions=[activate]",
            "try target an element with trait adjustable",
        ])
    }

    func testExecuteCustomActionMissingReportsAvailableCustomActions() async throws {
        let heistId: HeistId = "options_button"
        let liveObject = ActionActivationOverrideView()
        await registerScreenElement(
            heistId: heistId,
            element: makeElement(
                label: "Options",
                traits: .button,
                customActions: ["Delete", "Archive"]
            ),
            object: liveObject
        )

        var timing = ActionTiming()

        let result = await brains.actions.executeCustomAction(
            name: "Share",
            target: try AccessibilityTarget.label("Options").resolve(in: .empty),
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .customAction)
        XCTAssertDiagnostic(result.message, contains: [
            "custom action failed",
            "requestedAction=\"Share\"",
            "label=\"Options\"",
            "actions=[activate, Archive, Delete]",
            "try use one of custom actions [\"Archive\", \"Delete\"]",
        ])
    }

    func testExecuteCustomActionDeclinedReportsAlternatives() async throws {
        let heistId: HeistId = "options_button"
        let liveObject = ActionActivationOverrideView()
        liveObject.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Delete") { _ in false },
            UIAccessibilityCustomAction(name: "Archive") { _ in true },
        ]
        await registerScreenElement(
            heistId: heistId,
            element: makeElement(
                label: "Options",
                traits: .button,
                customActions: ["Delete", "Archive"]
            ),
            object: liveObject
        )

        var timing = ActionTiming()

        let result = await brains.actions.executeCustomAction(
            name: "Delete",
            target: try AccessibilityTarget.label("Options").resolve(in: .empty),
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .customAction)
        XCTAssertDiagnostic(result.message, contains: [
            "custom action failed",
            "requestedAction=\"Delete\" declined by handler",
            "label=\"Options\"",
            "actions=[activate, Archive, Delete]",
            "try use another custom action [\"Archive\"]",
        ])
    }

    func testExecuteCustomActionDispatchesLiveCustomAction() async throws {
        let heistId: HeistId = "live_custom_action_host"
        let liveObject = UIView()
        let customActionTarget = CustomActionTargetObject()
        liveObject.accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: "Archive",
                target: customActionTarget,
                selector: #selector(CustomActionTargetObject.archive(_:))
            ),
        ]
        await registerScreenElement(
            heistId: heistId,
            element: makeElement(label: "Options", traits: .button),
            object: liveObject
        )

        var timing = ActionTiming()

        let result = await brains.actions.executeCustomAction(
            name: "Archive",
            target: try AccessibilityTarget.label("Options").resolve(in: .empty),
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.method, .customAction)
        XCTAssertEqual(customActionTarget.invocationCount, 1)
    }

    func testExecuteCustomActionSelectorDeclineReportsFailure() async throws {
        let heistId: HeistId = "declining_custom_action_host"
        let liveObject = UIView()
        let customActionTarget = CustomActionTargetObject()
        liveObject.accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: "Archive",
                target: customActionTarget,
                selector: #selector(CustomActionTargetObject.decline(_:))
            ),
        ]
        await registerScreenElement(
            heistId: heistId,
            element: makeElement(label: "Options", traits: .button, customActions: ["Archive"]),
            object: liveObject
        )

        var timing = ActionTiming()

        let result = await brains.actions.executeCustomAction(
            name: "Archive",
            target: try AccessibilityTarget.label("Options").resolve(in: .empty),
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .customAction)
        XCTAssertEqual(customActionTarget.invocationCount, 1)
        XCTAssertDiagnostic(result.message, contains: [
            "custom action failed",
            "requestedAction=\"Archive\" declined by handler",
            "label=\"Options\"",
        ])
    }

    func testExecuteActivateSucceedsForNoTraitElementWithActivationOverride() async throws {
        let rootView = UIView(frame: UIScreen.main.bounds)
        rootView.backgroundColor = .white
        let liveObject = ActionActivationOverrideView(
            frame: CGRect(x: 80, y: 180, width: 180, height: 44)
        )
        liveObject.isAccessibilityElement = true
        liveObject.accessibilityLabel = "Plain action"
        liveObject.accessibilityIdentifier = "plain_action"
        liveObject.accessibilityTraits = .none
        rootView.addSubview(liveObject)

        let window = try installModalWindow(rootView: rootView)
        defer {
            window.rootViewController?.view.accessibilityViewIsModal = false
            window.isHidden = true
        }
        let heistId: HeistId = "plain_action"
        await installSyntheticObservation(.makeForTests(
            elements: [(
                AccessibilityElement.make(
                    label: "Plain action",
                    identifier: heistId.rawValue,
                    shape: .frame(AccessibilityRect(liveObject.frame))
                ),
                heistId
            )],
            objects: [heistId: liveObject]
        ))

        let target = try AccessibilityTarget.identifier("plain_action").resolve(in: .empty)
        var timing = ActionTiming()
        let result = await brains.actions.executeActivate(
            target,
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(liveObject.activationCount, 1)
    }

    func testExecuteActivateUsesSemanticActionBeforeRequiringUsableTapGeometry() async throws {
        let liveObject = ActionActivationOverrideView()
        let target = try await installActivationTargetWithUnusableTapGeometry(
            heistId: "semantic_before_geometry",
            label: "Semantic Before Geometry",
            object: liveObject
        )
        var timing = ActionTiming()

        let result = await brains.actions.executeActivate(
            target,
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertTrue(result.success, result.message ?? "activate failed")
        XCTAssertEqual(liveObject.activationCount, 1)
        XCTAssertEqual(
            result.activationTrace,
            ActivationTrace(.accessibilityActivate(axActivateReturned: true))
        )
    }

    func testExecuteActivateExplainsGeometryFailureAfterSemanticRefusal() async throws {
        let liveObject = RefusingActivationView()
        let target = try await installActivationTargetWithUnusableTapGeometry(
            heistId: "refusal_before_geometry",
            label: "Refusal Before Geometry",
            object: liveObject
        )
        var timing = ActionTiming()

        let result = await brains.actions.executeActivate(
            target,
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(liveObject.activationCount, 1)
        XCTAssertEqual(result.activationTrace?.axActivateReturned, false)
        XCTAssertEqual(result.activationTrace?.tapActivationDispatched, false)
        XCTAssertDiagnostic(result.message, contains: [
            "element inflation failed [noRevealPath]",
            "no live scrollable ancestor",
            "liveFrame=",
            "activationPoint=",
            "screenBounds=",
        ])
    }

    private func installActivationTargetWithUnusableTapGeometry(
        heistId: HeistId,
        label: String,
        object: NSObject
    ) async throws -> ResolvedAccessibilityTarget {
        let frame = CGRect(
            x: 24,
            y: ScreenMetrics.current.bounds.maxY + 80,
            width: 180,
            height: 44
        )
        let activationPoint = CGPoint(x: frame.midX, y: frame.midY)
        object.accessibilityLabel = label
        object.accessibilityFrame = frame
        object.accessibilityActivationPoint = activationPoint
        let element = AccessibilityElement.make(
            label: label,
            traits: .button,
            shape: .frame(AccessibilityRect(frame)),
            activationPoint: activationPoint
        )
        let entry = InterfaceTree.Element(
            heistId: heistId,
            path: TreePath([0]),
            scrollMembership: nil,
            geometry: testGeometry(
                for: element,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: element)
            ),
            element: element
        )
        await installSyntheticObservation(InterfaceObservation.makeForTests(
            elements: [heistId: entry],
            hierarchy: [.element(element, traversalIndex: 0)],
            heistIdsByPath: [TreePath([0]): heistId],
            elementRefs: [heistId: .init(object: object, scrollView: nil)],
            firstResponderHeistId: nil
        ))
        return try AccessibilityTarget.label(label).resolve(in: .empty)
    }

    func testProductionActionDispatchReportsOwnedPhaseTiming() async throws {
        let rootView = UIView(frame: UIScreen.main.bounds)
        rootView.backgroundColor = .white
        let liveObject = ActionActivationOverrideView(
            frame: CGRect(x: 80, y: 180, width: 180, height: 44)
        )
        liveObject.isAccessibilityElement = true
        liveObject.accessibilityLabel = "Timed action"
        liveObject.accessibilityIdentifier = "timed_action"
        liveObject.accessibilityTraits = .button
        rootView.addSubview(liveObject)

        let window = try installModalWindow(rootView: rootView)
        defer {
            window.rootViewController?.view.accessibilityViewIsModal = false
            window.isHidden = true
        }
        let heistId: HeistId = "timed_action"
        let observation = InterfaceObservation.makeForTests(
            elements: [(
                AccessibilityElement.make(
                    label: "Timed action",
                    identifier: heistId.rawValue,
                    traits: .button,
                    shape: .frame(AccessibilityRect(liveObject.frame))
                ),
                heistId
            )],
            objects: [heistId: liveObject]
        )
        await installSyntheticObservation(observation)

        let command = HeistActionCommand.activate(.identifier("timed_action"))
        let result = await brains.executeRuntimeAction(command)
        let timing = try XCTUnwrap(result.timing)

        XCTAssertTrue(result.outcome.isSuccess, result.message ?? "activate failed")
        let targetResolution = try XCTUnwrap(timing.targetResolutionMs)
        let actionDispatch = try XCTUnwrap(timing.actionDispatchMs)
        let interaction = try XCTUnwrap(timing.interactionMs)
        let total = try XCTUnwrap(timing.totalMs)
        XCTAssertGreaterThanOrEqual(interaction.milliseconds, targetResolution.milliseconds)
        XCTAssertGreaterThanOrEqual(interaction.milliseconds, actionDispatch.milliseconds)
        for phase in [targetResolution, actionDispatch, interaction] {
            XCTAssertGreaterThanOrEqual(total.milliseconds, phase.milliseconds)
        }
        XCTAssertEqual(liveObject.activationCount, 1)
    }

    func testExecuteActivateDispatchesNoTraitElementWithoutActivationImplementation() async throws {
        let heistId: HeistId = "plain_label"
        let liveObject = UIView()
        await registerScreenElement(
            heistId: heistId,
            element: makeElement(label: "Plain label"),
            object: liveObject
        )

        let target = try AccessibilityTarget.label("Plain label").resolve(in: .empty)
        var timing = ActionTiming()
        let result = await brains.actions.executeActivate(
            target,
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(result.activationTrace?.axActivateReturned, false)
        XCTAssertEqual(result.activationTrace?.implementsAccessibilityActivation, false)
        XCTAssertTrue(result.activationTrace?.tapActivationDispatched == true)
        XCTAssertEqual(result.activationTrace?.tapActivationSucceeded, true)
        XCTAssertEqual(result.subjectEvidence?.element.semantics.assertable.label, "Plain label")
        XCTAssertEqual(result.subjectEvidence?.element.semantics.assertable.actions, [])
    }

    func testCanonicalPlanCarriesPostActionObservationForSuccessfulAndFailedActions() async throws {
        let rootView = UIView(frame: UIScreen.main.bounds)
        rootView.backgroundColor = .white

        let successful = ActionActivationOverrideView(frame: CGRect(x: 40, y: 140, width: 220, height: 44))
        successful.isAccessibilityElement = true
        successful.accessibilityLabel = "Trace Success"
        successful.accessibilityIdentifier = "trace_success"
        successful.accessibilityTraits = .button
        rootView.addSubview(successful)

        let failing = UIView(frame: CGRect(x: 40, y: 220, width: 220, height: 44))
        failing.isAccessibilityElement = true
        failing.accessibilityLabel = "Trace Failure"
        failing.accessibilityIdentifier = "trace_failure"
        failing.accessibilityTraits = .notEnabled
        rootView.addSubview(failing)

        let window = try installModalWindow(rootView: rootView)
        defer {
            window.rootViewController?.view.accessibilityViewIsModal = false
            window.isHidden = true
        }
        let successId: HeistId = "trace_success"
        let failureId: HeistId = "trace_failure"
        let observation = InterfaceObservation.makeForTests(
            elements: [
                (
                    makeElement(
                        label: "Trace Success",
                        identifier: successId.rawValue,
                        traits: .button
                    ),
                    successId
                ),
                (
                    makeElement(
                        label: "Trace Failure",
                        identifier: failureId.rawValue,
                        traits: .notEnabled
                    ),
                    failureId
                ),
            ],
            objects: [
                successId: successful,
                failureId: failing,
            ]
        )
        await installSyntheticObservation(observation)

        let success = try await heistStepResult(
            for: .action(ActionStep(command: .activate(.identifier("trace_success")))),
            label: "successful activation"
        )
        XCTAssertTrue(success.outcome.isSuccess, success.message ?? "activate failed")
        let successObservation = try XCTUnwrap(success.observationEvidence)
        XCTAssertEqual(successObservation.coverage, .complete)
        XCTAssertNotNil(successObservation.current)

        let failure = try await heistStepResult(
            for: .action(ActionStep(command: .activate(.identifier("trace_failure")))),
            label: "failed activation"
        )
        XCTAssertFalse(failure.outcome.isSuccess)
        XCTAssertEqual(failure.method, .activate)
        let failureObservation = try XCTUnwrap(failure.observationEvidence)
        XCTAssertEqual(failureObservation.coverage, .complete)
        let current = try XCTUnwrap(failureObservation.current)
        XCTAssertTrue(current.interface.projectedElements.contains {
            $0.semantics.assertable.identifier == "trace_failure"
        })
    }

    func testExecuteActivateBlocksDisabledElementWithActivationOverride() async throws {
        let heistId: HeistId = "disabled_action"
        let liveObject = ActionActivationOverrideView()
        await registerScreenElement(
            heistId: heistId,
            element: makeElement(label: "Disabled action", traits: .notEnabled),
            object: liveObject
        )

        let target = try AccessibilityTarget.label("Disabled action").resolve(in: .empty)
        var timing = ActionTiming()
        let result = await brains.actions.executeActivate(
            target,
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .activate)
        XCTAssertTrue(result.message?.contains("disabled") ?? false)
        XCTAssertEqual(liveObject.activationCount, 0)
    }

    func testExecuteIncrementSucceedsWhenElementObjectIsLive() async throws {
        let heistId: HeistId = "live_slider"
        let liveObject = UISlider()
        await registerScreenElement(
            heistId: heistId,
            element: makeElement(label: "Live", traits: .adjustable),
            object: liveObject
        )

        let target = try AccessibilityTarget.label("Live").resolve(in: .empty)
        var timing = ActionTiming()
        let result = await brains.actions.executeIncrement(
            target,
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.method, .increment)
    }

    func testActionsExecuteIncrementUsesCurrentAccessibilityCaptureGeometry() async throws {
        let heistId: HeistId = "moving_slider"
        let staleObjectPoint = CGPoint(x: 20, y: 20)
        let staleObjectFrame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let capturePoint = CGPoint(x: 190, y: 302)
        let captureFrame = CGRect(x: 150, y: 280, width: 80, height: 44)
        let element = AccessibilityElement.make(
            label: "Moving",
            traits: .adjustable,
            shape: .frame(AccessibilityRect(captureFrame)),
            activationPoint: capturePoint
        )
        let liveObject = AdjustableGeometryView(frame: staleObjectFrame, activationPoint: staleObjectPoint)
        await installScreen(elements: [(element, heistId)], objects: [heistId: liveObject])

        let target = try AccessibilityTarget.label("Moving").resolve(in: .empty)
        let resolved = brains.vault.resolveTarget(target).resolvedElement
        let liveTarget: TheVault.LiveActionTarget?
        if let resolved,
           case .resolved(let target) = brains.vault.resolveLiveActionTarget(for: resolved) {
            liveTarget = target
        } else {
            liveTarget = nil
        }

        XCTAssertEqual(liveTarget?.frame, captureFrame)
        XCTAssertEqual(liveTarget?.activationPoint, capturePoint)
        XCTAssertNotEqual(liveTarget?.activationPoint, staleObjectPoint)

        var timing = ActionTiming()

        let result = await brains.actions.executeIncrement(
            target,
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.method, .increment)
        XCTAssertEqual(liveObject.incrementCount, 1)
    }

    func testActionsExecuteIncrementUsesMatcherTargetBeforeLiveResolution() async throws {
        let heistId: HeistId = "quantity_stepper"
        let sourceElement = makeElement(
            label: "Quantity",
            value: "0",
            identifier: "quantity_stepper",
            traits: .adjustable
        )
        let sourceScreen = InterfaceObservation.makeForTests(elements: [(sourceElement, heistId)])
        let currentElement = makeElement(
            label: "Quantity",
            value: "1",
            identifier: "quantity_stepper",
            traits: .adjustable
        )
        let liveObject = AdjustableGeometryView(
            frame: CGRect(x: 80, y: 180, width: 180, height: 44),
            activationPoint: CGPoint(x: 170, y: 202)
        )
        await installSyntheticObservation(.makeForTests(
            elements: [(currentElement, heistId)],
            objects: [heistId: liveObject]
        ))
        let target = try matcherTarget(label: "Quantity", in: sourceScreen)

        var timing = ActionTiming()

        let result = await brains.actions.executeIncrement(
            try target.resolve(in: .empty),
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertTrue(result.success, result.message ?? "increment failed")
        XCTAssertEqual(result.method, .increment)
        XCTAssertEqual(liveObject.incrementCount, 1)
    }

    func testActionsExecuteIncrementUsesAccessibilityGeometryWhenObjectFrameIsMissing() async throws {
        let heistId: HeistId = "quantity_stepper"
        let sourceElement = makeElement(
            label: "Quantity",
            value: "0",
            identifier: "quantity_stepper",
            traits: .adjustable
        )
        let sourceScreen = InterfaceObservation.makeForTests(elements: [(sourceElement, heistId)])
        let currentElement = makeElement(
            label: "Quantity",
            value: "1",
            identifier: "quantity_stepper",
            traits: .adjustable
        )
        let liveObject = AdjustableGeometryView(frame: .zero, activationPoint: CGPoint(x: 170, y: 202))
        await installSyntheticObservation(.makeForTests(
            elements: [(currentElement, heistId)],
            objects: [heistId: liveObject]
        ))
        let target = try matcherTarget(label: "Quantity", in: sourceScreen)

        var timing = ActionTiming()

        let result = await brains.actions.executeIncrement(
            try target.resolve(in: .empty),
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertTrue(result.success, result.message ?? "increment failed")
        XCTAssertEqual(result.method, .increment)
        XCTAssertEqual(liveObject.incrementCount, 1)
    }

    func testViewportDebugCommandsResolveForDirectRuntimeDispatch() async throws {
        let target = AccessibilityTarget.identifier("target")
        let commands: [(HeistActionCommand, HeistActionCommandType)] = [
            (.scroll(ScrollTarget(direction: .down)), .scroll),
            (.scrollToVisible(target), .scrollToVisible),
            (.scrollToEdge(ScrollToEdgeTarget(edge: .bottom)), .scrollToEdge),
        ]

        for (command, expectedType) in commands {
            XCTAssertNotNil(command.durableHeistActionFailure)
            XCTAssertNoThrow(try command.resolve(in: .empty))
            XCTAssertEqual(command.wireType, expectedType)
        }
    }

    func testClearCacheResetsStash() async {
        let element = makeElement(label: "Item")
        await installScreen(elements: [(element, "test_id")])

        await brains.vault.resetInterfaceForLifecycle()

        XCTAssertEqual(brains.vault.interfaceTree, .empty)
    }

    func testCanonicalWaitReportsUnavailableAccessibilityTreeAtItsBaselineBoundary() async throws {
        let step = WaitStep(predicate: .exists(.label("never")), timeout: try .milliseconds(1))
        let plan = try HeistPlan(body: [.wait(step)])
        let execution = await withNoTraversableWindows {
            await brains.executeHeistPlan(plan)
        }
        let heist = try execution.get()
        let result = try XCTUnwrap(heist.steps.first)

        XCTAssertEqual(result.status, .failed)
        XCTAssertNil(result.reportActionResult)
        XCTAssertEqual(result.failure?.category, .runtimeUnavailable)
    }

    func testActionsExecuteIncrementFailsWhenSemanticTargetHasNoLiveGeometry() async throws {
        let heistId: HeistId = "geometry_missing_slider"
        let element = AccessibilityElement.make(
            label: "Geometry Missing",
            traits: .adjustable,
            shape: .frame(.zero)
        )
        let liveObject = AdjustableGeometryView(
            frame: CGRect(x: 20, y: 20, width: 120, height: 44),
            activationPoint: CGPoint(x: 80, y: 42)
        )
        await installScreen(elements: [(element, heistId)], objects: [heistId: liveObject])

        let target = try AccessibilityTarget.label("Geometry Missing").resolve(in: .empty)
        let resolved = brains.vault.resolveTarget(target).resolvedElement
        let liveTarget: TheVault.LiveActionTarget?
        if let resolved,
           case .resolved(let target) = brains.vault.resolveLiveActionTarget(for: resolved) {
            liveTarget = target
        } else {
            liveTarget = nil
        }
        var timing = ActionTiming()
        let result = await brains.actions.executeIncrement(
            target,
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertNotNil(resolved)
        XCTAssertNil(liveTarget)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.method, .increment)
        XCTAssertEqual(liveObject.incrementCount, 0)
        XCTAssertDiagnostic(result.message, contains: [
            "element inflation failed [geometryNotActionable]",
            "method=increment",
            "label=\"Geometry Missing\"",
            "fresh live geometry from element inflation",
        ])
    }

    func testActionsExecuteIncrementReResolvesReplacementObjectForCommittedHeistId() async throws {
        let heistId: HeistId = "refreshed_slider"
        let settledElement = AccessibilityElement.make(
            label: "Refreshed Slider",
            identifier: "refreshed_slider",
            traits: .adjustable,
            frame: CGRect(x: 10, y: 10, width: 120, height: 44),
            respondsToUserInteraction: false
        )
        let refreshedElement = AccessibilityElement.make(
            label: "Refreshed Slider",
            identifier: "refreshed_slider",
            traits: .adjustable,
            frame: CGRect(x: 80, y: 180, width: 180, height: 44),
            respondsToUserInteraction: false
        )
        let replacementObject = AdjustableGeometryView(
            frame: refreshedElement.bhFrame,
            activationPoint: refreshedElement.bhResolvedActivationPoint
        )
        do {
            let deallocatedObject = AdjustableGeometryView(
                frame: settledElement.bhFrame,
                activationPoint: settledElement.bhResolvedActivationPoint
            )
            await installScreen(elements: [(settledElement, heistId)], objects: [heistId: deallocatedObject])
        }

        let target = try AccessibilityTarget.identifier("refreshed_slider").resolve(in: .empty)
        guard let committedTarget = brains.vault.resolveTarget(target).resolvedElement else {
            XCTFail("Expected committed semantic target to resolve")
            return
        }
        guard case .objectUnavailable = brains.vault.resolveLiveActionTarget(for: committedTarget) else {
            XCTFail("Expected the settled UIKit evidence to be held weakly")
            return
        }
        visibleObservationSource.observation = .makeForTests(
            elements: [(refreshedElement, heistId)],
            objects: [heistId: replacementObject]
        )

        var timing = ActionTiming()

        let result = await brains.actions.executeIncrement(
            target,
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertTrue(result.success, result.message ?? "increment failed")
        XCTAssertEqual(result.method, .increment)
        XCTAssertEqual(committedTarget.heistId, heistId)
        XCTAssertEqual(result.subjectEvidence?.element.semantics.assertable.identifier, heistId.rawValue)
        XCTAssertEqual(replacementObject.incrementCount, 1)
        XCTAssertEqual(
            brains.vault.interfaceElement(heistId: heistId)?.element.bhFrame,
            refreshedElement.bhFrame
        )
        guard case .resolved(let liveTarget) = brains.vault.resolveLiveActionTarget(for: committedTarget) else {
            XCTFail("Expected replacement live evidence for committed target")
            return
        }
        XCTAssertTrue(liveTarget.object === replacementObject)
        XCTAssertEqual(liveTarget.frame, refreshedElement.bhFrame)
    }

    func testActionsExecuteActivateRefreshesCommittedHeistIdBeforeSingleActivationAttempt() async throws {
        let heistId: HeistId = "refresh_activate"
        let settledElement = AccessibilityElement.make(
            label: "Refresh Activate",
            identifier: "refresh_activate",
            traits: .button,
            frame: CGRect(x: 40, y: 120, width: 180, height: 44)
        )
        let staleObject = RefusingActivationView(frame: settledElement.bhFrame)
        let replacementObject = ActionActivationOverrideView(frame: settledElement.bhFrame)
        await installScreen(elements: [(settledElement, heistId)], objects: [heistId: staleObject])
        visibleObservationSource.observation = .makeForTests(
            elements: [(settledElement, heistId)],
            objects: [heistId: replacementObject]
        )

        let target = try AccessibilityTarget.identifier("refresh_activate").resolve(in: .empty)
        var timing = ActionTiming()
        let result = await brains.actions.executeActivate(
            target,
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertTrue(result.success, result.message ?? "activate failed")
        XCTAssertEqual(result.method, .activate)
        XCTAssertEqual(result.subjectEvidence?.element.semantics.assertable.identifier, heistId.rawValue)
        XCTAssertEqual(replacementObject.activationCount, 1)
        XCTAssertEqual(staleObject.activationCount, 0)
    }

    func testActionsExecuteActivateKeepsCommittedHeistIdWhenOrdinalOrderChangesDuringRefresh() async throws {
        let selectedId: HeistId = "selected_action"
        let otherId: HeistId = "other_action"
        let element = AccessibilityElement.make(
            label: "Repeated Action",
            traits: .button,
            frame: CGRect(x: 40, y: 120, width: 180, height: 44)
        )
        let selectedObject = ActionActivationOverrideView(frame: element.bhFrame)
        let otherObject = ActionActivationOverrideView(frame: element.bhFrame)
        await installScreen(elements: [
            (element, selectedId),
            (element, otherId),
        ])

        let target = try AccessibilityTarget.target(
            .label("Repeated Action"),
            ordinal: 0
        ).resolve(in: .empty)
        let reorderedScreen = InterfaceObservation.makeForTests(
            elements: [
                (element, otherId),
                (element, selectedId),
            ],
            objects: [
                selectedId: selectedObject,
                otherId: otherObject,
            ]
        )
        visibleObservationSource.observation = reorderedScreen

        var timing = ActionTiming()
        let result = await brains.actions.executeActivate(
            target,
            deadline: actionDeadline(),
            timing: &timing
        )

        XCTAssertTrue(result.success, result.message ?? "activate failed")
        XCTAssertEqual(result.resolvedElementId, selectedId)
        XCTAssertEqual(selectedObject.activationCount, 1)
        XCTAssertEqual(otherObject.activationCount, 0)
    }

}
#endif
