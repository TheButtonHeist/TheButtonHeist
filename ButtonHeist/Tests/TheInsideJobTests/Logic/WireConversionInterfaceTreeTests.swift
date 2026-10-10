#if canImport(UIKit)
import ButtonHeistTestSupport
import XCTest
import ThePlans
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@testable import TheScore

@MainActor
extension WireConverterTests {
    private func interfaceTreeViewSpace(
        for container: AccessibilityContainer,
        ownerPath: TreePath = .root
    ) -> HeistElement.Geometry.ViewSpace {
        let frame = container.frame.cgRect
        guard let viewFrame = try? ViewRect(validating: frame),
              let activationPoint = try? ViewPoint(
                  validating: CGPoint(x: frame.midX, y: frame.midY)
              ) else {
            return .invalidated(ownerPath: ownerPath)
        }
        return .available(.init(
            ownerPath: ownerPath,
            frame: viewFrame,
            activationPoint: activationPoint
        ))
    }

    // MARK: - Tree Conversion

    func testToWireTreePreservesParserModalBoundary() async throws {
        let element = makeElement(label: "Confirm", traits: [.button])
        let container = AccessibilityContainer(
            type: .semanticGroup(label: "Alert", value: nil), identifier: nil,
            frame: .zero,
            isModalBoundary: true
        )
        let parse = TheVault.CaptureTree(
            hierarchy: [.container(container, children: [.element(element, traversalIndex: 0)])],
        )
        let screen = TheVault.buildObservation(from: parse)

        let tree = screen.tree.semanticInterface(timestamp: Date()).tree

        guard case .container(let info, _) = tree.first else {
            return XCTFail("Expected container root")
        }
        XCTAssertTrue(info.isModalBoundary)
    }

    func testSemanticInterfaceAnnotatesTraceIdentityFromHeistIds() async throws {
        let path = TreePath([0])
        let element = makeElement(
            label: "Checkout",
            traits: [.button],
            respondsToUserInteraction: true
        )
        let geometry = testGeometry(
            for: element,
            ownerPath: .root,
            screen: TheVault.onscreenSpace(for: element)
        )
        let treeElement = InterfaceTree.Element(
            heistId: "checkout_button",
            path: path,
            scrollMembership: nil,
            geometry: geometry,
            element: element
        )
        let screen = InterfaceObservation.makeForTests(
            elements: ["checkout_button": treeElement],
            hierarchy: [.element(treeElement.element, traversalIndex: 0)],
            heistIdsByPath: [path: "checkout_button"],
            firstResponderHeistId: nil
        )

        let interface = screen.tree.semanticInterface(timestamp: Date())
        let record = try XCTUnwrap(interface.projectedElementRecords.single)

        XCTAssertEqual(
            record.element,
            HeistElement(
                semantics: WireConversion.semantics(element),
                geometry: geometry
            )
        )
        XCTAssertEqual(record.observationIdentity, HeistId(rawValue: "checkout_button").observationElementIdentity)
    }

