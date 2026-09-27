#if canImport(UIKit)
import XCTest
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@testable import TheScore

/// Tests for `TheVault.buildObservation(from:)`. Validates that a `CaptureResult`
/// is converted into a `InterfaceObservation` value with the current semantics: heistId
/// assignment, scroll membership, first-responder detection, and
/// interface-name derivation.
@MainActor
final class TheVaultObservationBuildingTests: XCTestCase {

    private var vault: TheVault!

    override func setUp() async throws {
        try await super.setUp()
        vault = TheVault(tripwire: TheTripwire())
    }

    override func tearDown() async throws {
        vault = nil
        try await super.tearDown()
    }

    // MARK: - Observation identity

    func testBuildObservationPopulatesHeistIdsByPath() {
        let element = makeElement(label: "OK", traits: .button)
        let result = TheVault.CaptureResult(
            hierarchy: [.element(element, traversalIndex: 0)],
        )

        let observation = TheVault.buildObservation(from: result)

        XCTAssertEqual(observation.tree.viewportCapture.heistId(forPath: TreePath([0])), "ok_button")
    }

    func testBuildObservationKeepsDistinctEntriesForValueEqualElements() {
        let first = makeElement(label: "Item", traits: .button)
        let second = makeElement(label: "Item", traits: .button)
        let result = TheVault.CaptureResult(
            hierarchy: [
                .element(first, traversalIndex: 0),
                .element(second, traversalIndex: 1),
            ],
        )

        let observation = TheVault.buildObservation(from: result)
        let interface = observation.tree.semanticInterface(timestamp: Date())

        // Value-equal elements still get distinct synthesized heistIds because
        // live identity is keyed by tree path, not element value equality.
        XCTAssertEqual(observation.tree.elements.count, 2)
        XCTAssertEqual(Set(observation.tree.elements.keys), ["item_button_1", "item_button_2"])
        XCTAssertEqual(Set(observation.tree.elements.values.map(\.path)), [TreePath([0]), TreePath([1])])
        XCTAssertEqual(interface.annotations.elements.map(\.path), [TreePath([0]), TreePath([1])])
    }

    func testBuildObservationKeepsOffscreenFactsOutOfViewportEvidence() {
        let visible = makeElement(label: "Visible", traits: .button)
        let offscreen = makeElement(
            label: "Offscreen",
            traits: .button,
            visibility: .offscreen
        )
        let result = TheVault.CaptureResult(
            hierarchy: [
                .element(visible, traversalIndex: 0),
                .element(offscreen, traversalIndex: 1),
            ]
        )

        let observation = TheVault.buildObservation(from: result)

        XCTAssertEqual(observation.tree.elementIDs, ["visible_button", "offscreen_button"])
        XCTAssertEqual(observation.tree.viewportElementIDs, ["visible_button"])
        XCTAssertFalse(observation.tree.viewportCapture.contains(heistId: "offscreen_button"))
        XCTAssertEqual(observation.tree.viewportOnly.elementIDs, ["visible_button"])
        XCTAssertNotNil(observation.tree.findElement(heistId: "offscreen_button"))
        guard let visibleGeometry = observation.tree.elements["visible_button"]?.geometry.screen,
              let offscreenGeometry = observation.tree.elements["offscreen_button"]?.geometry.screen
        else {
            return XCTFail("Expected canonical geometry for both retained elements")
        }
        guard case .onscreen = visibleGeometry else {
            return XCTFail("Viewport-captured element must carry visible screen geometry")
        }
        XCTAssertEqual(offscreenGeometry, .offscreen)
    }

    func testBuildObservationAdmitsScrollInventoryOffscreenElementsAsKnownOnly() throws {
        let scrollContainerPath = TreePath([0])
        let visiblePath = scrollContainerPath.appending(0)
        let offscreenPath = scrollContainerPath.appending(1_000_004)
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        let visible = makeElement(label: "Visible", traits: .button)
        let offscreen = makeElement(
            label: "Far Target",
            traits: .button,
            frame: CGRect(x: 40, y: 1_120, width: 220, height: 44),
            activationPoint: CGPoint(x: 150, y: 1_142),
            visibility: .offscreen
        )
        let viewSpace = HeistElement.Geometry.ViewSpace.available(.init(
            ownerPath: scrollContainerPath,
            frame: try ViewRect(validating: CGRect(x: 40, y: 1_120, width: 220, height: 44)),
            activationPoint: try ViewPoint(validating: CGPoint(x: 150, y: 1_142))
        ))
        let result = TheVault.CaptureResult(
            hierarchy: [
                .container(makeScrollableContainer(), children: [
                    .element(visible, traversalIndex: 0)
                ])
            ],
            objectsByPath: [visiblePath: NSObject()],
            containerObjectsByPath: [scrollContainerPath: scrollView],
            scrollViewsByPath: [scrollContainerPath: scrollView],
            inventoryEnumeration: .init(offscreenElements: [
                .init(
                    path: offscreenPath,
                    scrollContainerPath: scrollContainerPath,
                    scrollIndex: 4,
                    element: offscreen,
                    viewSpace: viewSpace
                ),
            ])
        )

        let observation = TheVault.buildObservation(from: result)
        let target = try XCTUnwrap(observation.tree.orderedElements.first {
            $0.element.label == "Far Target"
        })

        XCTAssertEqual(target.path, offscreenPath)
        XCTAssertEqual(
            target.scrollMembership,
            InterfaceTree.ScrollMembership(containerPath: scrollContainerPath, index: 4)
        )
        XCTAssertEqual(target.geometry.view, viewSpace)
        XCTAssertEqual(target.geometry.screen, .offscreen)
        XCTAssertFalse(observation.tree.viewportElementIDs.contains(target.heistId))
        XCTAssertFalse(observation.tree.viewportCapture.contains(heistId: target.heistId))
        XCTAssertNil(observation.liveCapture.object(for: target.heistId))
        XCTAssertEqual(observation.tree.viewportOnly.elementIDs, ["visible_button"])

        let interface = TheVault.WireConversion.discoveryProjection(from: observation.tree).interface
        XCTAssertEqual(
            interface.projectedElements.compactMap(\.semantics.assertable.label),
            ["Visible", "Far Target"]
        )
        XCTAssertEqual(interface.projectedElements.last?.geometry.screen, .offscreen)
        guard case .container(_, let children) = interface.tree.first,
              case .element(let projectedOffscreen, _) = children.last
        else {
            return XCTFail("Expected offscreen inventory element projected under the scroll container")
        }
        XCTAssertEqual(projectedOffscreen.label, "Far Target")
        XCTAssertEqual(projectedOffscreen.visibility, .offscreen)
    }

