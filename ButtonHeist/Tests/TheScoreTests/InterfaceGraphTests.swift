import AccessibilitySnapshotModel
import ButtonHeistTestSupport
import Foundation
import ThePlans
import XCTest
@testable import TheScore

final class InterfaceGraphTests: XCTestCase {

    func testStableTraversalAndPathLookup() throws {
        let first = makeElement(label: "First")
        let second = makeElement(label: "Second")
        let third = makeElement(label: "Third")
        let tree: [AccessibilityHierarchy] = [
            .container(makeTestAccessibilityContainer(type: .list), children: [
                .element(makeTestAccessibilityElement(second), traversalIndex: 2),
                .container(makeTestAccessibilityContainer(type: .landmark), children: [
                    .element(makeTestAccessibilityElement(first), traversalIndex: 0),
                ]),
            ]),
            .element(makeTestAccessibilityElement(third), traversalIndex: 1),
        ]

        let graph = try Interface(
            timestamp: Date(timeIntervalSince1970: 1),
            tree: tree,
            annotations: InterfaceAnnotations(elements: [
                InterfaceElementAnnotation(
                    path: TreePath([0, 0]),
                    actions: second.semantics.assertable.orderedActions,
                    geometry: second.geometry
                ),
                InterfaceElementAnnotation(
                    path: TreePath([0, 1, 0]),
                    actions: first.semantics.assertable.orderedActions,
                    geometry: first.geometry
                ),
                InterfaceElementAnnotation(
                    path: TreePath([1]),
                    actions: third.semantics.assertable.orderedActions,
                    geometry: third.geometry
                ),
            ])
        ).graph

        XCTAssertEqual(graph.elementsInTraversalOrder.map(\.path), [
            TreePath([0, 1, 0]),
            TreePath([1]),
            TreePath([0, 0]),
        ])
        XCTAssertEqual(graph.elementsInTraversalOrder.map(\.projectedElement.semantics.assertable.label), [
            "First",
            "Third",
            "Second",
        ])
        let containerPaths = graph.nodesInPathOrder.compactMap { record -> TreePath? in
            guard case .container = record.kind else { return nil }
            return record.path
        }
        XCTAssertEqual(containerPaths, [
            TreePath([0]),
            TreePath([0, 1]),
        ])
        XCTAssertEqual(graph.node(at: TreePath([0, 1, 0])), tree[0].node(at: TreePath([1, 0])))
        XCTAssertNil(graph.node(at: TreePath([9])))
    }

    func testHierarchyGraphRetainsEmptyContainersAndDuplicateSemanticNodes() {
        let duplicate = makeTestAccessibilityElement(makeElement(label: "Duplicate"))
        let empty = makeTestAccessibilityContainer(type: .semanticGroup(label: "Empty", value: nil))
        let nested = makeTestAccessibilityContainer(type: .landmark)
        let root = makeTestAccessibilityContainer(type: .list)
        let tree: [AccessibilityHierarchy] = [
            .container(root, children: [
                .container(empty, children: []),
                .element(duplicate, traversalIndex: 2),
                .container(nested, children: [
                    .element(duplicate, traversalIndex: 2),
                ]),
            ]),
        ]

        let graph = AccessibilityHierarchyGraph(tree: tree)

        XCTAssertEqual(graph.nodesInPathOrder.map(\.path), [
            TreePath([0]),
            TreePath([0, 0]),
            TreePath([0, 1]),
            TreePath([0, 2]),
            TreePath([0, 2, 0]),
        ])
        XCTAssertEqual(graph.node(at: TreePath([0, 0])), .container(empty, children: []))
    }

    func testDuplicateAnnotationPathsRejected() {
        let element = makeElement(label: "Save")
        let annotation = InterfaceElementAnnotation(
            path: TreePath([0]),
            actions: [.activate],
            geometry: element.geometry
        )
        XCTAssertThrowsError(try Interface(
            timestamp: Date(timeIntervalSince1970: 1),
            tree: [.element(makeTestAccessibilityElement(element), traversalIndex: 0)],
            annotations: InterfaceAnnotations(elements: [annotation, annotation])
        )) { error in
            XCTAssertEqual(error as? InterfaceGraphValidationError, .duplicateElementAnnotationPath(TreePath([0])))
        }
    }

