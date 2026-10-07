import AccessibilitySnapshotModel
import ButtonHeistTestSupport
import ThePlans
import XCTest
@testable import TheScore

/// Wire-shape tests for the public `Interface` tree.
///
/// The canonical wire payload is the parser's full-fidelity hierarchy plus
/// Button Heist annotations. These tests pin the accepted public shape.
final class AccessibilityHierarchyWireShapeTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testElementLeafCarriesParserElementAndTraversalIndex() throws {
        let element = sampleElement(label: "OK")
        let interface = makeTestInterface(nodes: [testElement(element)])

        let payload = try encodeInterfacePayload(interface)

        let tree = try payload.array("tree")
        let elementPayload = try XCTUnwrap(tree.first).object("element")
        XCTAssertEqual(try elementPayload.string("description"), "Button")
        XCTAssertEqual(try elementPayload.string("label"), "OK")
        XCTAssertEqual(try elementPayload.int("traversalIndex"), 0)
        try payload.assertMissing("elements")
    }

    func testPathIndexedElementsReturnNamedRecords() {
        let interface = makeTestInterface(nodes: [
            testContainer(
                makeTestAccessibilityContainer(type: .list),
                children: [
                    testElement(sampleElement(label: "First")),
                    testElement(sampleElement(label: "Second")),
                ]
            ),
        ])

        let indexed: [PathIndexedAccessibilityElement] = interface.tree.pathIndexedElements

        XCTAssertEqual(indexed.map(\.path), [TreePath([0, 0]), TreePath([0, 1])])
        XCTAssertEqual(indexed.map(\.traversalIndex), [0, 1])
        XCTAssertEqual(indexed.map(\.element.label), ["First", "Second"])
    }

    func testPathIndexedContainersReturnNamedRecordsInPreorder() {
        let rootContainer = makeTestAccessibilityContainer(type: .landmark)
        let nestedScrollable = makeTestAccessibilityContainer(
            type: .none,
            scrollableContentSize: AccessibilitySize(width: 100, height: 400)
        )
        let siblingContainer = makeTestAccessibilityContainer(type: .list)
        let interface = makeTestInterface(nodes: [
            testContainer(
                rootContainer,
                children: [
                    testElement(sampleElement(label: "First")),
                    testContainer(
                        nestedScrollable,
                        children: [testElement(sampleElement(label: "Nested"))]
                    ),
                ]
            ),
            testContainer(
                siblingContainer,
                children: [testElement(sampleElement(label: "Sibling"))]
            ),
        ])

        let indexed: [PathIndexedAccessibilityContainer] = interface.tree.pathIndexedContainers

        XCTAssertEqual(indexed.map(\.path), [TreePath([0]), TreePath([0, 1]), TreePath([1])])
        XCTAssertEqual(indexed.map(\.container), [rootContainer, nestedScrollable, siblingContainer])
        XCTAssertEqual(interface.tree.scrollablePathIndexedContainers.map(\.path), [TreePath([0, 1])])
    }

    func testContainerCarriesParserContainerAndChildren() throws {
        let interface = makeTestInterface(nodes: [
            testContainer(
                makeTestAccessibilityContainer(type: .list, frameWidth: 320, frameHeight: 200),
                children: [testElement(sampleElement())]
            ),
        ])

        let payload = try encodeInterfacePayload(interface)

        let tree = try payload.array("tree")
        let containerPayload = try XCTUnwrap(tree.first).object("container")
        let type = try containerPayload.object("type")
        try type.assertPresent("list")
        let size = try containerPayload.object("frame").object("size")
        XCTAssertEqual(try size.double("width"), 320)
        XCTAssertEqual(try size.double("height"), 200)
        XCTAssertTrue(try containerPayload.array("customActions").isEmpty)
        let children = try containerPayload.array("children")
        XCTAssertEqual(children.count, 1)
    }

    func testInterfaceCarriesTreePlusAnnotations() throws {
        let header = sampleElement(label: "Header")
        let row = sampleElement(label: "Row 0")
        let interface = makeTestInterface(nodes: [
            testElement(header),
            testContainer(
                makeTestAccessibilityContainer(type: .list, frameY: 50, frameWidth: 320, frameHeight: 400),
                containerName: "list_0",
                children: [testElement(row)]
            ),
        ])

        let payload = try encodeInterfacePayload(interface)

        let tree = try payload.array("tree")
        XCTAssertEqual(tree.count, 2)
        try tree[0].assertPresent("element")
        try tree[1].assertPresent("container")
        try payload.assertMissing("elements")

        let annotations = try payload.object("annotations")
        let elements = try annotations.array("elements")
        XCTAssertEqual(elements.count, 2)
        try XCTUnwrap(elements.first).assertMissing("heistId")
        let containers = try annotations.array("containers")
        XCTAssertEqual(try XCTUnwrap(containers.first).string("containerName"), "list_0")
    }

    func testNestedInterfaceRoundTripsThroughCanonicalHierarchy() throws {
        let element = sampleElement(label: "Row")
        let original = makeTestInterface(nodes: [
            testContainer(
                makeTestAccessibilityContainer(
                    type: .none, scrollableContentSize: AccessibilitySize(width: 320, height: 1000),
                    frameWidth: 320,
                    frameHeight: 480
                ),
                containerName: "scroll",
                children: [
                    testContainer(
                        makeTestAccessibilityContainer(type: .landmark, frameWidth: 320, frameHeight: 100),
                        containerName: "landmark",
                        children: [testElement(element)]
                    ),
                ]
            ),
        ])

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Interface.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.projectedElements, [element])
    }

    func testInterfaceAdmissionRejectsMalformedRawHierarchyGeometry() {
        let invalidNodes: [AccessibilityHierarchy] = [
            .element(parsedElement(shape: .frame(AccessibilityRect(x: 0, y: 0, width: -1, height: 44))),
                     traversalIndex: 0),
            .element(parsedElement(shape: .path([
                .move(to: AccessibilityPoint(x: .nan, y: 0)),
            ])), traversalIndex: 0),
            .element(parsedElement(
                shape: .frame(.zero),
                activationPoint: AccessibilityPoint(x: .infinity, y: 0)
            ), traversalIndex: 0),
            .element(parsedElement(
                shape: .frame(.zero),
                customRotors: [AccessibilityElement.CustomRotor(
                    name: "Errors",
                    resultMarkers: [.init(
                        elementDescription: "Error",
                        shape: .frame(AccessibilityRect(x: 0, y: 0, width: 10, height: -.infinity))
                    )]
                )]
            ), traversalIndex: 0),
            .container(AccessibilityContainer(
                type: .none,
                scrollableContentSize: AccessibilitySize(width: -1, height: 100),
                frame: .zero
            ), children: []),
            .container(AccessibilityContainer(
                type: .scrollable(contentSize: AccessibilitySize(width: 100, height: -.infinity)),
                frame: .zero
            ), children: []),
        ]

        for node in invalidNodes {
            XCTAssertThrowsError(try Interface(
                timestamp: Date(timeIntervalSince1970: 0),
                tree: [node],
                annotations: .empty
            )) { error in
                XCTAssertTrue(error is InterfaceGeometryAdmissionError)
            }
        }
    }

    func testAdmittedPathGeometrySurvivesResponseEnvelopeRoundTrip() throws {
        let path: [AccessibilityPathElement] = [
            .move(to: AccessibilityPoint(x: -20, y: 10)),
            .quadCurve(
                to: AccessibilityPoint(x: 40, y: 50),
                control: AccessibilityPoint(x: 5, y: 80)
            ),
            .closeSubpath,
        ]
        let interface = makeTestInterface(nodes: [
            .parsedElement(parsedElement(shape: .path(path)), actions: [.activate]),
        ])

        let data = try encoder.encode(ResponseEnvelope(message: .interface(interface)))
        let decoded = try decoder.decode(ResponseEnvelope.self, from: data)

        guard case .interface(let decodedInterface) = decoded.message,
              case .element(let decodedElement, _) = decodedInterface.tree.first,
              case .path(let decodedPath) = decodedElement.shape else {
            return XCTFail("Expected path geometry in decoded interface envelope")
        }
        XCTAssertEqual(decodedPath, path)
    }

    func testInterfaceWireDecodingRejectsMalformedContainerGeometry() throws {
        let original = makeTestInterface(nodes: [
            testContainer(
                makeTestAccessibilityContainer(type: .list, frameWidth: 320, frameHeight: 200),
                children: []
            ),
        ])
        let canonicalPayload = try decoder.decode(JSONValue.self, from: encoder.encode(original))
        let malformedPayload = try XCTUnwrap(replacingFirstObjectValue(
            forKey: "width",
            in: canonicalPayload,
            with: .int(-1)
        ))

        XCTAssertThrowsError(try decoder.decode(Interface.self, from: encoder.encode(malformedPayload)))
    }

    func testInterfaceWireDecodingRejectsUnknownNestedGeometryKey() throws {
        let original = makeTestInterface(nodes: [
            testElement(sampleElement()),
        ])
        let canonicalPayload = try decoder.decode(JSONValue.self, from: encoder.encode(original))
        let malformedPayload = try XCTUnwrap(addingFirstObjectValue(
            .int(0),
            forKey: "legacyFrame",
            toObjectForKey: "shape",
            in: canonicalPayload
        ))

        XCTAssertThrowsError(try decoder.decode(Interface.self, from: encoder.encode(malformedPayload))) { error in
            XCTAssertTrue("\(error)".contains("legacyFrame"), "\(error)")
        }
    }

    func testInterfaceContainerRejectsMissingCustomActionsPayload() throws {
        let original = makeTestInterface(nodes: [
            testContainer(
                makeTestAccessibilityContainer(type: .list, frameWidth: 320, frameHeight: 200),
                children: []
            ),
        ])
        let canonicalPayload = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(original))
        let legacyPayload = try XCTUnwrap(removingFirstObjectValue(
            forKey: "customActions",
            in: canonicalPayload
        ))
        let legacyData = try JSONEncoder().encode(legacyPayload)

        XCTAssertThrowsError(try decoder.decode(Interface.self, from: legacyData)) { error in
            XCTAssertTrue("\(error)".contains("customActions"), "\(error)")
        }
    }

    func testNodeLookupHandlesRootAndInvalidPaths() {
        let leaf = AccessibilityHierarchy.element(
            makeTestAccessibilityElement(sampleElement(label: "Leaf")),
            traversalIndex: 7
        )
        let root = AccessibilityHierarchy.container(
            makeTestAccessibilityContainer(type: .list),
            children: [leaf]
        )

        XCTAssertEqual(root.node(at: .root), root)
        XCTAssertEqual(root.node(at: TreePath([0])), leaf)
        XCTAssertNil(root.node(at: TreePath([1])))
        XCTAssertNil(leaf.node(at: TreePath([0])))
    }

    func testForestNodeLookupHandlesRootsNestedPathsAndInvalidRootPath() {
        let standalone = AccessibilityHierarchy.element(
            makeTestAccessibilityElement(sampleElement(label: "Standalone")),
            traversalIndex: 0
        )
        let nestedLeaf = AccessibilityHierarchy.element(
            makeTestAccessibilityElement(sampleElement(label: "Nested")),
            traversalIndex: 1
        )
        let container = AccessibilityHierarchy.container(
            makeTestAccessibilityContainer(type: .landmark),
            children: [nestedLeaf]
        )
        let forest = [standalone, container]

        XCTAssertNil(forest.node(at: .root))
        XCTAssertEqual(forest.node(at: TreePath([0])), standalone)
        XCTAssertEqual(forest.node(at: TreePath([1])), container)
        XCTAssertEqual(forest.node(at: TreePath([1, 0])), nestedLeaf)
        XCTAssertNil(forest.node(at: TreePath([2])))
        XCTAssertNil(forest.node(at: TreePath([1, 1])))
    }

    func testTreePathHelpersExposeParentAndRelativePaths() {
        let path = TreePath([2, 4, 6])

        XCTAssertEqual(path.parent, TreePath([2, 4]))
        XCTAssertEqual(TreePath([2]).parent, .root)
        XCTAssertNil(TreePath.root.parent)
        XCTAssertEqual(path.removingPrefix(TreePath([2])), TreePath([4, 6]))
        XCTAssertEqual(path.relative(to: TreePath([2, 4])), TreePath([6]))
        XCTAssertNil(path.removingPrefix(TreePath([3])))
    }

    func testTreePathAdmissionRejectsNegativeIndices() throws {
        XCTAssertEqual(TreePath(validating: [0, 2])?.indices, [0, 2])
        XCTAssertNil(TreePath(validating: [0, -1]))
        XCTAssertThrowsError(try decoder.decode(TreePath.self, from: Data(#"{"indices":[0,-1]}"#.utf8)))
    }

    func testInterfaceDiagnosticsRoundTripThroughCanonicalWireShape() throws {
        let diagnostics = InterfaceDiagnostics(discovery: InterfaceDiscoveryDiagnostics(
            state: .limited,
            reasonCodes: [.discoveryScrollLimit],
            includedElementCount: 3,
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
                    viewportWidth: 320,
                    viewportHeight: 400,
                    contentWidth: 320,
                    contentHeight: 1_200
                ),
            ],
            nextAction: "Retry get_interface with a higher maxScrollsPerDiscovery."
        ))
        let original = makeTestInterface(elements: [sampleElement(label: "Row")])
            .withDiagnostics(diagnostics)

        let payload = try encodeInterfacePayload(original)
        let encodedDiscovery = try payload.object("diagnostics").object("discovery")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Interface.self, from: data)

        XCTAssertEqual(try encodedDiscovery.string("state"), "limited")
        XCTAssertEqual(try encodedDiscovery.strings("reasonCodes"), ["scroll-attempt-budget"])
        XCTAssertEqual(decoded, original)
    }

    func testOmittedContainerDiagnosticsUseCanonicalSortOrder() {
        let unnamed = InterfaceDiscoveryOmittedContainer(
            type: .none,
            reasonCodes: [],
            viewportWidth: 320,
            viewportHeight: 400
        )
        let namedList = InterfaceDiscoveryOmittedContainer(
            containerName: "main",
            type: .list,
            reasonCodes: [],
            viewportWidth: 500,
            viewportHeight: 400
        )
        let namedScrollableNarrow = InterfaceDiscoveryOmittedContainer(
            containerName: "main",
            type: .none,
            reasonCodes: [],
            viewportWidth: 320,
            viewportHeight: 400
        )
        let namedScrollableWide = InterfaceDiscoveryOmittedContainer(
            containerName: "main",
            type: .none,
            reasonCodes: [],
            viewportWidth: 500,
            viewportHeight: 400
        )
        let laterName = InterfaceDiscoveryOmittedContainer(
            containerName: "secondary",
            type: .none,
            reasonCodes: [],
            viewportWidth: 100,
            viewportHeight: 100
        )

        XCTAssertEqual(
            [namedScrollableWide, laterName, namedScrollableNarrow, unnamed, namedList].sorted(),
            [unnamed, namedList, namedScrollableNarrow, namedScrollableWide, laterName]
        )
    }

    func testPublicNumericEvidenceRejectsMalformedValues() throws {
        XCTAssertNil(ScrollInventory(totalElementCount: -1))
        XCTAssertNil(InterfaceDiscoveryDiagnostics(
            state: .complete,
            includedElementCount: -1,
            scrollAttempts: 0,
            maxScrollsPerDiscovery: 1,
            maxScrollsPerContainer: 1,
            exploredScrollableContainerCount: 0,
            omittedScrollableContainerCount: 0
        ))
        XCTAssertNil(InterfaceDiscoveryDiagnostics(
            state: .complete,
            reasonCodes: [.discoveryScrollLimit],
            includedElementCount: 0,
            scrollAttempts: 0,
            maxScrollsPerDiscovery: 1,
            maxScrollsPerContainer: 1,
            exploredScrollableContainerCount: 0,
            omittedScrollableContainerCount: 0
        ))
        XCTAssertNil(InterfaceDiscoveryDiagnostics(
            state: .limited,
            includedElementCount: 0,
            scrollAttempts: 0,
            maxScrollsPerDiscovery: 1,
            maxScrollsPerContainer: 1,
            exploredScrollableContainerCount: 0,
            omittedScrollableContainerCount: 1,
            omittedContainers: []
        ))

        let negativeInventory = #"{"totalElementCount":-1}"#
        let negativeDiagnostics = """
        {
          "state":"complete",
          "reasonCodes":[],
          "includedElementCount":0,
          "scrollAttempts":-1,
          "maxScrollsPerDiscovery":1,
          "maxScrollsPerContainer":1,
          "exploredScrollableContainerCount":0,
          "omittedScrollableContainerCount":0,
          "omittedContainers":[]
        }
        """
        let inconsistentDiagnostics = """
        {
          "state":"complete",
          "reasonCodes":["scroll-attempt-budget"],
          "includedElementCount":0,
          "scrollAttempts":0,
          "maxScrollsPerDiscovery":1,
          "maxScrollsPerContainer":1,
          "exploredScrollableContainerCount":0,
          "omittedScrollableContainerCount":0,
          "omittedContainers":[]
        }
        """

        XCTAssertThrowsError(try decoder.decode(ScrollInventory.self, from: Data(negativeInventory.utf8)))
        XCTAssertThrowsError(
            try decoder.decode(InterfaceDiscoveryDiagnostics.self, from: Data(negativeDiagnostics.utf8))
        )
        XCTAssertThrowsError(
            try decoder.decode(InterfaceDiscoveryDiagnostics.self, from: Data(inconsistentDiagnostics.utf8))
        )
    }

    func testTypedGeometryRejectsNegativeAndNonFiniteDimensions() throws {
        let negative = #"{"x":0,"y":0,"width":-1,"height":44}"#
        let nonFinite = #"{"x":0,"y":0,"width":"Infinity","height":44}"#
        let nonFiniteDecoder = JSONDecoder()
        nonFiniteDecoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        XCTAssertThrowsError(try decoder.decode(ScreenRect.self, from: Data(negative.utf8)))
        XCTAssertThrowsError(try nonFiniteDecoder.decode(ScreenRect.self, from: Data(nonFinite.utf8)))
        XCTAssertThrowsError(try decoder.decode(ViewRect.self, from: Data(negative.utf8)))
    }

    private func encodeInterfacePayload(_ interface: Interface) throws -> JSONProbe {
        let envelope = ResponseEnvelope(message: .interface(interface))
        let data = try encoder.encode(envelope)
        return try JSONProbe(data: data).object("payload")
    }

    private func replacingFirstObjectValue(
        forKey key: String,
        in value: JSONValue,
        with replacement: JSONValue
    ) -> JSONValue? {
        switch value {
        case .object(var object):
            if object[key] != nil {
                object[key] = replacement
                return .object(object)
            }
            for childKey in Array(object.keys) {
                guard let child = object[childKey],
                      let replaced = replacingFirstObjectValue(forKey: key, in: child, with: replacement)
                else { continue }
                object[childKey] = replaced
                return .object(object)
            }
            return nil
        case .array(let values):
            for index in values.indices {
                guard let replaced = replacingFirstObjectValue(forKey: key, in: values[index], with: replacement)
                else { continue }
                var updated = values
                updated[index] = replaced
                return .array(updated)
            }
            return nil
        case .string, .int, .double, .bool, .null:
            return nil
        }
    }

    private func removingFirstObjectValue(
        forKey key: String,
        in value: JSONValue
    ) -> JSONValue? {
        switch value {
        case .object(var object):
            if object.removeValue(forKey: key) != nil {
                return .object(object)
            }
            for childKey in Array(object.keys) {
                guard let child = object[childKey],
                      let removed = removingFirstObjectValue(forKey: key, in: child)
                else { continue }
                object[childKey] = removed
                return .object(object)
            }
            return nil
        case .array(let values):
            for index in values.indices {
                guard let removed = removingFirstObjectValue(forKey: key, in: values[index])
                else { continue }
                var updated = values
                updated[index] = removed
                return .array(updated)
            }
            return nil
        case .string, .int, .double, .bool, .null:
            return nil
        }
    }

    private func addingFirstObjectValue(
        _ value: JSONValue,
        forKey key: String,
        toObjectForKey objectKey: String,
        in payload: JSONValue
    ) -> JSONValue? {
        switch payload {
        case .object(var object):
            if case .object(var nested)? = object[objectKey] {
                nested[key] = value
                object[objectKey] = .object(nested)
                return .object(object)
            }
            for childKey in Array(object.keys) {
                guard let child = object[childKey],
                      let updated = addingFirstObjectValue(
                          value,
                          forKey: key,
                          toObjectForKey: objectKey,
                          in: child
                      ) else { continue }
                object[childKey] = updated
                return .object(object)
            }
            return nil
        case .array(let values):
            for index in values.indices {
                guard let updated = addingFirstObjectValue(
                    value,
                    forKey: key,
                    toObjectForKey: objectKey,
                    in: values[index]
                ) else { continue }
                var copy = values
                copy[index] = updated
                return .array(copy)
            }
            return nil
        case .string, .int, .double, .bool, .null:
            return nil
        }
    }

    private func parsedElement(
        shape: AccessibilityShape,
        activationPoint: AccessibilityPoint = .zero,
        customRotors: [AccessibilityElement.CustomRotor] = []
    ) -> AccessibilityElement {
        AccessibilityElement(
            description: "Element",
            label: "Element",
            value: nil,
            traits: .button,
            identifier: nil,
            hint: nil,
            userInputLabels: nil,
            shape: shape,
            activationPoint: activationPoint,
            usesDefaultActivationPoint: true,
            customActions: [],
            customContent: [],
            customRotors: customRotors,
            accessibilityLanguage: nil,
            respondsToUserInteraction: true
        )
    }

    private func sampleElement(
        label: String? = "OK"
    ) -> HeistElement {
        makeTestHeistElement(
            description: "Button",
            label: label,
            value: nil,
            identifier: nil,
            frameX: 0,
            frameY: 0,
            frameWidth: 100,
            frameHeight: 44,
            actions: [.activate]
        )
    }
}
