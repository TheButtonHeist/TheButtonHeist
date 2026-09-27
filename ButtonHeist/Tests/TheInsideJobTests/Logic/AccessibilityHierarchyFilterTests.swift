#if canImport(UIKit)
import XCTest
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob

@MainActor
final class AccessibilityHierarchyFilterTests: XCTestCase {

    // MARK: - Fixtures

    private func element(
        label: String,
        value: String? = nil,
        traits: UIAccessibilityTraits = .none,
        index: Int = 0
    ) -> AccessibilityHierarchy {
        .element(
            .make(label: label, value: value, traits: traits),
            traversalIndex: index
        )
    }

    private func group(
        label: String? = nil,
        children: [AccessibilityHierarchy]
    ) -> AccessibilityHierarchy {
        .container(
            AccessibilityContainer(
                type: .semanticGroup(label: label, value: nil), identifier: nil,
                frame: .zero
            ),
            children: children
        )
    }

    private func scrollable(
        children: [AccessibilityHierarchy]
    ) -> AccessibilityHierarchy {
        .container(
            AccessibilityContainer(
                type: .none, scrollableContentSize: AccessibilitySize(width: 320, height: 1000),
                frame: .zero
            ),
            children: children
        )
    }

    private func tabBar(
        children: [AccessibilityHierarchy]
    ) -> AccessibilityHierarchy {
        .container(
            AccessibilityContainer(type: .tabBar, frame: .zero),
            children: children
        )
    }

    /// Extracts the label from an element node, nil for containers.
    private func label(of node: AccessibilityHierarchy) -> String? {
        if case let .element(e, _) = node { return e.label }
        return nil
    }

    // MARK: - Elements & Containers Extraction

    func testElementsCountsLeaves() {
        let tree = group(children: [
            element(label: "A", index: 0),
            group(children: [
                element(label: "B", index: 1),
                element(label: "C", index: 2),
            ]),
        ])

        XCTAssertEqual(tree.elements.count, 3)
    }

    func testContainersCountsAllContainers() {
        let tree = group(children: [
            group(children: [element(label: "A")]),
            group(children: []),
        ])

        XCTAssertEqual(tree.containers.count, 3, "Root + 2 inner containers")
    }

    func testElementsCollectsLabelsInTraversalOrder() {
        let tree = group(children: [
            element(label: "A", index: 0),
            element(label: "B", index: 1),
            group(children: [
                element(label: "C", index: 2),
            ]),
        ])

        let labels = tree.elements.compactMap(\.element.label)
        XCTAssertEqual(labels, ["A", "B", "C"])
    }

    func testFoldedComputesMaxTraversalIndex() {
        let tree = group(children: [
            element(label: "A", index: 3),
            group(children: [
                element(label: "B", index: 7),
                element(label: "C", index: 1),
            ]),
        ])

        let maxIndex = tree.folded(
            onElement: { _, traversalIndex in traversalIndex },
            onContainer: { _, childMaxes in childMaxes.max() ?? Int.min }
        )
        XCTAssertEqual(maxIndex, 7)
    }

    func testFoldedComputesTreeDepth() {
        let tree = group(children: [
            element(label: "shallow", index: 0),
            group(children: [
                group(children: [
                    element(label: "deep", index: 1),
                ]),
            ]),
        ])

        let depth: Int = tree.folded(
            onElement: { _, _ in 1 },
            onContainer: { _, childDepths in 1 + (childDepths.max() ?? 0) }
        )
        XCTAssertEqual(depth, 4, "Root > group > group > element")
    }

    func testCompactMapFindsButtonElements() {
        let tree = group(children: [
            element(label: "Title", traits: .header),
            element(label: "OK", traits: .button),
        ])

        let buttons: [String] = [tree].compactMap(
            context: (),
            container: { _, _ in () },
            element: { element, _, _ in
                element.traits.contains(.button) ? element.label : nil
            }
        )
        XCTAssertEqual(buttons, ["OK"])
    }

    func testElementsOnSingleElement() {
        let node = element(label: "Solo", index: 0)
        XCTAssertEqual(node.elements.count, 1)
    }

    func testElementsOnArray() {
        let roots: [AccessibilityHierarchy] = [
            element(label: "A", index: 0),
            group(children: [
                element(label: "B", index: 1),
            ]),
        ]

        XCTAssertEqual(roots.elements.count, 2)
    }

    func testElementsOnEmptyArray() {
        let roots: [AccessibilityHierarchy] = []
        XCTAssertEqual(roots.elements.count, 0)
    }