    func testLaterViewportCaptureReplacesOffscreenScreenGeometry() throws {
        let containerPath = TreePath([0])
        let inventoryPath = containerPath.appending(1_000_000)
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        let offscreen = makeElement(
            label: "Target",
            traits: .button,
            frame: CGRect(x: 20, y: 900, width: 120, height: 44),
            visibility: .offscreen
        )
        let viewSpace = HeistElement.Geometry.ViewSpace.available(.init(
            ownerPath: containerPath,
            frame: try ViewRect(validating: CGRect(x: 20, y: 900, width: 120, height: 44)),
            activationPoint: try ViewPoint(validating: CGPoint(x: 80, y: 922))
        ))
        let retained = TheVault.buildObservation(from: TheVault.CaptureResult(
            hierarchy: [.container(makeScrollableContainer(), children: [])],
            containerObjectsByPath: [containerPath: scrollView],
            scrollViewsByPath: [containerPath: scrollView],
            inventoryEnumeration: .init(offscreenElements: [
                .init(
                    path: inventoryPath,
                    scrollContainerPath: containerPath,
                    scrollIndex: 0,
                    element: offscreen,
                    viewSpace: viewSpace
                ),
            ])
        ))
        let retainedElement = try XCTUnwrap(retained.tree.orderedElements.first)
        XCTAssertEqual(retainedElement.geometry.screen, .offscreen)

        let visible = makeElement(
            label: "Target",
            traits: .button,
            frame: CGRect(x: 20, y: 120, width: 120, height: 44)
        )
        let refreshed = TheVault.buildObservation(from: TheVault.CaptureResult(
            hierarchy: [
                .container(makeScrollableContainer(), children: [
                    .element(visible, traversalIndex: 0),
                ]),
            ],
            scrollViewsByPath: [containerPath: scrollView]
        ))
        let merged = retained.tree.merging(refreshed.tree)
        let refreshedElement = try XCTUnwrap(merged.elements[retainedElement.heistId])

        guard case .onscreen = refreshedElement.geometry.screen else {
            return XCTFail("A later viewport capture must replace offscreen screen geometry")
        }
    }

    func testCaptureInvalidatesIncompleteParentGeometry() throws {
        let ownerPath = TreePath([0])
        let element = makeElement(
            label: "Boundary Target",
            traits: .button,
            frame: CGRect(x: 20, y: 120, width: 120, height: 44),
            activationPoint: CGPoint(x: 80, y: 142)
        )

        for invalidComponent in ParentGeometryConversionScrollView.InvalidComponent.allCases {
            let scrollView = ParentGeometryConversionScrollView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 400),
                parentFrame: CGRect(x: 20, y: 900, width: 120, height: 44),
                parentActivationPoint: CGPoint(x: 80, y: 922),
                invalidComponent: invalidComponent
            )
            let observation = buildScrollObservation(
                element: element,
                scrollView: scrollView,
                ownerPath: ownerPath
            )
            let captured = try XCTUnwrap(observation.tree.orderedElements.first)