    func testAnnotationPathWithoutNodeRejected() {
        let element = makeElement(label: "Save")
        XCTAssertThrowsError(try Interface(
            timestamp: Date(timeIntervalSince1970: 1),
            tree: [.element(makeTestAccessibilityElement(element), traversalIndex: 0)],
            annotations: InterfaceAnnotations(elements: [
                InterfaceElementAnnotation(
                    path: TreePath([1]),
                    actions: [.activate],
                    geometry: element.geometry
                ),
            ])
        )) { error in
            XCTAssertEqual(error as? InterfaceGraphValidationError, .elementAnnotationForMissingPath(TreePath([1])))
        }
    }

    func testAnnotationAndObservationIdentityLookupByPath() throws {
        let save = makeElement(label: "Save")
        let cancel = makeElement(label: "Cancel")
        let savePath = TreePath([0])
        let cancelPath = TreePath([1])
        let saveIdentity = Observation.ElementIdentity("save_button")
        let cancelIdentity = Observation.ElementIdentity("cancel_button")

        let graph = try Interface(
            timestamp: Date(timeIntervalSince1970: 1),
            tree: [
                .element(makeTestAccessibilityElement(save), traversalIndex: 0),
                .element(makeTestAccessibilityElement(cancel), traversalIndex: 1),
            ],
            annotations: InterfaceAnnotations(elements: [
                InterfaceElementAnnotation(
                    path: savePath,
                    actions: [.activate],
                    geometry: save.geometry
                ),
                InterfaceElementAnnotation(
                    path: cancelPath,
                    actions: [],
                    geometry: cancel.geometry
                ),
            ]),
            observationIdentities: InterfaceElementIdentities([
                savePath: saveIdentity,
                cancelPath: cancelIdentity,
            ])
        ).graph

        let saveRecord = graph.elementsInTraversalOrder.first { $0.path == savePath }
        let cancelRecord = graph.elementsInTraversalOrder.first { $0.path == cancelPath }
        XCTAssertEqual(saveRecord?.annotation?.actions, [.activate])
        XCTAssertEqual(saveRecord?.observationIdentity, saveIdentity)
        XCTAssertEqual(cancelRecord?.observationIdentity, cancelIdentity)
    }

    func testElementPathIndexReusesPathDistinctCanonicalRecords() throws {
        let duplicateElement = makeElement(label: "Duplicate")
        let duplicate = makeTestAccessibilityElement(duplicateElement)
        let firstPath = TreePath([0, 0])
        let secondPath = TreePath([0, 1])
        let graph = try Interface(
            timestamp: Date(timeIntervalSince1970: 1),
            tree: [
                .container(makeTestAccessibilityContainer(type: .list), children: [
                    .element(duplicate, traversalIndex: 4),
                    .element(duplicate, traversalIndex: 4),
                ]),
            ],
            annotations: InterfaceAnnotations(elements: [
                InterfaceElementAnnotation(
                    path: firstPath,
                    actions: [.activate],
                    geometry: duplicateElement.geometry
                ),
                InterfaceElementAnnotation(
                    path: secondPath,
                    actions: [.custom("Archive")],
                    geometry: duplicateElement.geometry
                ),
            ]),
            observationIdentities: InterfaceElementIdentities([
                firstPath: Observation.ElementIdentity("duplicate_first"),
                secondPath: Observation.ElementIdentity("duplicate_second"),
            ])
        ).graph

        let first = try XCTUnwrap(graph.element(at: firstPath))
        let second = try XCTUnwrap(graph.element(at: secondPath))
        let indexedNodes = graph.nodesInPathOrder.compactMap { node -> InterfaceGraphElementRecord? in
            guard case .element(let element) = node.kind else { return nil }
            return element
        }

        XCTAssertEqual(graph.elementsInTraversalOrder, [first, second])
        XCTAssertEqual(indexedNodes, [first, second])
        XCTAssertEqual(first.annotation?.actions, [.activate])
        XCTAssertEqual(second.annotation?.actions, [.custom("Archive")])
        XCTAssertEqual(first.observationIdentity, Observation.ElementIdentity("duplicate_first"))
        XCTAssertEqual(second.observationIdentity, Observation.ElementIdentity("duplicate_second"))
        XCTAssertNil(graph.element(at: TreePath([9])))
    }