    func testSemanticInterfacePreservesContainersWhenKnownElementsShareParserPath() async throws {
        let containerPath = TreePath([0])
        let recycledElementPath = TreePath([0, 0])
        let containerIdentifier = "SquareCheckoutAppletCore.OrderEntryContainerViewController"
        let container = AccessibilityContainer(
            type: .none, identifier: containerIdentifier,
            frame: AccessibilityRect(CGRect(x: 0, y: 0, width: 320, height: 480))
        )
        let first = makeElement(label: "First row", traits: [.staticText])
        let second = makeElement(label: "Second row", traits: [.staticText])
        let screen = InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: [
                    "first_row_staticText": InterfaceTree.Element(
                        heistId: "first_row_staticText",
                        path: recycledElementPath,
                        scrollMembership: nil,
                        geometry: testGeometry(
                            for: first,
                            ownerPath: .root,
                            screen: .offscreen
                        ),
                        element: first
                    ),
                    "second_row_staticText": InterfaceTree.Element(
                        heistId: "second_row_staticText",
                        path: recycledElementPath,
                        scrollMembership: nil,
                        geometry: testGeometry(
                            for: second,
                            ownerPath: .root,
                            screen: TheVault.onscreenSpace(for: second)
                        ),
                        element: second
                    ),
                ],
                containers: [
                    containerPath: InterfaceTree.Container(
                        container: container,
                        path: containerPath,
                        containerName: "container_order_entry",
                        viewSpace: interfaceTreeViewSpace(for: container)
                    ),
                ],
                viewportCapture: .init(
                    hierarchy: [.container(container, children: [
                        .element(second, traversalIndex: 0),
                    ])],
                    heistIdsByPath: [recycledElementPath: "second_row_staticText"]
                )
            ),
            liveCapture: LiveCapture.makeForTests()
        )

        let interface = screen.tree.semanticInterface(timestamp: Date())
        let expression = AccessibilityPredicate.exists(.container(.identifier(containerIdentifier)))
        let predicate = try expression.resolve(in: .empty)
        let snapshot = Observation.Snapshot(interface: interface, context: .empty)
        let evidence = Observation.Evidence(
            baseline: snapshot,
            events: [],
            current: snapshot,
            coverage: .complete
        )
        let result = try predicate.evaluate(in: evidence)

        XCTAssertEqual(result, PredicateEvaluationResult(met: true))
        XCTAssertEqual(
            interface.projectedElements.compactMap(\.semantics.assertable.label),
            ["Second row", "First row"]
        )
        XCTAssertEqual(
            interface.projectedElements.map(\.geometry.screen),
            [TheVault.onscreenSpace(for: second), .offscreen]
        )
    }

    func testSemanticInterfaceDensifiesSparseContainerPathsBeforeValidation() async throws {
        let rootPath = TreePath([0])
        let splitPath = TreePath([0, 2])
        let orderPath = TreePath([0, 2, 63])
        let libraryPath = TreePath([0, 2, 63, 83])
        let rowPath = TreePath([0, 2, 63, 83, 10])
        let orderIdentifier = "SquareCheckoutAppletCore.OrderEntryContainerViewController"
        let root = AccessibilityContainer(
            type: .none, identifier: "RGUIStatusBarContentViewController",
            frame: AccessibilityRect(CGRect(x: 0, y: 0, width: 1_024, height: 768))
        )
        let split = AccessibilityContainer(
            type: .none, identifier: "MarketUI.MarketSplitViewController",
            frame: AccessibilityRect(CGRect(x: 0, y: 0, width: 1_024, height: 768))
        )
        let order = AccessibilityContainer(
            type: .none, identifier: orderIdentifier,
            frame: AccessibilityRect(CGRect(x: 0, y: 0, width: 1_024, height: 768))
        )
        let library = AccessibilityContainer(
            type: .semanticGroup(label: "LibraryListScreen", value: nil),
            identifier: "LibraryListScreen",
            frame: AccessibilityRect(CGRect(x: 0, y: 96, width: 820, height: 672))
        )
        let row = makeElement(
            label: "Search all items",
            identifier: "LibraryListScreen-SearchField",
            traits: [.searchField]
        )
        let screen = InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: [
                    "library_search_searchField": InterfaceTree.Element(
                        heistId: "library_search_searchField",
                        path: rowPath,
                        scrollMembership: nil,
                        geometry: testGeometry(
                            for: row,
                            ownerPath: .root,
                            screen: .offscreen
                        ),
                        element: row
                    ),
                ],
                containers: [
                    rootPath: InterfaceTree.Container(
                        container: root,
                        path: rootPath,
                        containerName: "root",
                        viewSpace: interfaceTreeViewSpace(for: root)
                    ),
                    splitPath: InterfaceTree.Container(
                        container: split,
                        path: splitPath,
                        containerName: "split",
                        viewSpace: interfaceTreeViewSpace(for: split)
                    ),
                    orderPath: InterfaceTree.Container(
                        container: order,
                        path: orderPath,
                        containerName: "order_entry",
                        viewSpace: interfaceTreeViewSpace(for: order)
                    ),
                    libraryPath: InterfaceTree.Container(
                        container: library,
                        path: libraryPath,
                        containerName: "library",
                        viewSpace: interfaceTreeViewSpace(for: library)
                    ),
                ],
                viewportCapture: .init(
                    hierarchy: [.container(root, children: [])]
                )
            ),
            liveCapture: LiveCapture.makeForTests()
        )

        let interface = screen.tree.semanticInterface(timestamp: Date())
        let expression = AccessibilityPredicate.exists(.container(.identifier(orderIdentifier)))
        let predicate = try expression.resolve(in: .empty)
        let snapshot = Observation.Snapshot(interface: interface, context: .empty)
        let evidence = Observation.Evidence(
            baseline: snapshot,
            events: [],
            current: snapshot,
            coverage: .complete
        )
        let result = try predicate.evaluate(in: evidence)

        XCTAssertEqual(result, PredicateEvaluationResult(met: true))
        XCTAssertEqual(interface.annotations.containers.count, 4)
        XCTAssertEqual(
            interface.projectedElements.single?.semantics.assertable.label,
            "Search all items"
        )
        XCTAssertEqual(interface.projectedElements.single?.geometry.screen, .offscreen)
        XCTAssertEqual(interface.graph.nodesInPathOrder.count, 5)
    }

    func testInterfaceSelectionPreservesObservationIdentityAnnotations() async throws {
        let firstElement = makeElement(label: "First", traits: [.button])
        let secondElement = makeElement(label: "Second", traits: [.button])
        let first = InterfaceTree.Element(
            heistId: "first_button",
            path: TreePath([0]),
            scrollMembership: nil,
            geometry: testGeometry(
                for: firstElement,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: firstElement)
            ),
            element: firstElement
        )
        let second = InterfaceTree.Element(
            heistId: "second_button",
            path: TreePath([1]),
            scrollMembership: nil,
            geometry: testGeometry(
                for: secondElement,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: secondElement)
            ),
            element: secondElement
        )
        let screen = InterfaceObservation.makeForTests(
            elements: [
                "first_button": first,
                "second_button": second,
            ],
            hierarchy: [
                .element(first.element, traversalIndex: 0),
                .element(second.element, traversalIndex: 1),
            ],
            heistIdsByPath: [
                TreePath([0]): "first_button",
                TreePath([1]): "second_button",
            ],
            firstResponderHeistId: nil
        )
        let vault = TheVault(tripwire: TheTripwire())
        await vault.installObservationForTesting(screen)
        let selected = try vault.selectInterface(InterfaceQuery(
            subtree: .predicate(ElementPredicate(label: "Second"))
        ))
        let record = try XCTUnwrap(selected.projectedElementRecords.single)

        XCTAssertEqual(record.element.semantics, WireConversion.semantics(secondElement))
        XCTAssertEqual(record.element.geometry.screen, second.geometry.screen)
        XCTAssertEqual(
            record.element.geometry.view,
            .invalidated(ownerPath: .root)
        )
        XCTAssertEqual(record.observationIdentity, HeistId(rawValue: "second_button").observationElementIdentity)
    }

    func testContainerSubtreeSelectionPreservesAnnotationsAndObservationIdentity() async throws {
        let containerPath = TreePath([0])
        let firstPath = TreePath([0, 0])
        let secondPath = TreePath([0, 1])
        let firstElement = makeElement(label: "First", traits: [.button])
        let secondElement = makeElement(label: "Second", traits: [.button])
        let first = InterfaceTree.Element(
            heistId: "first_button",
            path: firstPath,
            scrollMembership: nil,
            geometry: testGeometry(
                for: firstElement,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: firstElement)
            ),
            element: firstElement
        )
        let second = InterfaceTree.Element(
            heistId: "second_button",
            path: secondPath,
            scrollMembership: nil,
            geometry: testGeometry(
                for: secondElement,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: secondElement)
            ),
            element: secondElement
        )
        let container = AccessibilityContainer(
            type: .semanticGroup(label: "Actions", value: nil), identifier: nil,
            frame: .zero
        )
        let screen = InterfaceObservation.makeForTests(
            elements: [
                "first_button": first,
                "second_button": second,
            ],
            hierarchy: [
                .container(container, children: [
                    .element(first.element, traversalIndex: 0),
                    .element(second.element, traversalIndex: 1),
                ]),
            ],
            containerNamesByPath: [containerPath: "actions"],
            heistIdsByPath: [
                firstPath: "first_button",
                secondPath: "second_button",
            ],
            firstResponderHeistId: nil
        )
        let vault = TheVault(tripwire: TheTripwire())
        await vault.installObservationForTesting(screen)
        let selected = try vault.selectInterface(InterfaceQuery(
            subtree: .container(.label("Actions"))
        ))
        let records = selected.projectedElementRecords

        XCTAssertEqual(
            selected.projectedElements.compactMap(\.semantics.assertable.label),
            ["First", "Second"]
        )
        XCTAssertEqual(selected.annotations.containerByPath[containerPath]?.containerName, "actions")
        XCTAssertEqual(selected.annotations.elementByPath[firstPath]?.actions, [.activate])
        XCTAssertEqual(
            selected.annotations.elementByPath[firstPath]?.geometry.screen,
            first.geometry.screen
        )
        XCTAssertEqual(records.map(\.observationIdentity), [
            HeistId(rawValue: "first_button").observationElementIdentity,
            HeistId(rawValue: "second_button").observationElementIdentity,
        ])
    }

    func testElementRemovalRemapsOwnerPathsWithoutChangingViewSpaceCases() throws {
        let originalOwner = TreePath([1])
        let remappedOwner = TreePath([0])
        let frame = try ViewRect(validating: CGRect(x: 16, y: 600, width: 200, height: 44))
        let activationPoint = try ViewPoint(validating: CGPoint(x: 116, y: 622))
        let removed = makeElement(label: "Removed", traits: [.staticText])
        let availableElement = makeElement(label: "Available", traits: [.button])
        let invalidatedElement = makeElement(label: "Invalidated", traits: [.button])
        let container = AccessibilityContainer(
            type: .none,
            scrollableContentSize: AccessibilitySize(width: 320, height: 1_200),
            frame: AccessibilityRect(x: 0, y: 0, width: 320, height: 480)
        )
        let available = HeistElement.Geometry.ViewSpace.available(.init(
            ownerPath: originalOwner,
            frame: frame,
            activationPoint: activationPoint
        ))
        let screen = InterfaceObservation.makeForTests(
            elements: [
                "removed": InterfaceTree.Element(
                    heistId: "removed",
                    path: TreePath([0]),
                    scrollMembership: nil,
                    geometry: testGeometry(
                        for: removed,
                        ownerPath: .root,
                        screen: TheVault.onscreenSpace(for: removed)
                    ),
                    element: removed
                ),
                "available": InterfaceTree.Element(
                    heistId: "available",
                    path: TreePath([1, 0]),
                    scrollMembership: .init(containerPath: originalOwner, index: 0),
                    geometry: .init(screen: .offscreen, view: available),
                    element: availableElement
                ),
                "invalidated": InterfaceTree.Element(
                    heistId: "invalidated",
                    path: TreePath([1, 1]),
                    scrollMembership: .init(containerPath: originalOwner, index: 1),
                    geometry: .init(
                        screen: .offscreen,
                        view: .invalidated(ownerPath: originalOwner)
                    ),
                    element: invalidatedElement
                ),
            ],
            hierarchy: [
                .element(removed, traversalIndex: 0),
                .container(container, children: [
                    .element(availableElement, traversalIndex: 1),
                    .element(invalidatedElement, traversalIndex: 2),
                ]),
            ],
            heistIdsByPath: [
                TreePath([0]): "removed",
                TreePath([1, 0]): "available",
                TreePath([1, 1]): "invalidated",
            ],
            firstResponderHeistId: nil
        )

        let filtered = screen.removingElements(withIds: ["removed"])

        XCTAssertEqual(filtered.tree.findElement(heistId: "available")?.path, TreePath([0, 0]))
        XCTAssertEqual(
            filtered.tree.findElement(heistId: "available")?.geometry.view,
            .available(.init(
                ownerPath: remappedOwner,
                frame: frame,
                activationPoint: activationPoint
            ))
        )
        XCTAssertEqual(
            filtered.tree.findElement(heistId: "invalidated")?.geometry.view,
            .invalidated(ownerPath: remappedOwner)
        )
        XCTAssertEqual(filtered.tree.findElement(heistId: "available")?.geometry.screen, .offscreen)
        XCTAssertEqual(filtered.tree.findElement(heistId: "invalidated")?.geometry.screen, .offscreen)
    }

    func testDiscoveryInterfaceGraftsKnownOffViewportElementsUnderScrollContainer() async throws {
        let visible = makeElement(
            label: "aardvark",
            traits: [.staticText],
            frameX: 16,
            frameY: 100,
            frameWidth: 288,
            frameHeight: 44
        )
        let offViewport = makeElement(
            label: "zymurgy",
            traits: [.staticText],
            frameX: 16,
            frameY: 100,
            frameWidth: 288,
            frameHeight: 44
        )
        let container = AccessibilityContainer(
            type: .none, scrollableContentSize: AccessibilitySize(CGSize(width: 320, height: 2_000)),
            frame: AccessibilityRect(CGRect(x: 0, y: 0, width: 320, height: 480))
        )
        let screen = InterfaceObservation.makeForTests(
            elements: [
                "aardvark_staticText": InterfaceTree.Element(
                    heistId: "aardvark_staticText",
                    path: TreePath([0, 0]),
                    scrollMembership: InterfaceTree.ScrollMembership(containerPath: TreePath([0]), index: 0),
                    geometry: testGeometry(
                        for: visible,
                        ownerPath: TreePath([0]),
                        screen: TheVault.onscreenSpace(for: visible)
                    ),
                    element: visible
                ),
                "zymurgy_staticText": InterfaceTree.Element(
                    heistId: "zymurgy_staticText",
                    path: TreePath([0, 1]),
                    scrollMembership: InterfaceTree.ScrollMembership(containerPath: TreePath([0]), index: 1),
                    geometry: testGeometry(
                        for: offViewport,
                        ownerPath: TreePath([0]),
                        screen: .offscreen
                    ),
                    element: offViewport
                ),
            ],
            hierarchy: [
                .container(container, children: [
                    .element(visible, traversalIndex: 0),
                ]),
            ],
            containerNamesByPath: [TreePath([0]): "words_list"],
            heistIdsByPath: [TreePath([0, 0]): "aardvark_staticText"],
            containerViewSpacesByPath: [
                TreePath([0]): interfaceTreeViewSpace(for: container),
            ],
            firstResponderHeistId: nil,
        )

        let interface = WireConversion.discoveryProjection(from: screen.tree).interface

        guard case .container(_, let children) = interface.tree.first else {
            return XCTFail("Expected root scroll container")
        }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children.compactMap { $0.testLabel }, ["aardvark", "zymurgy"])
        XCTAssertNotNil(interface.annotations.elementByPath[TreePath([0, 1])])

        let projected = interface.projectedElements
        XCTAssertEqual(
            projected.compactMap { $0.semantics.assertable.label },
            ["aardvark", "zymurgy"]
        )
        XCTAssertEqual(
            interface.annotations.elementByPath[TreePath([0, 0])]?.geometry,
            screen.tree.elements["aardvark_staticText"]?.geometry
        )
        XCTAssertEqual(
            interface.annotations.elementByPath[TreePath([0, 1])]?.geometry,
            screen.tree.elements["zymurgy_staticText"]?.geometry
        )

        let vault = TheVault(tripwire: TheTripwire())
        await vault.installObservationForTesting(screen)
        let selectedInterface = try vault.selectInterface(InterfaceQuery(
            subtree: .predicate(ElementPredicate(label: "zymurgy"))
        ))
        let selectedProjection = try XCTUnwrap(selectedInterface.projectedElements.first)
        XCTAssertEqual(selectedProjection.semantics.assertable.label, "zymurgy")
        XCTAssertEqual(selectedProjection.geometry.screen, .offscreen)
        XCTAssertEqual(
            selectedProjection.geometry.view,
            .invalidated(ownerPath: .root),
            "Detaching the element subtree must not retain geometry owned by its omitted scroll container"
        )
    }

    func testDiscoveryInterfaceDoesNotRegraftOffscreenElementsAlreadyInFullTreeCapture() async throws {
        let visible = makeElement(label: "Visible", traits: [.staticText])
        let offscreen = AccessibilityElement.make(
            label: "Offscreen",
            traits: .staticText,
            visibility: .offscreen
        )
        let container = AccessibilityContainer(
            type: .none,
            scrollableContentSize: AccessibilitySize(CGSize(width: 320, height: 2_000)),
            frame: AccessibilityRect(CGRect(x: 0, y: 0, width: 320, height: 480))
        )
        let screen = InterfaceObservation.makeForTests(
            elements: [
                "visible": InterfaceTree.Element(
                    heistId: "visible",
                    path: TreePath([0, 0]),
                    scrollMembership: InterfaceTree.ScrollMembership(containerPath: TreePath([0]), index: 0),
                    geometry: testGeometry(
                        for: visible,
                        ownerPath: TreePath([0]),
                        screen: TheVault.onscreenSpace(for: visible)
                    ),
                    element: visible
                ),
                "offscreen": InterfaceTree.Element(
                    heistId: "offscreen",
                    path: TreePath([0, 1]),
                    scrollMembership: InterfaceTree.ScrollMembership(containerPath: TreePath([0]), index: 1),
                    geometry: testGeometry(
                        for: offscreen,
                        ownerPath: TreePath([0]),
                        screen: .offscreen
                    ),
                    element: offscreen
                ),
            ],
            hierarchy: [
                .container(container, children: [
                    .element(visible, traversalIndex: 0),
                    .element(offscreen, traversalIndex: 1),
                ]),
            ],
            heistIdsByPath: [
                TreePath([0, 0]): "visible",
                TreePath([0, 1]): "offscreen",
            ],
            containerViewSpacesByPath: [
                TreePath([0]): interfaceTreeViewSpace(for: container),
            ],
            firstResponderHeistId: nil
        )

        let interface = WireConversion.discoveryProjection(from: screen.tree).interface

        XCTAssertEqual(
            interface.projectedElements.compactMap { $0.semantics.assertable.label },
            ["Visible", "Offscreen"]
        )
        XCTAssertEqual(
            interface.projectedElements.filter {
                $0.semantics.assertable.label == "Offscreen"
            }.count,
            1
        )
        XCTAssertEqual(interface.projectedElements.last?.geometry.screen, .offscreen)
    }

    func testDiscoveryInterfaceGraftsKnownNestedScrollContainers() async throws {
        let outer = AccessibilityContainer(
            type: .none, scrollableContentSize: AccessibilitySize(CGSize(width: 320, height: 2_000)),
            frame: AccessibilityRect(CGRect(x: 0, y: 0, width: 320, height: 480))
        )
        let inner = AccessibilityContainer(
            type: .none, scrollableContentSize: AccessibilitySize(CGSize(width: 280, height: 900)),
            frame: AccessibilityRect(CGRect(x: 20, y: 700, width: 280, height: 240))
        )
        let nestedWord = makeElement(label: "interstitial", traits: [.staticText])
        let liveScreen = InterfaceObservation.makeForTests(
            elements: [:],
            hierarchy: [.container(outer, children: [])],
            containerNamesByPath: [TreePath([0]): "outer_words"],
            containerViewSpacesByPath: [
                TreePath([0]): interfaceTreeViewSpace(for: outer),
            ],
            firstResponderHeistId: nil,
        )
        var containers = liveScreen.tree.containers
        containers[TreePath([0, 0])] = InterfaceTree.Container(
            container: inner,
            path: TreePath([0, 0]),
            containerName: "inner_words",
            viewSpace: interfaceTreeViewSpace(
                for: inner,
                ownerPath: TreePath([0])
            ),
            scrollMembership: InterfaceTree.ScrollMembership(containerPath: TreePath([0]), index: 0)
        )
        let screen = InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: [
                    "interstitial_staticText": InterfaceTree.Element(
                        heistId: "interstitial_staticText",
                        path: TreePath([0, 0, 0]),
                        scrollMembership: InterfaceTree.ScrollMembership(containerPath: TreePath([0, 0]), index: 0),
                        geometry: testGeometry(
                            for: nestedWord,
                            ownerPath: TreePath([0, 0]),
                            screen: .offscreen
                        ),
                        element: nestedWord
                    ),
                ],
                containers: containers
            ),
            liveCapture: liveScreen.liveCapture
        )

        let interface = WireConversion.discoveryProjection(from: screen.tree).interface

        guard case .container(_, let outerChildren) = interface.tree.first else {
            return XCTFail("Expected outer container")
        }
        guard case .container(_, let innerChildren) = outerChildren.first else {
            return XCTFail("Expected nested discovered container")
        }
        XCTAssertEqual(innerChildren.compactMap(\.testLabel), ["interstitial"])
        XCTAssertEqual(interface.annotations.containerByPath[TreePath([0, 0])]?.containerName, "inner_words")
        XCTAssertEqual(
            interface.annotations.elementByPath[TreePath([0, 0, 0])]?.geometry.view.ownerPath,
            TreePath([0, 0])
        )
        XCTAssertEqual(
            interface.projectedElements.single?.semantics.assertable.label,
            "interstitial"
        )
        XCTAssertEqual(interface.projectedElements.single?.geometry.screen, .offscreen)
    }

    func testDiscoveryInterfaceEmitsCanonicalGraftedHeistIdOnce() async throws {
        let rootContainer = AccessibilityContainer(
            type: .none, scrollableContentSize: AccessibilitySize(CGSize(width: 320, height: 2_000)),
            frame: AccessibilityRect(CGRect(x: 0, y: 0, width: 320, height: 480))
        )
        let recycledCell = makeElement(
            label: "618F3ADF",
            traits: [.staticText],
            frameX: 0,
            frameY: 724,
            frameWidth: 393,
            frameHeight: 64
        )
        let screen = InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: [
                    "recycled_cell": InterfaceTree.Element(
                        heistId: "recycled_cell",
                        path: TreePath([0, 0]),
                        scrollMembership: InterfaceTree.ScrollMembership(containerPath: TreePath([0]), index: 0),
                        geometry: testGeometry(
                            for: recycledCell,
                            ownerPath: TreePath([0]),
                            screen: .offscreen
                        ),
                        element: recycledCell
                    ),
                ],
                containers: [
                    TreePath([0]): InterfaceTree.Container(
                        container: rootContainer,
                        path: TreePath([0]),
                        containerName: "transactions_list",
                        viewSpace: interfaceTreeViewSpace(for: rootContainer)
                    ),
                ],
                viewportCapture: .init(
                    hierarchy: [.container(rootContainer, children: [])]
                )
            ),
            liveCapture: LiveCapture.makeForTests()
        )

        let interface = WireConversion.discoveryProjection(from: screen.tree).interface

        guard case .container(_, let children) = interface.tree.first else {
            return XCTFail("Expected root scroll container")
        }
        XCTAssertEqual(children.compactMap { $0.testLabel }, ["618F3ADF"])
        XCTAssertEqual(
            interface.projectedElements.filter {
                $0.semantics.assertable.label == "618F3ADF"
            }.count,
            1
        )
        XCTAssertEqual(
            interface.annotations.elementByPath[TreePath([0, 0])]?.geometry,
            screen.tree.elements["recycled_cell"]?.geometry
        )
        XCTAssertEqual(
            interface.projectedElementRecords.single?.observationIdentity,
            HeistId(rawValue: "recycled_cell").observationElementIdentity
        )
        XCTAssertNil(interface.annotations.elementByPath[TreePath([0, 1])])
    }

    func testDiscoveryInterfacePreservesDistinctDisambiguatedHeistIds() async throws {
        let rootContainer = AccessibilityContainer(
            type: .none, scrollableContentSize: AccessibilitySize(CGSize(width: 320, height: 2_000)),
            frame: AccessibilityRect(CGRect(x: 0, y: 0, width: 320, height: 480))
        )
        let firstCell = makeElement(
            label: "Repeat",
            traits: [.button],
            frameX: 0,
            frameY: 724,
            frameWidth: 393,
            frameHeight: 64
        )
        let secondCell = makeElement(
            label: "Repeat",
            traits: [.button],
            frameX: 0,
            frameY: 788,
            frameWidth: 393,
            frameHeight: 64
        )
        let screen = InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: [
                    "repeat_button": InterfaceTree.Element(
                        heistId: "repeat_button",
                        path: TreePath([0, 0]),
                        scrollMembership: InterfaceTree.ScrollMembership(containerPath: TreePath([0]), index: 0),
                        geometry: testGeometry(
                            for: firstCell,
                            ownerPath: TreePath([0]),
                            screen: .offscreen
                        ),
                        element: firstCell
                    ),
                    "repeat_button_1": InterfaceTree.Element(
                        heistId: "repeat_button_1",
                        path: TreePath([0, 1]),
                        scrollMembership: InterfaceTree.ScrollMembership(containerPath: TreePath([0]), index: 1),
                        geometry: testGeometry(
                            for: secondCell,
                            ownerPath: TreePath([0]),
                            screen: .offscreen
                        ),
                        element: secondCell
                    ),
                ],
                containers: [
                    TreePath([0]): InterfaceTree.Container(
                        container: rootContainer,
                        path: TreePath([0]),
                        containerName: "transactions_list",
                        viewSpace: interfaceTreeViewSpace(for: rootContainer)
                    ),
                ],
                viewportCapture: .init(
                    hierarchy: [.container(rootContainer, children: [])]
                )
            ),
            liveCapture: LiveCapture.makeForTests()
        )

        let interface = WireConversion.discoveryProjection(from: screen.tree).interface

        guard case .container(_, let children) = interface.tree.first else {
            return XCTFail("Expected root scroll container")
        }
        XCTAssertEqual(children.compactMap { $0.testLabel }, ["Repeat", "Repeat"])
        XCTAssertEqual(
            interface.projectedElements.filter {
                $0.semantics.assertable.label == "Repeat"
            }.count,
            2
        )
        XCTAssertEqual(
            interface.projectedElementRecords.map { $0.observationIdentity },
            [
                HeistId(rawValue: "repeat_button").observationElementIdentity,
                HeistId(rawValue: "repeat_button_1").observationElementIdentity,
            ]
        )
        XCTAssertEqual(
            interface.projectedElements.map { $0.geometry.view.ownerPath },
            [TreePath([0]), TreePath([0])]
        )
        XCTAssertNotNil(interface.annotations.elementByPath[TreePath([0, 0])])
        XCTAssertNotNil(interface.annotations.elementByPath[TreePath([0, 1])])
    }

    func testDiscoveryInterfaceEmitsDuplicateGraftedContainerNamesByPath() async throws {
        let rootContainer = AccessibilityContainer(
            type: .none, scrollableContentSize: AccessibilitySize(CGSize(width: 320, height: 2_000)),
            frame: AccessibilityRect(CGRect(x: 0, y: 0, width: 320, height: 480))
        )
        let recycledContainer = AccessibilityContainer(
            type: .semanticGroup(label: "Saved carts", value: nil), identifier: nil,
            frame: AccessibilityRect(CGRect(x: 0, y: 640, width: 320, height: 120))
        )
        let screen = InterfaceObservation.makeForTests(
            tree: InterfaceTree(
                elements: [:],
                containers: [
                    TreePath([0]): InterfaceTree.Container(
                        container: rootContainer,
                        path: TreePath([0]),
                        containerName: "transactions_list",
                        viewSpace: interfaceTreeViewSpace(for: rootContainer)
                    ),
                    TreePath([0, 0]): InterfaceTree.Container(
                        container: recycledContainer,
                        path: TreePath([0, 0]),
                        containerName: "saved_carts_group",
                        viewSpace: interfaceTreeViewSpace(
                            for: recycledContainer,
                            ownerPath: TreePath([0])
                        ),
                        scrollMembership: InterfaceTree.ScrollMembership(containerPath: TreePath([0]), index: 0)
                    ),
                    TreePath([0, 1]): InterfaceTree.Container(
                        container: recycledContainer,
                        path: TreePath([0, 1]),
                        containerName: "saved_carts_group",
                        viewSpace: interfaceTreeViewSpace(
                            for: recycledContainer,
                            ownerPath: TreePath([0])
                        ),
                        scrollMembership: InterfaceTree.ScrollMembership(containerPath: TreePath([0]), index: 1)
                    ),
                ],
                viewportCapture: .init(
                    hierarchy: [.container(rootContainer, children: [])]
                )
            ),
            liveCapture: LiveCapture.makeForTests()
        )

        let interface = WireConversion.discoveryProjection(from: screen.tree).interface

        guard case .container(_, let children) = interface.tree.first else {
            return XCTFail("Expected root scroll container")
        }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(
            interface.annotations.containers.filter { $0.containerName == "saved_carts_group" }.count,
            2
        )
        XCTAssertNotNil(interface.annotations.containerByPath[TreePath([0, 0])])
        XCTAssertNotNil(interface.annotations.containerByPath[TreePath([0, 1])])
        XCTAssertEqual(
            screen.tree.containers[TreePath([0, 0])]?.viewSpace.ownerPath,
            TreePath([0])
        )
        XCTAssertEqual(
            screen.tree.containers[TreePath([0, 1])]?.viewSpace.ownerPath,
            TreePath([0])
        )
    }

}

#endif
