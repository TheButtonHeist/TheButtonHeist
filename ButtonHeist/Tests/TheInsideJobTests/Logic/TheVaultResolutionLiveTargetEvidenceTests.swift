#if canImport(UIKit)
import XCTest
import ThePlans
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@testable import TheScore

@MainActor
extension TheVaultResolutionTests {

    func testContainerTargetResolutionUsesCommittedSemanticContainers() async throws {
        let path = TreePath([0, 1])
        let frame = CGRect(x: 0, y: 900, width: 240, height: 80)
        let viewSpace = try availableViewSpace(frame: frame)
        let container = AccessibilityContainer(
            type: .semanticGroup(label: "Actions", value: nil), identifier: "actions",
            frame: AccessibilityRect(frame),
            customActions: [.init(name: "Archive")]
        )
        await vault.installObservationForTesting(InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: [:],
                containers: [
                    path: .init(
                        container: container,
                        path: path,
                        containerName: "semantic_actions__actions",
                        viewSpace: viewSpace
                    ),
                ]
            ),
            liveCapture: LiveCapture.makeForTests()
        ))

        let result = vault.resolveTarget(try resolvedTarget(
            .container(.identifier("actions"))
        ))
        switch result {
        case .resolved(.container(let resolved)):
            XCTAssertEqual(resolved.path, path)
            XCTAssertEqual(resolved.containerName, "semantic_actions__actions")
            XCTAssertEqual(resolved.viewSpace, viewSpace)
        case .resolved(.element), .notFound, .ambiguous:
            XCTFail("Expected semantic container resolution, got \(result.diagnostics)")
        }
    }

    func testContainerTargetResolutionReportsStructuredFacts() async throws {
        let primaryPath = TreePath([0, 1])
        let secondaryPath = TreePath([0, 2])
        let primaryFrame = CGRect(x: 0, y: 120, width: 240, height: 80)
        let secondaryFrame = CGRect(x: 0, y: 240, width: 240, height: 80)
        await vault.installObservationForTesting(InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: [:],
                containers: [
                    primaryPath: .init(
                        container: AccessibilityContainer(
                            type: .semanticGroup(label: "Actions", value: nil), identifier: "primary",
                            frame: AccessibilityRect(primaryFrame)
                        ),
                        path: primaryPath,
                        containerName: "actions_primary",
                        viewSpace: try availableViewSpace(frame: primaryFrame)
                    ),
                    secondaryPath: .init(
                        container: AccessibilityContainer(
                            type: .semanticGroup(label: "Actions", value: nil), identifier: "secondary",
                            frame: AccessibilityRect(secondaryFrame)
                        ),
                        path: secondaryPath,
                        containerName: "actions_secondary",
                        viewSpace: try availableViewSpace(frame: secondaryFrame)
                    ),
                ]
            ),
            liveCapture: LiveCapture.makeForTests()
        ))

        let predicate = ContainerPredicate.matching(
            .type(.semanticGroup),
            .semantic(.label("Actions"))
        )
        let ambiguous = vault.resolveTarget(try resolvedTarget(
            .container(predicate)
        ))
        guard case .ambiguous(let facts) = ambiguous else {
            XCTFail("Expected structured ambiguity, got \(ambiguous)")
            return
        }
        XCTAssertEqual(facts.matchedCount, 2)
        XCTAssertEqual(facts.resolutionScope, .interface)
        let ambiguousMatches = try XCTUnwrap(facts.containerMatches)
        XCTAssertEqual(
            ambiguousMatches.exactMatches.map { $0.container.containerPredicateFacts.identifier },
            ["primary", "secondary"]
        )
        XCTAssertEqual(ambiguousMatches.exactMatches.map(\.containerName), ["actions_primary", "actions_secondary"])
        XCTAssertTrue(ambiguous.diagnostics.contains("container target is ambiguous across 2 containers"))
        XCTAssertFalse(ambiguous.diagnostics.contains("containerName"))

        let outOfRange = vault.resolveTarget(try resolvedTarget(
            .container(predicate, ordinal: 3)
        ))
        guard case .notFound(let notFoundFacts) = outOfRange else {
            XCTFail("Expected structured ordinal miss, got \(outOfRange)")
            return
        }
        XCTAssertEqual(notFoundFacts.reason, .ordinalOutOfRange(requested: 3, matchCount: 2))
        XCTAssertEqual(notFoundFacts.resolutionScope, .interface)
        XCTAssertEqual(notFoundFacts.containerMatches?.exactMatches.map(\.path), [primaryPath, secondaryPath])
        XCTAssertTrue(outOfRange.diagnostics.contains("container target ordinal 3"))
        XCTAssertTrue(outOfRange.diagnostics.contains("target an element inside the intended region"))
    }

    func testGeneratedConcreteTargetUsesMinimumPredicateSelector() async throws {
        let selected = element(label: "Mode", value: "A", traits: [.button, .selected])
        let other = element(label: "Mode", value: "B", traits: [.button, .selected])
        await vault.installObservationForTesting(InterfaceObservation.makeForTests(elements: [
            (selected, "mode_a"),
            (other, "mode_b"),
        ]))

        let treeElement = try XCTUnwrap(vault.interfaceElement(heistId: "mode_a"))

        XCTAssertEqual(
            vault.minimumUniqueTarget(for: treeElement),
            AccessibilityTarget.element(
                .label("Mode"),
                .traits([.button]),
                .value("A")
            )
        )
    }

    // MARK: - Live Geometry Replay

    func testMatcherTargetAcquiresFreshLiveGeometry() async throws {
        let sourceFrame = CGRect(x: 10, y: 20, width: 80, height: 44)
        let sourcePoint = CGPoint(x: 50, y: 42)
        let freshFrame = CGRect(x: 120, y: 240, width: 80, height: 44)
        let freshPoint = CGPoint(x: 160, y: 262)
        let currentElement = AccessibilityElement.make(
            label: "Quantity",
            value: "1",
            identifier: "quantity_stepper",
            traits: .adjustable,
            shape: .frame(AccessibilityRect(freshFrame)),
            activationPoint: freshPoint
        )
        let object = UIAccessibilityElement(accessibilityContainer: NSObject())
        object.accessibilityFrame = sourceFrame
        object.accessibilityActivationPoint = sourcePoint
        await vault.installObservationForTesting(InterfaceObservation.makeForTests(
            elements: [(currentElement, "quantity_1")],
            objects: ["quantity_1": object]
        ))

        let executableTarget = AccessibilityTarget.element(.identifier("quantity_stepper"))

        guard case .predicate(let matcher, let ordinal) = executableTarget else {
            XCTFail("Expected semantic replay target to carry matcher identity, got \(executableTarget)")
            return
        }
        XCTAssertEqual(matcher.checks, [.identifier(.exact("quantity_stepper"))])
        XCTAssertNil(ordinal)

        guard let resolved = vault.resolveTarget(try resolvedTarget(executableTarget)).resolvedElement else {
            XCTFail("Expected semantic replay selector to resolve against current observation")
            return
        }
        XCTAssertEqual(resolved.heistId, "quantity_1")
        XCTAssertEqual(resolved.geometry.screen, TheVault.onscreenSpace(for: currentElement))
        guard case .available(let resolvedViewSpace) = resolved.geometry.view else {
            return XCTFail("Expected fresh parent-space geometry")
        }
        XCTAssertEqual(resolvedViewSpace.ownerPath, .root)
        XCTAssertEqual(resolvedViewSpace.frame.cgRect, freshFrame)
        XCTAssertEqual(resolvedViewSpace.activationPoint.cgPoint, freshPoint)

        guard case .resolved(let liveTarget) = vault.resolveLiveActionTarget(for: resolved) else {
            XCTFail("Expected current accessibility capture to provide action geometry")
            return
        }
        XCTAssertEqual(liveTarget.frame, freshFrame)
        XCTAssertEqual(liveTarget.activationPoint, freshPoint)
        XCTAssertNotEqual(liveTarget.frame, object.accessibilityFrame)
        XCTAssertNotEqual(liveTarget.activationPoint, object.accessibilityActivationPoint)
        XCTAssertNotEqual(liveTarget.frame, sourceFrame)
        XCTAssertNotEqual(liveTarget.activationPoint, sourcePoint)
    }

    func testVisibleCommitSuppliesFreshSemanticsAndLiveGeometryAtomically() async throws {
        let staleFrame = CGRect(x: 32, y: 865, width: 240, height: 44)
        let stalePoint = CGPoint(x: staleFrame.midX, y: staleFrame.midY)
        let settledElement = AccessibilityElement.make(
            label: "Rotor Host",
            identifier: "rotor_host",
            traits: .staticText,
            shape: .frame(AccessibilityRect(staleFrame)),
            activationPoint: stalePoint,
            customRotors: [.init(name: "Errors")]
        )
        let liveObject = UIAccessibilityElement(accessibilityContainer: NSObject())
        liveObject.accessibilityFrame = staleFrame
        liveObject.accessibilityActivationPoint = stalePoint
        await vault.installObservationForTesting(InterfaceObservation.makeForTests(
            elements: [(settledElement, "rotor_host")],
            objects: ["rotor_host": liveObject]
        ))

        let freshFrame = CGRect(x: 32, y: 320, width: 240, height: 44)
        let freshPoint = CGPoint(x: freshFrame.midX, y: freshFrame.midY)
        let freshElement = AccessibilityElement.make(
            label: "Rotor Host",
            identifier: "rotor_host",
            traits: .staticText,
            shape: .frame(AccessibilityRect(freshFrame)),
            activationPoint: freshPoint,
            customRotors: [.init(name: "Errors")]
        )
        await vault.installObservationForTesting(InterfaceObservation.makeForTests(
            elements: [(freshElement, "rotor_host")],
            objects: ["rotor_host": liveObject]
        ))

        let target = literalTarget(ResolvedElementPredicate.identifier("rotor_host"))
        let committed = try XCTUnwrap(vault.resolveTarget(target).resolvedElement)
        XCTAssertEqual(committed.geometry.screen, TheVault.onscreenSpace(for: freshElement))
        guard case .available(let committedViewSpace) = committed.geometry.view else {
            return XCTFail("Expected committed parent-space geometry")
        }
        XCTAssertEqual(committedViewSpace.ownerPath, .root)
        XCTAssertEqual(committedViewSpace.frame.cgRect, freshFrame)
        XCTAssertEqual(committedViewSpace.activationPoint.cgPoint, freshPoint)

        let visible = try XCTUnwrap(vault.resolveVisibleTarget(target).resolvedElement)
        XCTAssertEqual(visible.geometry, committed.geometry)

        guard case .resolved(let liveTarget) = vault.resolveLiveActionTarget(for: committed) else {
            return XCTFail("Expected fresh live action target")
        }
        XCTAssertEqual(liveTarget.frame, freshFrame)
        XCTAssertEqual(liveTarget.activationPoint, freshPoint)
        XCTAssertNotEqual(liveTarget.frame, liveObject.accessibilityFrame)
        XCTAssertNotEqual(liveTarget.activationPoint, liveObject.accessibilityActivationPoint)
    }

    func testMismatchedLiveEvidenceCannotAttachToCommittedTree() throws {
        let committedId: HeistId = "committed_control"
        let rawId: HeistId = "raw_control"
        let committedFrame = CGRect(x: 20, y: 40, width: 120, height: 44)
        let committedElement = AccessibilityElement.make(
            label: "Shared Control",
            traits: .adjustable,
            frame: committedFrame
        )
        let committedObservation = InterfaceObservation.makeForTests(
            elements: [(committedElement, committedId)]
        )
        var state = TheVault.State()
        let initial = requireCommittedObservation(
            state.commitObservation(
                stateAdmission(for: committedObservation),
                beginningNewBaseline: false
            )
        )
        let priorHistoryEnd = state.history.endIndex
        let priorNotificationIndex = state.notificationIndex
        let priorCurrent = state.current
        let priorObservation = state.interfaceObservation

        let rawObject = NSObject()
        let rawFrame = CGRect(x: 80, y: 160, width: 180, height: 52)
        let rawElement = AccessibilityElement.make(
            label: "Shared Control",
            traits: .adjustable,
            frame: rawFrame
        )
        let rawObservation = InterfaceObservation.makeForTests(
            elements: [(rawElement, rawId)],
            objects: [rawId: rawObject]
        )

        XCTAssertThrowsError(
            try rawObservation.replacingTreeWithCurrentCapture(committedObservation.tree)
        )
        XCTAssertThrowsError(
            try rawObservation.replacingTreeWithCurrentCapture(committedObservation.tree)
        )
        XCTAssertEqual(state.history.endIndex, priorHistoryEnd)
        XCTAssertEqual(state.notificationIndex, priorNotificationIndex)
        XCTAssertEqual(state.current, priorCurrent)
        XCTAssertEqual(state.interfaceObservation?.tree, priorObservation?.tree)
        XCTAssertEqual(initial.current, priorCurrent)
    }

    func testVisibleSettleCommitStripsLiveHandlesFromSettledProjection() async {
        let liveObject = UIAccessibilityElement(accessibilityContainer: NSObject())
        liveObject.accessibilityFrame = CGRect(x: 10, y: 10, width: 100, height: 44)
        let observation = InterfaceObservation.makeForTests(
            elements: [(element(label: "Save", traits: .button), "save")],
            objects: ["save": liveObject]
        )

        await vault.semanticObservationStream.commitVisibleObservationForTesting(observation)

        XCTAssertNotNil(vault.currentLiveCapture.object(for: "save"))
        XCTAssertNil(LiveCapture.makeForTests(tree: vault.interfaceTree).object(for: "save"))
    }

    func testVisibleCommitSuppliesFreshContainerSemanticsAndLiveGeometryAtomically() async throws {
        let path = TreePath([0])
        let staleFrame = CGRect(x: 0, y: 800, width: 240, height: 80)
        let freshFrame = CGRect(x: 0, y: 120, width: 240, height: 80)
        let staleContainer = AccessibilityContainer(
            type: .semanticGroup(label: "Actions", value: nil), identifier: "actions",
            frame: AccessibilityRect(staleFrame)
        )
        let freshContainer = AccessibilityContainer(
            type: .semanticGroup(label: "Actions", value: nil), identifier: "actions",
            frame: AccessibilityRect(freshFrame)
        )
        let staleViewSpace = try availableViewSpace(frame: staleFrame)
        let freshViewSpace = try availableViewSpace(frame: freshFrame)
        let liveObject = NSObject()
        let settledObservationScreen = InterfaceObservation.makeForTests(
            elements: [:],
            hierarchy: [.container(staleContainer, children: [])],
            containerNamesByPath: [path: "actions"],
            containerViewSpacesByPath: [
                path: staleViewSpace,
            ],
            firstResponderHeistId: nil
        )
        await vault.semanticObservationStream.commitDiscoveryObservationForTesting(settledObservationScreen)
        let liveScreen = InterfaceObservation.makeForTests(
            elements: [:],
            hierarchy: [.container(freshContainer, children: [])],
            containerNamesByPath: [path: "actions"],
            containerRefsByPath: [path: .init(object: liveObject)],
            containerViewSpacesByPath: [
                path: freshViewSpace,
            ],
            firstResponderHeistId: nil
        )
        await vault.installObservationForTesting(liveScreen)

        let resolved = vault.resolveTarget(try resolvedTarget(
            .container(.identifier("actions"))
        ))
        guard case .resolved(.container(let semanticTarget)) = resolved else {
            return XCTFail("Expected semantic container, got \(resolved.diagnostics)")
        }
        guard case .resolved(let liveTarget) = vault.resolveLiveContainerTarget(for: semanticTarget) else {
            return XCTFail("Expected fresh live container target")
        }

        XCTAssertTrue(liveTarget.object === liveObject)
        XCTAssertEqual(liveTarget.containerTarget.container.frame.cgRect, freshFrame)
        XCTAssertEqual(liveTarget.containerTarget.viewSpace, freshViewSpace)
        XCTAssertEqual(liveTarget.frame, freshFrame)
        XCTAssertEqual(liveTarget.activationPoint, CGPoint(x: freshFrame.midX, y: freshFrame.midY))
    }

    func testViewportUpdatePreservesKnownDiscoveryUnionWhenRefreshingSameScreen() async throws {
        let controls = element(label: "Controls Demo", traits: .button)
        let customRotors = element(label: "Custom Rotors", traits: .button)
        let discovery = InterfaceObservation.makeForTests(
            elements: [(customRotors, "custom_rotors")],
            offViewport: [
                InterfaceObservation.OffViewportEntry(
                    controls,
                    heistId: "controls_demo",
                    scrollContainerPath: TreePath([0])
                ),
            ]
        )
        await vault.semanticObservationStream.commitDiscoveryObservationForTesting(discovery)

        let refreshedBottom = InterfaceObservation.makeForTests(elements: [(customRotors, "custom_rotors")])
        await vault.semanticObservationStream.commitVisibleObservationForTesting(refreshedBottom)

        XCTAssertEqual(vault.viewportElementIDs, ["custom_rotors"])
        XCTAssertEqual(vault.interfaceElementIDs, ["controls_demo", "custom_rotors"])
        XCTAssertEqual(
            vault.resolveTarget(try resolvedTarget(
                AccessibilityTarget.element(.label("Controls Demo"), traits: [.button])
            )).resolvedElement?.heistId,
            "controls_demo"
        )
    }

    func testViewportUpdateDoesNotPreserveOffViewportMemoryForDisjointCommittedViewport() async {
        let bottom = element(label: "Bottom Row", traits: .button)
        let staleOffscreen = element(label: "Stale Row", traits: .button)
        let discovery = InterfaceObservation.makeForTests(
            elements: [(bottom, "bottom_row")],
            offViewport: [
                InterfaceObservation.OffViewportEntry(
                    staleOffscreen,
                    heistId: "shared_row",
                    scrollContainerPath: TreePath([0])
                ),
            ]
        )
        await vault.semanticObservationStream.commitDiscoveryObservationForTesting(discovery)

        let freshVisible = element(label: "Fresh Row", traits: .button)
        let refreshedTop = InterfaceObservation.makeForTests(elements: [(freshVisible, "shared_row")])
        await vault.semanticObservationStream.commitVisibleObservationForTesting(refreshedTop)

        XCTAssertEqual(vault.viewportElementIDs, ["shared_row"])
        XCTAssertEqual(vault.interfaceElementIDs, ["shared_row"])
        XCTAssertEqual(vault.interfaceElement(heistId: "shared_row")?.element.label, "Fresh Row")
        XCTAssertNil(vault.interfaceElement(heistId: "bottom_row"))
    }

    func testViewportUpdateDropsDiscoveryMemoryWhenScreenIdChangesDespiteSharedVisibleElement() async {
        let previousHeader = element(label: "Controls Demo", traits: .header)
        let sharedPreviousAction = element(label: "Shared Action", traits: .button)
        let staleOffscreen = element(label: "Stale Offscreen", traits: .button)
        let previousDiscovery = InterfaceObservation.makeForTests(
            elements: [
                (previousHeader, "controls_demo"),
                (sharedPreviousAction, "shared_action"),
            ],
            offViewport: [
                InterfaceObservation.OffViewportEntry(
                    staleOffscreen,
                    heistId: "stale_offscreen",
                    scrollContainerPath: TreePath([0])
                ),
            ]
        )
        await vault.semanticObservationStream.commitDiscoveryObservationForTesting(previousDiscovery)

        let currentHeader = element(label: "ButtonHeist Demo", traits: .header)
        let sharedCurrentAction = element(label: "Shared Action", traits: .button)
        let currentVisible = InterfaceObservation.makeForTests(elements: [
            (currentHeader, "buttonheist_demo"),
            (sharedCurrentAction, "shared_action"),
        ])
        await vault.semanticObservationStream.commitVisibleObservationForTesting(currentVisible)

        XCTAssertEqual(vault.viewportElementIDs, ["buttonheist_demo", "shared_action"])
        XCTAssertEqual(vault.interfaceElementIDs, ["buttonheist_demo", "shared_action"])
        XCTAssertNil(vault.interfaceElement(heistId: "controls_demo"))
        XCTAssertNil(vault.interfaceElement(heistId: "stale_offscreen"))
    }

}