    func testElementsVisitsAllRoots() {
        let roots: [AccessibilityHierarchy] = [
            group(children: [element(label: "A")]),
            group(children: [element(label: "B")]),
            group(children: [element(label: "C")]),
        ]

        let labels = roots.elements.compactMap(\.element.label)
        XCTAssertEqual(labels, ["A", "B", "C"])
    }

    func testContainersOnEmptyContainer() {
        let tree = group(children: [])
        XCTAssertEqual(tree.containers.count, 1, "Just the container itself")
    }

    // MARK: - CompactMap with Context

    func testCompactMapCollectsTransformedElements() {
        let tree = group(children: [
            element(label: "A", index: 0),
            element(label: "B", index: 1),
            element(label: "C", index: 2),
        ])

        let result: [String] = [tree].compactMap(
            context: (),
            container: { _, _ in () },
            element: { element, _, _ in element.label }
        )

        XCTAssertEqual(result, ["A", "B", "C"])
    }

    func testCompactMapFiltersNilResults() {
        let tree = group(children: [
            element(label: "Keep", traits: .button, index: 0),
            element(label: "Drop", index: 1),
            element(label: "Also Keep", traits: .button, index: 2),
        ])

        let result: [String] = [tree].compactMap(
            context: (),
            container: { _, _ in () },
            element: { element, _, _ in
                element.traits.contains(.button) ? element.label : nil
            }
        )

        XCTAssertEqual(result, ["Keep", "Also Keep"])
    }

    func testCompactMapPropagatesContainerContext() {
        let tree = scrollable(children: [
            element(label: "Row", index: 0),
        ])

        let result: [(String, Bool)] = [tree].compactMap(
            context: false,
            container: { _, container in container.isScrollable },
            element: { element, _, isScrollable in
                (element.label ?? "?", isScrollable)
            }
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].0, "Row")
        XCTAssertTrue(result[0].1, "Element should inherit scrollable context")
    }

    func testCompactMapChainsContextThroughNestedContainers() {
        let tree = group(label: "Root", children: [
            group(label: "Section", children: [
                element(label: "Item", index: 0),
            ]),
        ])

        let result: [String] = [tree].compactMap(
            context: "",
            container: { context, container in
                if case let .semanticGroup(label, _) = container.type {
                    return context.isEmpty ? (label ?? "") : context + "/" + (label ?? "")
                }
                return context
            },
            element: { element, _, context in
                context + "/" + (element.label ?? "?")
            }
        )

        XCTAssertEqual(result, ["Root/Section/Item"])
    }

    func testCompactMapOnSingleElement() {
        let node = element(label: "Solo", index: 5)

        let result: [String] = [node].compactMap(
            context: "ctx",
            container: { context, _ in context },
            element: { element, traversalIndex, context in
                "\(context):\(element.label ?? "?"):\(traversalIndex)"
            }
        )

        XCTAssertEqual(result, ["ctx:Solo:5"])
    }

    func testCompactMapOnSingleElementReturningNil() {
        let node = element(label: "Solo", index: 0)

        let result: [String] = [node].compactMap(
            context: (),
            container: { _, _ in () },
            element: { _, _, _ in nil }
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testCompactMapOnEmptyContainer() {
        let tree = group(label: "Empty", children: [])

        let result: [String] = [tree].compactMap(
            context: (),
            container: { _, _ in () },
            element: { element, _, _ in element.label }
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testCompactMapOnArrayCollectsAcrossRoots() {
        let roots: [AccessibilityHierarchy] = [
            group(children: [element(label: "A", index: 0)]),
            group(children: [element(label: "B", index: 1)]),
            element(label: "C", index: 2),
        ]

        let result: [String] = roots.compactMap(
            context: (),
            container: { _, _ in () },
            element: { element, _, _ in element.label }
        )

        XCTAssertEqual(result, ["A", "B", "C"])
    }

    func testCompactMapOnEmptyArray() {
        let roots: [AccessibilityHierarchy] = []

        let result: [String] = roots.compactMap(
            context: "ignored",
            container: { context, _ in context },
            element: { element, _, _ in element.label }
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testCompactMapContextIsolatedPerBranch() {
        let tree = group(children: [
            scrollable(children: [
                element(label: "Scrolled", index: 0),
            ]),
            group(label: "Static", children: [
                element(label: "Fixed", index: 1),
            ]),
        ])

        let result: [(String, Bool)] = [tree].compactMap(
            context: false,
            container: { _, container in container.isScrollable },
            element: { element, _, isScrollable in
                (element.label ?? "?", isScrollable)
            }
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].0, "Scrolled")
        XCTAssertTrue(result[0].1)
        XCTAssertEqual(result[1].0, "Fixed")
        XCTAssertFalse(result[1].1)
    }

}
#endif