            XCTAssertEqual(
                captured.geometry.view,
                .invalidated(ownerPath: ownerPath),
                "A failed \(invalidComponent) conversion must invalidate the complete parent geometry"
            )
        }
    }

    func testViewportMovementPreservesParentSpaceGeometry() throws {
        let ownerPath = TreePath([0])
        let parentFrame = CGRect(x: 24, y: 900, width: 160, height: 44)
        let parentActivationPoint = CGPoint(x: 104, y: 922)
        let scrollView = ParentGeometryConversionScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400),
            parentFrame: parentFrame,
            parentActivationPoint: parentActivationPoint
        )
        let before = buildScrollObservation(
            element: makeElement(
                label: "Moving Target",
                traits: .button,
                frame: CGRect(x: 24, y: 260, width: 160, height: 44),
                activationPoint: CGPoint(x: 104, y: 282)
            ),
            scrollView: scrollView,
            ownerPath: ownerPath
        )
        let after = buildScrollObservation(
            element: makeElement(
                label: "Moving Target",
                traits: .button,
                frame: CGRect(x: 24, y: 80, width: 160, height: 44),
                activationPoint: CGPoint(x: 104, y: 102)
            ),
            scrollView: scrollView,
            ownerPath: ownerPath
        )
        let heistId = try XCTUnwrap(before.tree.orderedElements.first?.heistId)
        let beforeGeometry = try XCTUnwrap(before.tree.elements[heistId]?.geometry)
        let updated = before.tree.updatingViewport(with: after.tree)
        let afterGeometry = try XCTUnwrap(updated.elements[heistId]?.geometry)

        XCTAssertNotEqual(beforeGeometry.screen, afterGeometry.screen)
        XCTAssertEqual(beforeGeometry.view, afterGeometry.view)
        XCTAssertEqual(
            afterGeometry.view,
            .available(.init(
                ownerPath: ownerPath,
                frame: try ViewRect(validating: parentFrame),
                activationPoint: try ViewPoint(validating: parentActivationPoint)
            ))
        )
    }

    func testLayoutRefreshReplacesParentGeometryAtomically() throws {
        let ownerPath = TreePath([0])
        let initialParentFrame = CGRect(x: 24, y: 900, width: 160, height: 44)
        let initialParentPoint = CGPoint(x: 104, y: 922)
        let refreshedParentFrame = CGRect(x: 40, y: 1_040, width: 220, height: 60)
        let refreshedParentPoint = CGPoint(x: 150, y: 1_070)
        let scrollView = ParentGeometryConversionScrollView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 400),
            parentFrame: initialParentFrame,
            parentActivationPoint: initialParentPoint
        )
        let element = makeElement(
            label: "Layout Target",
            traits: .button,
            frame: CGRect(x: 24, y: 120, width: 160, height: 44),
            activationPoint: CGPoint(x: 104, y: 142)
        )
        let initial = buildScrollObservation(
            element: element,
            scrollView: scrollView,
            ownerPath: ownerPath
        )
        let heistId = try XCTUnwrap(initial.tree.orderedElements.first?.heistId)
        let invalidated = initial.tree.invalidatingParentSpaceGeometry()

        scrollView.parentFrame = refreshedParentFrame
        scrollView.parentActivationPoint = refreshedParentPoint
        let refresh = buildScrollObservation(
            element: element,
            scrollView: scrollView,
            ownerPath: ownerPath
        )
        let restored = invalidated.updatingViewport(with: refresh.tree)

        XCTAssertEqual(
            initial.tree.elements[heistId]?.geometry.view,
            .available(.init(
                ownerPath: ownerPath,
                frame: try ViewRect(validating: initialParentFrame),
                activationPoint: try ViewPoint(validating: initialParentPoint)
            ))
        )
        XCTAssertEqual(
            invalidated.elements[heistId]?.geometry.view,
            .invalidated(ownerPath: ownerPath)
        )
        XCTAssertEqual(
            restored.elements[heistId]?.geometry.view,
            .available(.init(
                ownerPath: ownerPath,
                frame: try ViewRect(validating: refreshedParentFrame),
                activationPoint: try ViewPoint(validating: refreshedParentPoint)
            ))
        )
    }

    func testScrollInventoryDuplicateIdsFollowScrollMembershipAcrossViewportReordering() throws {
        let scrollContainerPath = TreePath([0])
        let workHighObject = NSObject()
        let workLowObject = NSObject()
        let homeHighObject = NSObject()
        let scrollView = ObservationInventoryScrollView(elements: [
            workHighObject,
            workLowObject,
            homeHighObject,
        ])
        scrollView.contentSize = CGSize(width: 320, height: 1_600)

        let workHigh = duplicateReviewElement(category: "Work", priority: "High", value: "Active")
        let workLow = duplicateReviewElement(category: "Work", priority: "Low", value: "Active")
        let workLowOffscreen = duplicateReviewElement(
            category: "Work",
            priority: "Low",
            value: "Active",
            visibility: .offscreen
        )
        let homeHighOffscreen = duplicateReviewElement(
            category: "Home",
            priority: "High",
            value: "Active",
            visibility: .offscreen
        )
        let initialObservation = TheVault.buildObservation(from: TheVault.CaptureResult(
            hierarchy: [
                .container(makeScrollableContainer(), children: [
                    .element(workHigh, traversalIndex: 0),
                ]),
            ],
            objectsByPath: [scrollContainerPath.appending(0): workHighObject],
            scrollViewsByPath: [scrollContainerPath: scrollView],
            inventoryEnumeration: .init(offscreenElements: [
                offscreenScrollElement(workLowOffscreen, containerPath: scrollContainerPath, index: 1),
                offscreenScrollElement(homeHighOffscreen, containerPath: scrollContainerPath, index: 2),
            ])
        ))
        let initialWorkHighId = try XCTUnwrap(reviewID(
            in: initialObservation,
            category: "Work",
            priority: "High"
        ))

        let reorderedWorkLowPath = scrollContainerPath.appending(0)
        let reorderedWorkHighPath = scrollContainerPath.appending(1)
        let reorderedObservation = TheVault.buildObservation(from: TheVault.CaptureResult(
            hierarchy: [
                .container(makeScrollableContainer(), children: [
                    .element(workLow, traversalIndex: 0),
                    .element(workHigh, traversalIndex: 1),
                ]),
            ],
            objectsByPath: [
                reorderedWorkLowPath: workLowObject,
                reorderedWorkHighPath: workHighObject,
            ],
            scrollViewsByPath: [scrollContainerPath: scrollView],
            inventoryEnumeration: .init(offscreenElements: [
                offscreenScrollElement(homeHighOffscreen, containerPath: scrollContainerPath, index: 2),
            ])
        ))

        XCTAssertEqual(initialWorkHighId, "review_pr_button_1")
        XCTAssertEqual(
            reviewID(in: reorderedObservation, category: "Work", priority: "High"),
            initialWorkHighId
        )
        XCTAssertEqual(
            reorderedObservation.tree.viewportCapture.heistId(forPath: reorderedWorkHighPath),
            initialWorkHighId
        )
        XCTAssertEqual(
            reviewID(in: reorderedObservation, category: "Work", priority: "Low"),
            "review_pr_button_2"
        )
    }

    // MARK: - First responder detection

    func testDetectsFirstResponder() async {
        let textField = UITextField()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        window.addSubview(textField)
        window.makeKeyAndVisible()
        textField.becomeFirstResponder()

        let element = makeElement(label: "Email", traits: .none)
        let result = TheVault.CaptureResult(
            hierarchy: [.element(element, traversalIndex: 0)],
            objectsByPath: [TreePath([0]): textField],
        )

        let observation = TheVault.buildObservation(from: result)

        XCTAssertNotNil(observation.tree.viewportCapture.firstResponderHeistId)

        textField.resignFirstResponder()
        window.isHidden = true
        await KeyboardWindowTestHelpers.waitForKeyboardWindowsToRetire()
    }

    func testFirstResponderNilWhenNoneActive() {
        let element = makeElement(label: "Label")
        let label = UILabel()
        let result = TheVault.CaptureResult(
            hierarchy: [.element(element, traversalIndex: 0)],
            objectsByPath: [TreePath([0]): label],
        )

        let observation = TheVault.buildObservation(from: result)

        XCTAssertNil(observation.tree.viewportCapture.firstResponderHeistId)
    }

    func testBuildObservationUsesSyntheticFirstResponderFacts() {
        let first = makeElement(label: "Email")
        let second = makeElement(label: "Password")
        let firstPath = TreePath([0])
        let secondPath = TreePath([1])
        let result = TheVault.CaptureResult(
            hierarchy: [
                .element(first, traversalIndex: 0),
                .element(second, traversalIndex: 1),
            ],
            objectsByPath: [
                firstPath: NSObject(),
                secondPath: NSObject(),
            ]
        )
        let facts = TheVault.BuildFacts(
            focus: TheVault.FocusFacts(firstResponderPaths: [secondPath])
        )

        let observation = TheVault.buildObservation(from: result, facts: facts)

        XCTAssertEqual(
            observation.tree.viewportCapture.firstResponderHeistId,
            observation.tree.viewportCapture.heistId(forPath: secondPath)
        )
    }

    func testElementOrderDerivesFromHierarchyTraversalIndex() {
        let first = makeElement(label: "Row", traits: .button,
                                frame: CGRect(x: 0, y: 0, width: 100, height: 44))
        let second = makeElement(label: "Row", traits: .button,
                                 frame: CGRect(x: 0, y: 50, width: 100, height: 44))
        let result = TheVault.CaptureResult(
            hierarchy: [
                .element(second, traversalIndex: 1),
                .element(first, traversalIndex: 0),
            ],
        )

        let observation = TheVault.buildObservation(from: result)

        XCTAssertEqual(observation.tree.viewportCapture.heistId(forPath: TreePath([1])), "row_button_1")
        XCTAssertEqual(observation.tree.viewportCapture.heistId(forPath: TreePath([0])), "row_button_2")
    }

    func testBuildObservationRestoresScreenCoordinateGeometryFromParseRootOffset() throws {
        let parseRootOffset = CGPoint(x: 180, y: 24)
        let rootLocalFrame = CGRect(x: 64, y: 372, width: 155, height: 72)
        let screenFrame = rootLocalFrame.offsetBy(dx: parseRootOffset.x, dy: parseRootOffset.y)
        let rootLocalActivationPoint = CGPoint(x: 141.5, y: 408)
        let screenActivationPoint = CGPoint(
            x: rootLocalActivationPoint.x + parseRootOffset.x,
            y: rootLocalActivationPoint.y + parseRootOffset.y
        )
        let parsedElement = makeElement(
            label: "Confirm",
            traits: .button,
            frame: rootLocalFrame,
            activationPoint: rootLocalActivationPoint
        )

        let result = TheVault.CaptureResult(
            hierarchy: [.element(parsedElement, traversalIndex: 0)],
            rootScreenSpacesByPath: [TreePath([0]): .init(
                offset: parseRootOffset,
                bounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
            )]
        )

        let observation = TheVault.buildObservation(from: result)
        let element = try XCTUnwrap(observation.tree.viewportCapture.hierarchy.sortedElements.first)
        let treeElement = try XCTUnwrap(observation.tree.orderedElements.first)
        let projected = TheVault.WireConversion.convert(
            element,
            geometry: treeElement.geometry
        )

        XCTAssertEqual(element.shape.frame, screenFrame)
        XCTAssertEqual(element.bhResolvedActivationPoint, screenActivationPoint)
        guard case .onscreen(let frame, let activationPoint) = projected.geometry.screen else {
            return XCTFail("Expected restored screen geometry")
        }
        XCTAssertEqual(frame.rect?.cgRect, screenFrame)
        XCTAssertEqual(activationPoint.point?.cgPoint, screenActivationPoint)
        XCTAssertEqual(projected.geometry, treeElement.geometry)
    }

    func testBuildObservationAdmitsPresentedRootElementOnlyAfterItEntersScreen() throws {
        let rootPath = TreePath([0])
        let screenBounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let rootLocalFrame = CGRect(x: 120, y: 100, width: 160, height: 44)
        let parsedElement = makeElement(
            label: "Dismiss",
            traits: .button,
            frame: rootLocalFrame
        )
        let liveObject = NSObject()

        let transitioning = TheVault.buildObservation(from: TheVault.CaptureResult(
            hierarchy: [.element(parsedElement, traversalIndex: 0)],
            objectsByPath: [rootPath: liveObject],
            rootScreenSpacesByPath: [rootPath: .init(
                offset: CGPoint(x: 0, y: 900),
                bounds: screenBounds
            )]
        ))
        let transitioningElement = try XCTUnwrap(
            transitioning.tree.viewportCapture.hierarchy.sortedElements.first
        )
        let transitioningTreeElement = try XCTUnwrap(transitioning.tree.orderedElements.first)

        XCTAssertEqual(transitioningElement.visibility, .offscreen)
        XCTAssertEqual(transitioningTreeElement.geometry.screen, .offscreen)
        XCTAssertFalse(transitioning.tree.viewportCapture.contains(
            heistId: transitioningTreeElement.heistId
        ))
        XCTAssertNil(transitioning.liveCapture.object(for: transitioningTreeElement.heistId))

        let settled = TheVault.buildObservation(from: TheVault.CaptureResult(
            hierarchy: [.element(parsedElement, traversalIndex: 0)],
            objectsByPath: [rootPath: liveObject],
            rootScreenSpacesByPath: [rootPath: .init(
                offset: CGPoint(x: 0, y: 500),
                bounds: screenBounds
            )]
        ))
        let settledElement = try XCTUnwrap(settled.tree.viewportCapture.hierarchy.sortedElements.first)
        let settledTreeElement = try XCTUnwrap(settled.tree.orderedElements.first)

        XCTAssertEqual(settledElement.visibility, .onscreen)
        guard case .onscreen = settledTreeElement.geometry.screen else {
            return XCTFail("Expected settled presentation geometry to be on screen")
        }
        XCTAssertTrue(settled.tree.viewportCapture.contains(heistId: settledTreeElement.heistId))
        XCTAssertTrue(settled.liveCapture.object(for: settledTreeElement.heistId) === liveObject)
    }

    func testBuildObservationRestoresPathGeometryFromParseRootOffset() throws {
        let parseRootOffset = CGPoint(x: 20, y: 30)
        let pathElement = AccessibilityElement(
            description: "Path Button",
            label: "Path Button",
            value: nil,
            traits: .button,
            identifier: nil,
            hint: nil,
            userInputLabels: nil,
            shape: .path([
                .move(to: AccessibilityPoint(x: 10, y: 10)),
                .line(to: AccessibilityPoint(x: 50, y: 10)),
                .quadCurve(
                    to: AccessibilityPoint(x: 50, y: 50),
                    control: AccessibilityPoint(x: 60, y: 25)
                ),
            ]),
            activationPoint: AccessibilityPoint(x: 30, y: 30),
            usesDefaultActivationPoint: false,
            customActions: [],
            customContent: [],
            customRotors: [],
            accessibilityLanguage: nil,
            respondsToUserInteraction: true
        )
        let result = TheVault.CaptureResult(
            hierarchy: [.element(pathElement, traversalIndex: 0)],
            rootScreenSpacesByPath: [TreePath([0]): .init(
                offset: parseRootOffset,
                bounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
            )]
        )

        let observation = TheVault.buildObservation(from: result)
        let translated = try XCTUnwrap(observation.tree.viewportCapture.hierarchy.sortedElements.first)

        guard case .path(let elements) = translated.shape else {
            return XCTFail("Expected translated path")
        }
        XCTAssertEqual(elements.first, .move(to: AccessibilityPoint(x: 30, y: 40)))
        XCTAssertEqual(translated.bhResolvedActivationPoint, CGPoint(x: 50, y: 60))
    }

    func testBuildObservationTranslationPreservesContainerFacts() throws {
        let parseRootOffset = CGPoint(x: 12, y: 34)
        let containerPath = TreePath([0])
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 80, width: 320, height: 400))
        scrollView.contentSize = CGSize(width: 320, height: 1200)
        let containerFrame = CGRect(x: 0, y: 80, width: 320, height: 400)
        let container = AccessibilityContainer(
            type: .none,
            identifier: "checkout-scroll",
            scrollableContentSize: AccessibilitySize(scrollView.contentSize),
            frame: AccessibilityRect(containerFrame),
            isModalBoundary: true,
            customActions: [AccessibilityElement.CustomAction(name: "Archive")]
        )
        let child = makeElement(
            label: "Checkout",
            traits: .button,
            frame: CGRect(x: 24, y: 160, width: 140, height: 44)
        )
        let result = TheVault.CaptureResult(
            hierarchy: [.container(container, children: [.element(child, traversalIndex: 0)])],
            scrollViewsByPath: [containerPath: scrollView],
            rootScreenSpacesByPath: [containerPath: .init(
                offset: parseRootOffset,
                bounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
            )]
        )

        let observation = TheVault.buildObservation(from: result)
        let translated = try XCTUnwrap(observation.tree.viewportCapture.hierarchy.first)
        guard case .container(let translatedContainer, _) = translated else {
            return XCTFail("Expected translated container")
        }

        XCTAssertEqual(translatedContainer.type, .none)
        XCTAssertEqual(translatedContainer.identifier, "checkout-scroll")
        XCTAssertEqual(translatedContainer.scrollableContentSize, AccessibilitySize(scrollView.contentSize))
        XCTAssertEqual(translatedContainer.isModalBoundary, true)
        XCTAssertEqual(translatedContainer.customActions, [AccessibilityElement.CustomAction(name: "Archive")])
        XCTAssertEqual(translatedContainer.frame.cgRect, containerFrame.offsetBy(dx: 12, dy: 34))
        XCTAssertNotNil(observation.liveCapture.scrollView(forContainerPath: containerPath))
    }

    // MARK: - Scroll membership

    func testViewSpaceAdmitsOnlyMatchingOwner() throws {
        let ownerPath = TreePath([0, 1])
        let frame = try ViewRect(validating: CGRect(x: 60, y: 618, width: 120, height: 44))
        let point = try ViewPoint(validating: CGPoint(x: 120, y: 640))
        let viewSpace = HeistElement.Geometry.ViewSpace.available(.init(
            ownerPath: ownerPath,
            frame: frame,
            activationPoint: point
        ))

        XCTAssertEqual(viewSpace.admitted(ownedBy: ownerPath), viewSpace)
        XCTAssertEqual(
            viewSpace.admitted(ownedBy: TreePath([0])),
            .invalidated(ownerPath: TreePath([0]))
        )
        XCTAssertEqual(
            viewSpace.admitted(ownedBy: TreePath([0, 2])),
            .invalidated(ownerPath: TreePath([0, 2]))
        )
    }

    func testObservedContentPointsCarryProducingContainerPath() throws {
        let outerPath = TreePath([0])
        let viewportElementPath = TreePath([0, 0])
        let nestedPath = TreePath([0, 1])
        let outerScrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        outerScrollView.contentSize = CGSize(width: 320, height: 2_000)
        let offscreenElement = UIAccessibilityElement(accessibilityContainer: NSObject())
        offscreenElement.accessibilityLabel = "Offscreen"
        offscreenElement.accessibilityTraits = .button
        offscreenElement.accessibilityFrame = CGRect(x: 20, y: 900, width: 160, height: 44)
        offscreenElement.accessibilityActivationPoint = CGPoint(x: 100, y: 922)
        let nestedScrollView = ObservationInventoryScrollView(element: offscreenElement)
        nestedScrollView.frame = CGRect(x: 0, y: 500, width: 320, height: 300)
        nestedScrollView.contentSize = CGSize(width: 320, height: 1_600)
        let viewportElement = makeElement(
            label: "Viewport",
            traits: .button,
            frame: CGRect(x: 20, y: 120, width: 160, height: 44),
            activationPoint: CGPoint(x: 100, y: 142)
        )
        let inventory = vault.enumerateOffscreenScrollInventory(
            objectsByPath: [:],
            scrollViewsByPath: [nestedPath: nestedScrollView],
            budget: 1
        )
        XCTAssertEqual(inventory.offscreenElements.count, 1)
        let offscreenViewSpace = try XCTUnwrap(
            inventory.offscreenElements.first?.viewSpace
        )
        let result = TheVault.CaptureResult(
            hierarchy: [
                .container(makeScrollableContainer(), children: [
                    .element(viewportElement, traversalIndex: 0),
                    .container(
                        makeScrollableContainer(
                            frame: CGRect(x: 0, y: 500, width: 320, height: 300)
                        ),
                        children: []
                    ),
                ]),
            ],
            scrollViewsByPath: [
                outerPath: outerScrollView,
                nestedPath: nestedScrollView,
            ]
        )

        let observation = TheVault.buildObservation(from: result)
        let viewportHeistId = try XCTUnwrap(observation.tree.viewportCapture.heistId(forPath: viewportElementPath))
        let viewportViewSpace = try XCTUnwrap(
            observation.tree.elements[viewportHeistId]?.geometry.view
        )
        let nestedViewSpace = try XCTUnwrap(
            observation.tree.containers[nestedPath]?.viewSpace
        )
        XCTAssertEqual(viewportViewSpace.ownerPath, outerPath)
        XCTAssertEqual(nestedViewSpace.ownerPath, outerPath)
        XCTAssertEqual(offscreenViewSpace.ownerPath, nestedPath)
    }

    func testPropagatesScrollMembershipForScrollableContainerChild() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 100, width: 320, height: 500))
        scrollView.contentSize = CGSize(width: 320, height: 2000)

        let scrollableContainer = AccessibilityContainer(
            type: .none, scrollableContentSize: AccessibilitySize(scrollView.contentSize),
            frame: AccessibilityRect(scrollView.frame)
        )
        let childFrame = CGRect(x: 10, y: 150, width: 50, height: 30)
        let child = makeElement(label: "Cell", traits: .button, frame: childFrame)

        let result = TheVault.CaptureResult(
            hierarchy: [.container(scrollableContainer, children: [.element(child, traversalIndex: 0)])],
            scrollViewsByPath: [TreePath([0]): scrollView]
        )

        let observation = TheVault.buildObservation(from: result)
        guard let heistId = observation.tree.elements.keys.first else {
            XCTFail("Expected one heistId")
            return
        }

        XCTAssertEqual(observation.tree.findElement(heistId: heistId)?.scrollMembership?.containerPath, TreePath([0]))
    }

    func testLeavesScrollMembershipNilOutsideScrollableContainer() {
        let element = makeElement(label: "Plain",
                                  frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        let result = TheVault.CaptureResult(
            hierarchy: [.element(element, traversalIndex: 0)]
        )

        let observation = TheVault.buildObservation(from: result)
        guard let heistId = observation.tree.elements.keys.first else {
            XCTFail("Expected one heistId")
            return
        }

        XCTAssertNil(observation.tree.findElement(heistId: heistId)?.scrollMembership)
    }

    func testBuildObservationUsesSyntheticScrollFactsForPureProjection() throws {
        let scrollPath = TreePath([0])
        let nestedContainerPath = TreePath([0, 0])
        let childPath = TreePath([0, 0, 0])
        let scrollableContainer = AccessibilityContainer(
            type: .none, scrollableContentSize: AccessibilitySize(width: 320, height: 2000),
            frame: AccessibilityRect(x: 0, y: 0, width: 320, height: 500)
        )
        let nestedContainer = AccessibilityContainer(
            type: .list,
            frame: AccessibilityRect(x: 0, y: 150, width: 320, height: 100)
        )
        let child = makeElement(
            label: "Cell",
            traits: .button,
            frame: CGRect(x: 10, y: 160, width: 120, height: 44)
        )
        let elementViewSpace = HeistElement.Geometry.ViewSpace.available(.init(
            ownerPath: scrollPath,
            frame: try ViewRect(validating: child.bhFrame),
            activationPoint: try ViewPoint(validating: CGPoint(x: 70, y: 180))
        ))
        let containerViewSpace = HeistElement.Geometry.ViewSpace.available(.init(
            ownerPath: scrollPath,
            frame: try ViewRect(validating: nestedContainer.frame.cgRect),
            activationPoint: try ViewPoint(validating: CGPoint(x: 160, y: 200))
        ))
        let inventory = try XCTUnwrap(
            ScrollInventory(totalElementCount: 20)
        )
        let result = TheVault.CaptureResult(
            hierarchy: [
                .container(scrollableContainer, children: [
                    .container(nestedContainer, children: [
                        .element(child, traversalIndex: 0),
                    ]),
                ]),
            ]
        )
        let facts = TheVault.BuildFacts(
            scroll: TheVault.ScrollFacts(
                contextContainerPaths: [scrollPath],
                elementsByPath: [
                    childPath: TheVault.ElementScrollFacts(
                        containerPath: scrollPath,
                        index: 7,
                        viewSpace: elementViewSpace
                    ),
                ],
                containerViewSpacesByPath: [
                    nestedContainerPath: containerViewSpace,
                ],
                inventoriesByPath: [scrollPath: inventory]
            )
        )

        let observation = TheVault.buildObservation(from: result, facts: facts)
        let heistId = try XCTUnwrap(observation.tree.viewportCapture.heistId(forPath: childPath))
        let element = try XCTUnwrap(observation.tree.findElement(heistId: heistId))

        XCTAssertEqual(
            element.scrollMembership,
            InterfaceTree.ScrollMembership(containerPath: scrollPath, index: 7)
        )
        XCTAssertEqual(element.geometry.view, elementViewSpace)
        XCTAssertEqual(observation.tree.containers[scrollPath]?.scrollInventory, inventory)
        XCTAssertEqual(
            observation.tree.containers[nestedContainerPath]?.scrollMembership,
            InterfaceTree.ScrollMembership(containerPath: scrollPath, index: nil)
        )
        XCTAssertEqual(
            observation.tree.containers[nestedContainerPath]?.viewSpace,
            containerViewSpace
        )
    }

    // MARK: - Helpers

    private func makeElement(
        label: String? = nil,
        value: String? = nil,
        traits: UIAccessibilityTraits = .none,
        frame: CGRect = .zero,
        activationPoint: CGPoint? = nil,
        customActions: [AccessibilityElement.CustomAction] = [],
        customContent: [AccessibilityElement.CustomContent] = [],
        visibility: AccessibilityVisibility = .onscreen
    ) -> AccessibilityElement {
        .make(
            label: label,
            value: value,
            traits: traits,
            shape: .frame(AccessibilityRect(frame)),
            activationPoint: activationPoint,
            customActions: customActions,
            customContent: customContent,
            respondsToUserInteraction: false,
            visibility: visibility
        )
    }

    private func buildScrollObservation(
        element: AccessibilityElement,
        scrollView: UIScrollView,
        ownerPath: TreePath
    ) -> InterfaceObservation {
        scrollView.contentSize = CGSize(width: 320, height: 1_600)
        return TheVault.buildObservation(from: TheVault.CaptureResult(
            hierarchy: [
                .container(makeScrollableContainer(), children: [
                    .element(element, traversalIndex: 0),
                ]),
            ],
            scrollViewsByPath: [ownerPath: scrollView]
        ))
    }

    private func duplicateReviewElement(
        category: String,
        priority: String,
        value: String,
        visibility: AccessibilityVisibility = .onscreen
    ) -> AccessibilityElement {
        makeElement(
            label: "Review PR",
            value: value,
            traits: .button,
            customActions: [.init(name: "Toggle")],
            customContent: [
                .init(label: "Category", value: category, isImportant: true),
                .init(label: "Priority", value: priority, isImportant: true),
            ],
            visibility: visibility
        )
    }

    private func offscreenScrollElement(
        _ element: AccessibilityElement,
        containerPath: TreePath,
        index: Int
    ) -> TheVault.OffscreenScrollElement {
        TheVault.OffscreenScrollElement(
            path: containerPath.appending(1_000_000 + index),
            scrollContainerPath: containerPath,
            scrollIndex: index,
            element: element,
            viewSpace: HeistElement.Geometry.ViewSpace.admit(
                ownerPath: containerPath,
                frame: try? ViewRect(validating: element.bhFrame),
                activationPoint: try? ViewPoint(validating: element.bhResolvedActivationPoint)
            )
        )
    }

    private func reviewID(
        in observation: InterfaceObservation,
        category: String,
        priority: String
    ) -> HeistId? {
        observation.tree.elements.values.first { element in
            guard element.element.label == "Review PR" else { return false }
            let customContent = element.element.customContent
            return customContent.contains {
                $0.label == "Category" && $0.value == category
            } && customContent.contains {
                $0.label == "Priority" && $0.value == priority
            }
        }?.heistId
    }

    private func makeScrollableContainer(
        contentSize: CGSize = CGSize(width: 320, height: 1_600),
        frame: CGRect = CGRect(x: 0, y: 0, width: 320, height: 400)
    ) -> AccessibilityContainer {
        AccessibilityContainer(
            type: .none,
            scrollableContentSize: AccessibilitySize(contentSize),
            frame: AccessibilityRect(frame)
        )
    }
}