@MainActor
private func stateAdmission(for observation: InterfaceObservation) -> Observation.Admission {
    Observation.Admission(
        sourceObservation: observation,
        tripwireSignal: .empty,
        discoveryCommitPolicy: .mergeIntoInterface,
        lineage: .resting,
        scope: .visible,
        notifications: Observation.NotificationSnapshot(
            admittedNotifications: [],
            through: AccessibilityNotificationCursor(sequence: 0),
            scopedScreenChangedThrough: 0
        )!,
        keyboardVisible: nil,
        timestamp: Date(timeIntervalSince1970: 0),
        viewportFrames: observation.tree.viewportFrames,
        geometryTolerance: CoarseFrameComparison.currentGeometryTolerance
    )
}

private func requireCommittedObservation(
    _ result: Result<Observation.Publication, Observation.CaptureFailure>
) -> Observation.Publication {
    switch result {
    case .success(let publication):
        publication
    case .failure(let failure):
        preconditionFailure("Test observation was rejected: \(failure.diagnostic)")
    }
}

private func availableViewSpace(
    ownerPath: TreePath = .root,
    frame: CGRect
) throws -> HeistElement.Geometry.ViewSpace {
    .available(.init(
        ownerPath: ownerPath,
        frame: try ViewRect(validating: frame),
        activationPoint: try ViewPoint(
            validating: CGPoint(x: frame.midX, y: frame.midY)
        )
    ))
}

#endif
