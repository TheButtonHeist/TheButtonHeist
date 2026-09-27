import ButtonHeistTestSupport
import XCTest
import ThePlans
import AccessibilitySnapshotModel
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

extension TheFenceCompactFormattingContractTests {

    func testCompactInterfaceRendersNestedContainersAndElements() {
        let output = FenceResponse.compactInterface(formattingFixtureInterface(), detail: .summary)

        XCTAssertEqual(output, """
        4 elements
        ── group "Actions" id="actions" "semantic_actions__actions" ──
          [0] "Submit" button
          ── table rows=3 columns=4 "orders_table" ──
            [1] "Order ID" staticText
          ── /orders_table ──
          ── tab_bar "main_tabs" ──
            [2] "Home" tabBarItem
          ── /main_tabs ──
        ── /semantic_actions__actions ──
        ── container "main_scroll" 1 elements modal ──
          390×400 view, 390×1200 content (4 pages), vertical
          [3] "Bottom" staticText
        ── /main_scroll ──
        """)
        XCTAssertFalse(output.contains("<"), output)
        XCTAssertFalse(output.contains("semanticGroup"), output)
        XCTAssertFalse(output.contains("dataTable"), output)
        XCTAssertFalse(output.contains("tabBar containerName"), output)
        XCTAssertFalse(output.contains("stableId"), output)
    }

    func testCompactInterfaceStartsWithSummaryElementLabel() {
        let interface = makeTestInterface(elements: [
            makeTestHeistElement(label: "Inbox", traits: [.header]),
            makeTestHeistElement(label: "Messages", traits: [.summaryElement]),
            makeTestHeistElement(label: "Search", traits: [.searchField]),
        ])

        let output = FenceResponse.compactInterface(interface, detail: .summary)

        XCTAssertEqual(output, """
        Messages
        3 elements
        [0] "Inbox" header
        [1] "Messages" summaryElement
        [2] "Search" searchField
        """)
    }

    func testInterfaceRendersScreenActionsInCompactAndJSON() throws {
        let interface = formattingFixtureInterface().withScreenActions([.dismiss, .magicTap])
        let compact = FenceResponse.compactInterface(interface, detail: .summary)
        let json = try publicInterfaceJSONProbe(publicInterfaceProjection(interface: interface, detail: .summary))

        XCTAssertTrue(compact.hasPrefix("Actions: dismiss, magicTap\n4 elements"), compact)
        XCTAssertEqual(try json.strings("screenActions"), ["dismiss", "magicTap"])
    }

    func testCompactInterfaceRendersHorizontalAndBothAxisScrollSummaries() {
        let cases: [(name: ContainerName, contentHeight: Double, expected: String)] = [
            (
                "horizontal_scroll",
                400,
                """
                ── container "horizontal_scroll" 1 elements ──
                  390×400 view, 1200×400 content (4 pages), horizontal
                """
            ),
            (
                "both_axis_scroll",
                1200,
                """
                ── container "both_axis_scroll" 1 elements ──
                  390×400 view, 1200×1200 content (4 pages), both
                """
            ),
        ]

        for testCase in cases {
            let interface = makeTestInterface(nodes: [
                .container(
                    makeTestScrollableContainer(
                        contentWidth: 1200,
                        contentHeight: testCase.contentHeight,
                        frameWidth: 390,
                        frameHeight: 400
                    ),
                    containerName: testCase.name,
                    children: [.element(makeTestHeistElement(label: "Item"))]
                ),
            ])
            let output = FenceResponse.compactInterface(interface, detail: .summary)

            XCTAssertTrue(output.contains(testCase.expected), output)
        }
    }