    func testObservationIdentityPathWithoutElementRejected() {
        XCTAssertThrowsError(try Interface(
            timestamp: Date(timeIntervalSince1970: 1),
            tree: [
                .container(makeTestAccessibilityContainer(type: .list), children: []),
            ],
            observationIdentities: InterfaceElementIdentities([
                TreePath([0]): Observation.ElementIdentity("container_identity"),
            ])
        )) { error in
            XCTAssertEqual(error as? InterfaceGraphValidationError, .observationIdentityForContainerPath(TreePath([0])))
        }
    }

    func testInterfaceDerivesCanonicalGraphProjection() throws {
        let path = TreePath([0])
        let element = makeElement(label: "Save")
        let interface = try Interface(
            timestamp: Date(timeIntervalSince1970: 1),
            tree: [
                .element(makeTestAccessibilityElement(element), traversalIndex: 0),
            ],
            annotations: InterfaceAnnotations(elements: [
                InterfaceElementAnnotation(
                    path: path,
                    actions: [.activate],
                    geometry: element.geometry
                ),
            ])
        )

        let graph = interface.graph

        XCTAssertEqual(graph.node(at: path), interface.tree[0])
        XCTAssertEqual(graph.elementsInTraversalOrder.first?.annotation?.actions, [.activate])
        XCTAssertEqual(interface.projectedElements.map(\.semantics.assertable.label), ["Save"])
    }

    func testProjectedInterfaceDerivesMetadataPathsFromTreeNodes() {
        let tree: [AccessibilityHierarchy] = [
            .container(makeTestAccessibilityContainer(type: .list), children: [
                .element(makeTestAccessibilityElement(makeElement(label: "Save")), traversalIndex: 0),
            ]),
        ]

        let interface: Interface
        do {
            interface = try Interface(
                timestamp: Date(timeIntervalSince1970: 1),
                tree: tree,
                annotations: InterfaceAnnotations(
                    elements: [InterfaceElementAnnotation(
                        path: TreePath([0, 0]),
                        actions: [.activate],
                        geometry: makeElement(label: "Save").geometry
                    )],
                    containers: [InterfaceContainerAnnotation(
                        path: TreePath([0]),
                        containerName: "checkout"
                    )]
                ),
                observationIdentities: InterfaceElementIdentities([
                    TreePath([0, 0]): Observation.ElementIdentity("save_button"),
                ])
            )
        } catch {
            return XCTFail("Test interface fixture failed admission: \(error)")
        }

        let elementPath = TreePath([0, 0])
        let containerPath = TreePath([0])
        XCTAssertEqual(interface.annotations.elements.map(\.path), [elementPath])
        XCTAssertEqual(interface.annotations.containers.map(\.path), [containerPath])
        XCTAssertEqual(interface.graph.element(at: elementPath)?.observationIdentity, Observation.ElementIdentity("save_button"))
        XCTAssertEqual(interface.projectedElements.map(\.semantics.assertable.label), ["Save"])
    }

    func testDecodedInterfaceHasValidatedUsableGraph() throws {
        let path = TreePath([0])
        let element = makeElement(label: "Save")
        let original = try Interface(
            timestamp: Date(timeIntervalSince1970: 1),
            tree: [
                .element(makeTestAccessibilityElement(element), traversalIndex: 0),
            ],
            annotations: InterfaceAnnotations(elements: [
                InterfaceElementAnnotation(
                    path: path,
                    actions: [.activate],
                    geometry: element.geometry
                ),
            ])
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Interface.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.graph.node(at: path), original.tree[0])
        XCTAssertEqual(decoded.graph.elementsInTraversalOrder.first?.annotation?.actions, [.activate])
        XCTAssertEqual(try jsonObject(decoded), try jsonObject(original))
    }