@MainActor
private final class ObservationInventoryScrollView: UIScrollView {
    private let elements: [NSObject]

    convenience init(element: NSObject) {
        self.init(elements: [element])
    }

    init(elements: [NSObject]) {
        self.elements = elements
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func accessibilityElementCount() -> Int {
        elements.count
    }

    override func accessibilityElement(at index: Int) -> Any? {
        elements.indices.contains(index) ? elements[index] : nil
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        guard let object = element as? NSObject else { return NSNotFound }
        return elements.firstIndex { $0 === object } ?? NSNotFound
    }
}

@MainActor
private final class ParentGeometryConversionScrollView: UIScrollView {
    enum InvalidComponent: String, CaseIterable {
        case frame
        case activationPoint
    }

    var parentFrame: CGRect
    var parentActivationPoint: CGPoint
    let invalidComponent: InvalidComponent?

    init(
        frame: CGRect,
        parentFrame: CGRect,
        parentActivationPoint: CGPoint,
        invalidComponent: InvalidComponent? = nil
    ) {
        self.parentFrame = parentFrame
        self.parentActivationPoint = parentActivationPoint
        self.invalidComponent = invalidComponent
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func convert(_ rect: CGRect, from view: UIView?) -> CGRect {
        guard invalidComponent != .frame else {
            return CGRect(
                x: CGFloat.nan,
                y: parentFrame.minY,
                width: parentFrame.width,
                height: parentFrame.height
            )
        }
        return parentFrame
    }

    override func convert(_ point: CGPoint, from view: UIView?) -> CGPoint {
        guard invalidComponent != .activationPoint else {
            return CGPoint(x: CGFloat.nan, y: parentActivationPoint.y)
        }
        return parentActivationPoint
    }
}

#endif