    func testCompactInterfaceTruncatesScrollableSubtreeAtVisibleElementBudget() {
        let rows = (0..<4).map { index in
            TestInterfaceNode.element(makeTestHeistElement(label: "Row \(index)"))
        }
        let interface = makeTestInterface(nodes: [
            .container(
                makeTestScrollableContainer(
                    contentWidth: 390,
                    contentHeight: 1200,
                    frameWidth: 390,
                    frameHeight: 400
                ),
                containerName: "long_scroll",
                children: rows
            ),
            .element(makeTestHeistElement(label: "After")),
        ])

        let output = FenceResponse.compactInterface(
            interface,
            detail: .summary,
            visibleElementBudget: 2
        )

        XCTAssertEqual(output, """
        5 elements
        ── container "long_scroll" 4 elements ──
          390×400 view, 390×1200 content (4 pages), vertical
          [0] "Row 0" staticText
          [1] "Row 1" staticText
          ⋮ 2 more
        ── /long_scroll ──
        [4] "After" staticText
        """)
    }

    func testInterfaceProjectionPreservesDeepWideOrderAndPathDistinctDuplicates() throws {
        let depth = 20
        let width = 24
        let repeated = makeTestHeistElement(label: "Repeated")
        var deepNode = TestInterfaceNode.element(repeated)
        for level in (0..<depth).reversed() {
            deepNode = .container(
                makeTestSemanticContainer(label: "Depth \(level)"),
                containerName: ContainerName(stringLiteral: "depth_\(level)"),
                children: [deepNode]
            )
        }
        let wideNodes = (0..<width).map { index in
            TestInterfaceNode.element(makeTestHeistElement(label: "Wide \(index)"))
        }
        let interface = makeTestInterface(nodes: [deepNode] + wideNodes + [.element(repeated)])

        let compact = FenceResponse.compactInterface(
            interface,
            detail: .summary,
            visibleElementBudget: 100,
            totalNodeBudget: 100
        )
        let json = try publicInterfaceJSONProbe(publicInterfaceProjection(
            interface: interface,
            detail: .summary,
            visibleElementBudget: 100,
            totalNodeBudget: 100
        ))
        let tree = try json.array("tree")

        XCTAssertEqual(try json.object("rendering").int("renderedElementCount"), width + 2)
        XCTAssertEqual(tree.count, width + 2)
        XCTAssertEqual(compact.components(separatedBy: #""Repeated" staticText"#).count - 1, 2)
        XCTAssertTrue(compact.contains(#"[0] "Repeated" staticText"#), compact)
        XCTAssertTrue(compact.contains("[\(width + 1)] \"Repeated\" staticText"), compact)

        var deepJSONNode = tree[0]
        for level in 0..<depth {
            let container = try deepJSONNode.object("container")
            XCTAssertEqual(try container.string("containerName"), "depth_\(level)")
            deepJSONNode = try XCTUnwrap(try container.array("children").first)
        }
        let firstRepeated = try deepJSONNode.object("element")
        let firstWide = try tree[1].object("element")
        let lastRepeated = try XCTUnwrap(tree.last).object("element")
        XCTAssertEqual(try firstRepeated.string("label"), "Repeated")
        XCTAssertEqual(try firstRepeated.int("order"), 0)
        XCTAssertEqual(try firstWide.string("label"), "Wide 0")
        XCTAssertEqual(try firstWide.int("order"), 1)
        XCTAssertEqual(try lastRepeated.string("label"), "Repeated")
        XCTAssertEqual(try lastRepeated.int("order"), width + 1)
    }

    func testPublicInterfaceOwnsNestedScrollAndNodeBudgetSemantics() throws {
        let rows = (1...3).map { index in
            TestInterfaceNode.element(makeTestHeistElement(label: "Row \(index)"))
        }
        let interface = makeTestInterface(nodes: [
            .container(
                makeTestScrollableContainer(
                    contentWidth: 390,
                    contentHeight: 2_000,
                    frameWidth: 390,
                    frameHeight: 400
                ),
                containerName: "outer_scroll",
                children: [
                    .element(makeTestHeistElement(label: "Row 0")),
                    .container(
                        makeTestScrollableContainer(
                            contentWidth: 390,
                            contentHeight: 1_200,
                            frameWidth: 390,
                            frameHeight: 400
                        ),
                        containerName: "inner_scroll",
                        children: rows
                    ),
                    .element(makeTestHeistElement(label: "Row 4")),
                ]
            ),
            .element(makeTestHeistElement(label: "After")),
        ])

        let elementLimited = publicInterfaceProjection(
            interface: interface,
            detail: .summary,
            visibleElementBudget: 2,
            totalNodeBudget: 100
        )
        guard case .container(let elementOuter) = elementLimited.tree[0],
              case .container(let elementInner) = elementOuter.children[1],
              case .element(let after) = elementLimited.tree[1]
        else {
            return XCTFail("Expected nested scroll projection followed by the trailing element")
        }

        XCTAssertEqual(elementLimited.rendering.reason?.rawValue, "scroll-subtree-element-budget")
        XCTAssertEqual(elementLimited.rendering.observedElementCount, 6)
        XCTAssertEqual(elementLimited.rendering.renderedElementCount, 3)
        XCTAssertEqual(elementLimited.rendering.omittedElementCount, 3)
        XCTAssertEqual(elementOuter.truncation?.omittedElementCount, 3)
        XCTAssertEqual(elementInner.truncation?.omittedElementCount, 2)
        XCTAssertEqual(after.order, 5)

        let nodeLimited = publicInterfaceProjection(
            interface: interface,
            detail: .summary,
            visibleElementBudget: 2,
            totalNodeBudget: 3
        )
        guard case .container(let nodeOuter) = nodeLimited.tree[0],
              case .container(let nodeInner) = nodeOuter.children[1]
        else {
            return XCTFail("Expected both nested containers within the node budget")
        }

        XCTAssertEqual(nodeLimited.rendering.reason?.rawValue, "total-node-budget")
        XCTAssertEqual(nodeLimited.rendering.renderedElementCount, 1)
        XCTAssertEqual(nodeLimited.rendering.omittedElementCount, 5)
        XCTAssertNil(nodeLimited.rendering.visibleElementBudget)
        XCTAssertEqual(nodeLimited.rendering.totalNodeBudget, 3)
        XCTAssertNil(nodeOuter.truncation)
        XCTAssertNil(nodeInner.truncation)
    }

    func testPublicInterfaceJSONRendersScrollSummaryFields() throws {
        let response = FenceResponse.interface(formattingFixtureInterface(), detail: .summary)

        let interface = try publicJSONProbe(response).object("interface")
        let rendering = try interface.object("rendering")
        let tree = try interface.array("tree")
        let scrollContainer = try tree[1].object("container")

        XCTAssertEqual(try rendering.string("completeness"), "full")
        try rendering.assertMissing("reasonCode")
        XCTAssertEqual(try rendering.int("observedElementCount"), 4)
        XCTAssertEqual(try rendering.int("renderedElementCount"), 4)
        XCTAssertEqual(try rendering.int("omittedElementCount"), 0)
        try rendering.assertMissing("visibleElementBudget")
        try rendering.assertMissing("totalNodeBudget")
        XCTAssertEqual(try scrollContainer.string("type"), "none")
        XCTAssertEqual(try scrollContainer.double("contentWidth"), 390)
        XCTAssertEqual(try scrollContainer.double("contentHeight"), 1200)
        XCTAssertEqual(try scrollContainer.string("scrollAxis"), "vertical")
        try scrollContainer.assertMissing("pageScrollsX")
        XCTAssertEqual(try scrollContainer.int("pageScrollsY"), 3)
        XCTAssertEqual(try scrollContainer.int("observedElementCount"), 1)
        try scrollContainer.assertMissing("truncation")
    }

    func testPublicInterfaceOutputIncludesDiscoveryLimitDiagnostics() throws {
        let diagnostics = InterfaceDiagnostics(discovery: InterfaceDiscoveryDiagnostics(
            state: .limited,
            reasonCodes: [.discoveryScrollLimit],
            includedElementCount: 2,
            scrollAttempts: 5,
            maxScrollsPerDiscovery: 5,
            maxScrollsPerContainer: 3,
            exploredScrollableContainerCount: 1,
            omittedScrollableContainerCount: 1,
            omittedContainers: [
                InterfaceDiscoveryOmittedContainer(
                    containerName: "main_scroll",
                    type: .none,
                    reasonCodes: [.discoveryScrollLimit],
                    scrollAxis: .vertical,
                    viewportWidth: 390,
                    viewportHeight: 400,
                    contentWidth: 390,
                    contentHeight: 1_200
                ),
            ],
            nextAction: "Retry get_interface with a higher maxScrollsPerDiscovery."
        ))
        let interface = makeTestInterface(nodes: [
            .container(
                makeTestScrollableContainer(
                    contentWidth: 390,
                    contentHeight: 1_200,
                    frameWidth: 390,
                    frameHeight: 400
                ),
                containerName: "main_scroll",
                children: [
                    .element(makeTestHeistElement(label: "Top")),
                    .element(makeTestHeistElement(label: "Bottom")),
                ]
            ),
        ]).withDiagnostics(diagnostics)

        let compact = FenceResponse.compactInterface(interface, detail: .summary)
        let json = try publicInterfaceJSONProbe(publicInterfaceProjection(interface: interface, detail: .summary))
        let discovery = try json.object("diagnostics").object("discovery")
        let omittedContainers = try discovery.array("omittedContainers")
        let omitted = try XCTUnwrap(omittedContainers.first)

        XCTAssertTrue(
            compact.contains(
                "discovery: limited[scroll-attempt-budget] includedElements=2 scrollAttempts=5/5"
            ),
            compact
        )
        XCTAssertTrue(compact.contains(#"omitted: none containerName="main_scroll""#), compact)
        XCTAssertTrue(compact.contains("next: Retry get_interface"), compact)
        XCTAssertEqual(try discovery.string("state"), "limited")
        XCTAssertEqual(try discovery.strings("reasonCodes"), ["scroll-attempt-budget"])
        XCTAssertEqual(try discovery.int("includedElementCount"), 2)
        XCTAssertEqual(try discovery.int("scrollAttempts"), 5)
        XCTAssertEqual(try discovery.int("maxScrollsPerDiscovery"), 5)
        XCTAssertEqual(try discovery.int("maxScrollsPerContainer"), 3)
        XCTAssertEqual(try discovery.int("omittedScrollableContainerCount"), 1)
        XCTAssertEqual(try omitted.string("containerName"), "main_scroll")
        XCTAssertEqual(try omitted.string("scrollAxis"), "vertical")
        XCTAssertEqual(try omitted.strings("reasonCodes"), ["scroll-attempt-budget"])
    }

    func testPublicInterfaceJSONUsesCanonicalContainerTypeWithScrollMetadata() throws {
        let interface = makeTestInterface(nodes: [
            .container(
                makeTestScrollableContainer(
                    contentWidth: 390,
                    contentHeight: 1_200,
                    frameWidth: 390,
                    frameHeight: 400
                ),
                containerName: "main_scroll",
                children: [
                    .element(makeTestHeistElement(label: "Top")),
                ]
            ),
        ])

        let dto = try publicInterfaceContractDTO(interface)
        let container = try XCTUnwrap(dto.topLevelContainers.first)

        XCTAssertEqual(container.type, "none")
        XCTAssertNotEqual(container.type, "scrollable")
        XCTAssertEqual(container.containerName, "main_scroll")
        XCTAssertEqual(container.contentWidth, 390)
        XCTAssertEqual(container.contentHeight, 1_200)
        XCTAssertEqual(container.scrollAxis, "vertical")
        XCTAssertEqual(container.pageScrollsY, 3)
    }

    func testPublicInterfaceJSONKeepsNonScrollableContainerTypesDistinct() throws {
        let interface = makeTestInterface(nodes: [
            .container(
                makeTestSemanticContainer(label: "Actions", value: "Primary", identifier: "actions"),
                containerName: "actions_group",
                children: []
            ),
            .container(
                makeTestAccessibilityContainer(type: .list),
                containerName: "rows_list",
                children: []
            ),
            .container(
                makeTestAccessibilityContainer(type: .landmark),
                containerName: "main_landmark",
                children: []
            ),
            .container(
                makeTestAccessibilityContainer(type: .dataTable(rowCount: 3, columnCount: 2, cells: [])),
                containerName: "prices_table",
                children: []
            ),
            .container(
                makeTestAccessibilityContainer(type: .tabBar),
                containerName: "primary_tabs",
                children: []
            ),
        ])

        let containers = try publicInterfaceContractDTO(interface).topLevelContainers

        XCTAssertEqual(containers.map(\.type), [
            "semanticGroup",
            "list",
            "landmark",
            "dataTable",
            "tabBar",
        ])
        XCTAssertEqual(containers[0].label, "Actions")
        XCTAssertEqual(containers[0].value, "Primary")
        XCTAssertEqual(containers[0].identifier, "actions")
        XCTAssertEqual(containers[1].containerName, "rows_list")
        XCTAssertEqual(containers[3].rowCount, 3)
        XCTAssertEqual(containers[3].columnCount, 2)
    }

    func testPublicInterfaceOutputRendersContainerCustomActions() throws {
        let interface = makeTestInterface(nodes: [
            .container(
                makeTestAccessibilityContainer(
                    type: .none,
                    customActions: [AccessibilityElement.CustomAction(name: "Archive")]
                ),
                containerName: "archive_container",
                children: []
            ),
        ])

        let compact = FenceResponse.compactInterface(interface, detail: .summary)
        let human = FenceResponse.interface(interface, detail: .summary).humanFormatted()
        let container = try XCTUnwrap(try publicInterfaceContractDTO(interface).topLevelContainers.first)

        XCTAssertTrue(compact.contains(#"── container "archive_container" actions="Archive" ──"#), compact)
        XCTAssertTrue(human.contains(#"container containerName: archive_container actions="Archive""#), human)
        XCTAssertEqual(container.actions, ["Archive"])
    }

    func testPublicInterfaceJSONTruncatesWholeInterfaceAtTotalNodeBudget() throws {
        let rows = (0..<4).map { index in
            TestInterfaceNode.element(makeTestHeistElement(label: "Row \(index)"))
        }
        let interface = makeTestInterface(nodes: rows)

        let json = try publicInterfaceJSONProbe(
            publicInterfaceProjection(
                interface: interface,
                detail: .summary,
                visibleElementBudget: 10,
                totalNodeBudget: 2
            )
        )
        let rendering = try json.object("rendering")
        let tree = try json.array("tree")

        XCTAssertEqual(try rendering.string("completeness"), "truncated")
        XCTAssertEqual(try rendering.string("reasonCode"), "total-node-budget")
        XCTAssertEqual(try rendering.int("observedElementCount"), 4)
        XCTAssertEqual(try rendering.int("renderedElementCount"), 2)
        XCTAssertEqual(try rendering.int("omittedElementCount"), 2)
        try rendering.assertMissing("visibleElementBudget")
        XCTAssertEqual(try rendering.int("totalNodeBudget"), 2)
        XCTAssertEqual(tree.count, 2)
    }

    func testScrollInventoryCompletenessMatchesCaptureBudgetBoundaries() throws {
        let cases: [(
            name: String,
            totalElementCount: Int,
            materializedElementCount: Int,
            visibleElementBudget: Int,
            expectedCompleteness: String
        )] = [
            ("zero-empty", 0, 0, 0, "full"),
            ("zero-nonempty", 3, 0, 0, "truncated"),
            ("below-cap", 2, 2, 3, "full"),
            ("at-cap", 2, 2, 2, "full"),
            ("above-cap", 3, 1, 2, "truncated"),
        ]

        for testCase in cases {
            let interface = try scrollInventoryInterface(
                totalElementCount: testCase.totalElementCount,
                materializedElementCount: testCase.materializedElementCount
            )
            XCTAssertTrue(interface.annotations.elements.isEmpty, testCase.name)
            let publicInterface = publicInterfaceProjection(
                interface: interface,
                detail: .summary,
                visibleElementBudget: testCase.visibleElementBudget
            )
            if case .container(let projectedContainer)? = publicInterface.tree.first {
                for child in projectedContainer.children {
                    guard case .element(let projectedElement) = child else { continue }
                    XCTAssertEqual(
                        projectedElement.element.geometry.screen,
                        .offscreen,
                        testCase.name
                    )
                }
            }
            let json = try publicInterfaceJSONProbe(publicInterface)
            let rendering = try json.object("rendering")
            let container = try XCTUnwrap(try json.array("tree").first).object("container")
            let compact = FenceResponse.compactInterface(
                interface,
                detail: .summary,
                visibleElementBudget: testCase.visibleElementBudget
            )
            let completenessCount = max(
                testCase.totalElementCount,
                testCase.materializedElementCount
            )

            XCTAssertEqual(
                try rendering.string("completeness"),
                testCase.expectedCompleteness,
                testCase.name
            )
            XCTAssertEqual(
                try container.int("observedElementCount"),
                completenessCount,
                testCase.name
            )
            XCTAssertTrue(
                compact.contains(#"── container "inventory_scroll" \#(completenessCount) elements ──"#),
                "\(testCase.name): \(compact)"
            )

            if testCase.expectedCompleteness == "truncated" {
                let truncation = try container.object("truncation")
                let omittedElementCount = completenessCount - testCase.materializedElementCount
                XCTAssertEqual(
                    try truncation.int("observedElementCount"),
                    completenessCount,
                    testCase.name
                )
                XCTAssertEqual(
                    try truncation.int("renderedElementCount"),
                    testCase.materializedElementCount,
                    testCase.name
                )
                XCTAssertEqual(
                    try truncation.int("omittedElementCount"),
                    omittedElementCount,
                    testCase.name
                )
                XCTAssertTrue(
                    compact.contains("⋮ \(omittedElementCount) more"),
                    "\(testCase.name): \(compact)"
                )
            } else {
                try container.assertMissing("truncation")
                XCTAssertFalse(compact.contains("⋮"), "\(testCase.name): \(compact)")
            }
        }
    }

    func testScrollInventoryCompletenessSharesCaptureBudgetAcrossSiblingOwners() throws {
        let interface = try siblingScrollInventoryInterface(
            totalElementCount: 2,
            materializedElementCounts: [2, 1]
        )
        XCTAssertTrue(interface.annotations.elements.isEmpty)
        let json = try publicInterfaceJSONProbe(publicInterfaceProjection(
            interface: interface,
            detail: .summary,
            visibleElementBudget: 3
        ))
        let rendering = try json.object("rendering")
        let containers = try json.array("tree").map { try $0.object("container") }
        let compact = FenceResponse.compactInterface(
            interface,
            detail: .summary,
            visibleElementBudget: 3
        )

        XCTAssertEqual(try rendering.string("completeness"), "truncated")
        try containers[0].assertMissing("truncation")
        let secondTruncation = try containers[1].object("truncation")
        XCTAssertEqual(try secondTruncation.int("observedElementCount"), 2)
        XCTAssertEqual(try secondTruncation.int("renderedElementCount"), 1)
        XCTAssertEqual(try secondTruncation.int("omittedElementCount"), 1)
        XCTAssertTrue(compact.contains(#"── container "inventory_scroll_0" 2 elements ──"#), compact)
        XCTAssertTrue(compact.contains(#"── container "inventory_scroll_1" 2 elements ──"#), compact)
        XCTAssertEqual(compact.components(separatedBy: "⋮ 1 more").count - 1, 1, compact)
    }

    func testNestedScrollInventoryCountAppliesOnlyToOwningContainer() throws {
        let innerElements = (0..<2).map { index in
            AccessibilityHierarchy.element(
                makeTestAccessibilityElement(makeTestHeistElement(label: "Inner \(index)")),
                traversalIndex: index
            )
        }
        let innerScroll = AccessibilityHierarchy.container(
            makeTestScrollableContainer(
                contentWidth: 390,
                contentHeight: 1_200,
                frameWidth: 390,
                frameHeight: 400
            ),
            children: innerElements
        )
        let outerElement = AccessibilityHierarchy.element(
            makeTestAccessibilityElement(makeTestHeistElement(label: "Outer")),
            traversalIndex: 2
        )
        let tree = [
            AccessibilityHierarchy.container(
                makeTestScrollableContainer(
                    contentWidth: 390,
                    contentHeight: 2_000,
                    frameWidth: 390,
                    frameHeight: 400
                ),
                children: [innerScroll, outerElement]
            ),
        ]
        let inventory = try XCTUnwrap(ScrollInventory(totalElementCount: 5))
        let interface = try Interface(
            timestamp: Date(timeIntervalSince1970: 0),
            tree: tree,
            annotations: InterfaceAnnotations(containers: [
                InterfaceContainerAnnotation(path: TreePath([0]), containerName: "outer_scroll"),
                InterfaceContainerAnnotation(
                    path: TreePath([0, 0]),
                    containerName: "inner_scroll",
                    scrollInventory: inventory
                ),
            ])
        )
        XCTAssertTrue(interface.annotations.elements.isEmpty)

        let json = try publicInterfaceJSONProbe(publicInterfaceProjection(
            interface: interface,
            detail: .summary,
            visibleElementBudget: 10
        ))
        let rendering = try json.object("rendering")
        let outer = try XCTUnwrap(try json.array("tree").first).object("container")
        let inner = try XCTUnwrap(try outer.array("children").first).object("container")
        let compact = FenceResponse.compactInterface(
            interface,
            detail: .summary,
            visibleElementBudget: 10
        )

        XCTAssertEqual(try rendering.string("completeness"), "full")
        XCTAssertEqual(try outer.int("observedElementCount"), 3)
        XCTAssertEqual(try inner.int("observedElementCount"), 5)
        XCTAssertTrue(compact.contains(#"── container "outer_scroll" 3 elements ──"#), compact)
        XCTAssertTrue(compact.contains(#"── container "inner_scroll" 5 elements ──"#), compact)
        XCTAssertFalse(compact.contains("⋮"), compact)
    }

    func testCompactContainerEscapesLabelsAndContainerNames() {
        let interface = makeTestInterface(nodes: [
            .container(
                makeTestSemanticContainer(
                    label: "Actions \"Primary\"\nPane",
                    value: "hot\u{0001}",
                    identifier: "actions\"id"
                ),
                containerName: "semantic\n\"actions",
                children: [
                    .element(makeTestHeistElement(label: "Submit")),
                ]
            ),
        ])

        let output = FenceResponse.compactInterface(interface, detail: .summary)

        XCTAssertTrue(output.contains(#"── group "Actions \"Primary\"\nPane" value="hot\u0001" id="actions\"id" "semantic\n\"actions" ──"#), output)
        XCTAssertFalse(output.contains("stableId"), output)
    }

    func testCompactSummaryOmitsContainerGeometryAndFullIncludesFrame() {
        let interface = formattingFixtureInterface()

        let summary = FenceResponse.compactInterface(interface, detail: .summary)
        let full = FenceResponse.compactInterface(interface, detail: .full)

        XCTAssertFalse(summary.contains("frame="), summary)
        XCTAssertTrue(
            full.contains(#"── group "Actions" id="actions" "semantic_actions__actions" frame=(0,40,200,100) ──"#),
            full
        )
        XCTAssertTrue(summary.contains(#"── container "main_scroll" 1 elements modal ──"#), summary)
        XCTAssertTrue(summary.contains("390×400 view, 390×1200 content (4 pages), vertical"), summary)
    }

    func testHumanInterfaceRendersHierarchyAndRespectsDetail() {
        let interface = formattingFixtureInterface()

        let summary = FenceResponse.interface(interface, detail: .summary).humanFormatted()
        let full = FenceResponse.interface(interface, detail: .full).humanFormatted()

        XCTAssertTrue(summary.contains(#"group "Actions" id="actions" containerName: semantic_actions__actions"#), summary)
        XCTAssertTrue(summary.contains(#"  [ 0] "Submit" traits=button actions=activate"#), summary)
        XCTAssertTrue(summary.contains(#"  table rows=3 columns=4 containerName: orders_table"#), summary)
        XCTAssertTrue(summary.contains(#"container containerName: main_scroll viewport=390x400 content=390x1200 modal=true"#), summary)
        XCTAssertFalse(summary.contains("frame="), summary)
        XCTAssertFalse(summary.contains("stableId"), summary)
        XCTAssertTrue(full.contains(#"group "Actions" id="actions" containerName: semantic_actions__actions frame=(0,40,200,100)"#), full)
    }

}

private func scrollInventoryInterface(
    totalElementCount: Int,
    materializedElementCount: Int
) throws -> Interface {
    let children = (0..<materializedElementCount).map { index in
        AccessibilityHierarchy.element(
            makeTestAccessibilityElement(makeTestHeistElement(label: "Row \(index)")),
            traversalIndex: index
        )
    }
    let tree = [
        AccessibilityHierarchy.container(
            makeTestScrollableContainer(
                contentWidth: 390,
                contentHeight: 1_200,
                frameWidth: 390,
                frameHeight: 400
            ),
            children: children
        ),
    ]
    let inventory = ScrollInventory(totalElementCount: totalElementCount)
    return try Interface(
        timestamp: Date(timeIntervalSince1970: 0),
        tree: tree,
        annotations: InterfaceAnnotations(containers: [
            InterfaceContainerAnnotation(
                path: TreePath([0]),
                containerName: "inventory_scroll",
                scrollInventory: inventory
            ),
        ])
    )
}

private func siblingScrollInventoryInterface(
    totalElementCount: Int,
    materializedElementCounts: [Int]
) throws -> Interface {
    let tree = materializedElementCounts.enumerated().map { containerIndex, materializedElementCount in
        AccessibilityHierarchy.container(
            makeTestScrollableContainer(
                contentWidth: 390,
                contentHeight: 1_200,
                frameWidth: 390,
                frameHeight: 400
            ),
            children: (0..<materializedElementCount).map { elementIndex in
                AccessibilityHierarchy.element(
                    makeTestAccessibilityElement(
                        makeTestHeistElement(label: "Row \(containerIndex)-\(elementIndex)")
                    ),
                    traversalIndex: elementIndex
                )
            }
        )
    }
    let inventory = try XCTUnwrap(ScrollInventory(totalElementCount: totalElementCount))
    let annotations = materializedElementCounts.indices.map { index in
        InterfaceContainerAnnotation(
            path: TreePath([index]),
            containerName: ContainerName(stringLiteral: "inventory_scroll_\(index)"),
            scrollInventory: inventory
        )
    }
    return try Interface(
        timestamp: Date(timeIntervalSince1970: 0),
        tree: tree,
        annotations: InterfaceAnnotations(containers: annotations)
    )
}

private func publicInterfaceContractDTO(
    _ interface: Interface,
    detail: InterfaceDetail = .summary
) throws -> PublicInterfaceContractDTO {
    let data = try JSONEncoder().encode(publicInterfaceProjection(interface: interface, detail: detail))
    return try JSONDecoder().decode(PublicInterfaceContractDTO.self, from: data)
}

private struct PublicInterfaceContractDTO: Decodable {
    let tree: [PublicInterfaceTreeNodeContractDTO]

    var topLevelContainers: [PublicInterfaceContainerContractDTO] {
        tree.compactMap(\.container)
    }
}

private struct PublicInterfaceTreeNodeContractDTO: Decodable {
    let container: PublicInterfaceContainerContractDTO?
}

private struct PublicInterfaceContainerContractDTO: Decodable {
    let type: String
    let label: String?
    let value: String?
    let identifier: String?
    let rowCount: Int?
    let columnCount: Int?
    let actions: [String]?
    let contentWidth: Double?
    let contentHeight: Double?
    let scrollAxis: String?
    let pageScrollsY: Int?
    let containerName: String?
    let children: [PublicInterfaceTreeNodeContractDTO]
}