    func testInterfaceDecodeRejectsInvalidGraphInput() throws {
        let element = makeElement(label: "Save")
        let original = try Interface(
            timestamp: Date(timeIntervalSince1970: 1),
            tree: [
                .element(makeTestAccessibilityElement(element), traversalIndex: 0),
            ],
            annotations: InterfaceAnnotations(elements: [
                InterfaceElementAnnotation(
                    path: TreePath([0]),
                    actions: [.activate],
                    geometry: element.geometry
                ),
            ])
        )
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        var annotations = try XCTUnwrap(payload["annotations"] as? [String: Any])
        var elements = try XCTUnwrap(annotations["elements"] as? [[String: Any]])
        elements[0]["path"] = ["indices": [1]]
        annotations["elements"] = elements
        payload["annotations"] = annotations
        let invalidData = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertThrowsError(try JSONDecoder().decode(Interface.self, from: invalidData)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
            XCTAssertEqual(
                context.underlyingError as? InterfaceGraphValidationError,
                .elementAnnotationForMissingPath(TreePath([1]))
            )
        }
    }

    func testInterfaceConstructionValidatesPathIndexedEvidence() {
        let element = makeElement(label: "Save")
        let tree: [AccessibilityHierarchy] = [
            .element(makeTestAccessibilityElement(element), traversalIndex: 0),
        ]

        XCTAssertThrowsError(try Interface(
            timestamp: Date(timeIntervalSince1970: 1),
            tree: tree,
            annotations: InterfaceAnnotations(elements: [
                InterfaceElementAnnotation(
                    path: TreePath([1]),
                    actions: [.activate],
                    geometry: element.geometry
                ),
            ])
        )) { error in
            XCTAssertEqual(
                error as? InterfaceGraphValidationError,
                .elementAnnotationForMissingPath(TreePath([1]))
            )
        }

        XCTAssertThrowsError(try Interface(
            timestamp: Date(timeIntervalSince1970: 1),
            tree: tree,
            observationIdentities: InterfaceElementIdentities([
                TreePath([1]): Observation.ElementIdentity("missing_element"),
            ])
        )) { error in
            XCTAssertEqual(
                error as? InterfaceGraphValidationError,
                .observationIdentityForMissingPath(TreePath([1]))
            )
        }
    }

    func testDerivedGraphAndObservationIdentityRemainOutsideWireAndEqualityContracts() throws {
        let path = TreePath([0])
        let tree: [AccessibilityHierarchy] = [
            .element(makeTestAccessibilityElement(makeElement(label: "Save")), traversalIndex: 0),
        ]
        let plain = Interface(timestamp: Date(timeIntervalSince1970: 1), tree: tree)
        let observed = try Interface(
            timestamp: Date(timeIntervalSince1970: 1),
            tree: tree,
            observationIdentities: InterfaceElementIdentities([
                path: Observation.ElementIdentity("save_button"),
            ])
        )

        XCTAssertEqual(observed, plain)
        XCTAssertNotEqual(observed.graph, plain.graph)
        XCTAssertEqual(try jsonObject(observed), try jsonObject(plain))
        let payload = try jsonObject(observed)
        XCTAssertNil(payload["graph"])
        XCTAssertNil(payload["observationIdentities"])

        let decoded = try JSONDecoder().decode(Interface.self, from: JSONEncoder().encode(observed))
        XCTAssertEqual(decoded.graph, plain.graph)
    }

    private func makeElement(label: String) -> HeistElement {
        makeTestHeistElement(
            description: label,
            label: label,
            activationPointEvidence: .defaultCenter(ScreenPoint(x: 50, y: 22)),
            actions: []
        )
    }

    private func jsonObject(_ interface: Interface) throws -> NSDictionary {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(interface)) as? NSDictionary
        )
    }
}
