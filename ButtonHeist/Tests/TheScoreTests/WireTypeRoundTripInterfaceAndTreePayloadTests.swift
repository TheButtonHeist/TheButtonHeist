import ButtonHeistTestSupport
import XCTest
import ThePlans
import AccessibilitySnapshotModel
@_spi(ButtonHeistInternals) @testable import TheScore

extension WireTypeRoundTripTests {
    // MARK: - AccessibilityContainer

    func testAccessibilityContainerRoundTrip() throws {
        let container = makeTestAccessibilityContainer(
            type: .none, scrollableContentSize: AccessibilitySize(width: 390, height: 1000),
            frameY: 100,
            frameWidth: 390,
            frameHeight: 700
        )
        let data = try encoder.encode(container)
        let decoded = try decoder.decode(AccessibilityContainer.self, from: data)
        XCTAssertEqual(decoded, container)
    }

    func testAccessibilityContainerSemanticGroupRoundTrip() throws {
        let container = makeTestAccessibilityContainer(
            type: .semanticGroup(label: "Settings", value: nil), identifier: "settings",
            frameWidth: 390,
            frameHeight: 100
        )
        let data = try encoder.encode(container)
        let decoded = try decoder.decode(AccessibilityContainer.self, from: data)
        XCTAssertEqual(decoded, container)
    }

    func testAccessibilityContainerModalBoundaryRoundTrip() throws {
        let container = makeTestAccessibilityContainer(
            type: .semanticGroup(label: "Alert", value: nil), identifier: nil,
            frameWidth: 390,
            frameHeight: 300,
            isModalBoundary: true
        )
        let data = try encoder.encode(container)
        let decoded = try decoder.decode(AccessibilityContainer.self, from: data)
        XCTAssertEqual(decoded, container)
    }

    // MARK: - InterfaceQuery

    func testCurrentInterfaceQueryRoundTripsAndRejectsDiscoveryLimits() throws {
        let query = InterfaceQuery(capture: .current, subtree: .label("Editor"))
        let data = try encoder.encode(query)

        XCTAssertEqual(try decoder.decode(InterfaceQuery.self, from: data), query)
        XCTAssertEqual(try JSONProbe(data: data).string("mode"), "current")
        XCTAssertThrowsError(try decoder.decode(
            InterfaceQuery.self,
            from: Data(#"{"mode":"current","maxScrollsPerDiscovery":2}"#.utf8)
        ))
    }

    func testInterfaceQueryDiscoveryLimitsRoundTrip() throws {
        let query = InterfaceQuery(maxScrollsPerContainer: 1, maxScrollsPerDiscovery: 2_000)
        let data = try encoder.encode(query)
        let decoded = try decoder.decode(InterfaceQuery.self, from: data)

        XCTAssertEqual(decoded, query)
    }

    func testInterfaceDiscoveryLimitAdmitsDynamicValues() throws {
        let limit = try InterfaceDiscoveryLimit(validating: 25)
        let query = InterfaceQuery(maxScrollsPerContainer: limit)

        XCTAssertEqual(query.maxScrollsPerContainer?.value, 25)
        XCTAssertThrowsError(try InterfaceDiscoveryLimit(validating: 0))
        XCTAssertThrowsError(try InterfaceDiscoveryLimit(validating: 2_001))
    }

    func testInterfaceQueryRejectsNegativeDiscoveryLimit() {
        let json = #"{"maxScrollsPerContainer":-1}"#

        XCTAssertThrowsError(try decoder.decode(InterfaceQuery.self, from: Data(json.utf8))) { error in
            assertDecodingError(error, contains: ["interface discovery limit must be between 1 and 2000"])
        }
    }

    func testInterfaceQueryRejectsOversizedDiscoveryLimit() {
        let json = #"{"maxScrollsPerDiscovery":2001}"#

        XCTAssertThrowsError(try decoder.decode(InterfaceQuery.self, from: Data(json.utf8))) { error in
            assertDecodingError(error, contains: ["interface discovery limit must be between 1 and 2000"])
        }
    }

    func testInterfaceQueryRejectsRemovedMatcherField() {
        let json = #"""
        {
          "matcher": {
            "checks": [
              { "kind": "identifier", "match": { "mode": "exact", "value": "save" } }
            ]
          }
        }
        """#

        XCTAssertThrowsError(try decoder.decode(InterfaceQuery.self, from: Data(json.utf8))) { error in
            assertDecodingError(error, contains: ["matcher"])
        }
    }

    // MARK: - InterfaceQuery Subtree Targets

    func testInterfaceQueryElementSubtreeUsesCanonicalTargetShape() throws {
        let query = InterfaceQuery(
            subtree: .predicate(ElementPredicate(label: "Save", traits: [.button]), ordinal: 2)
        )

        let data = try encoder.encode(query)
        let payload = try JSONProbe(data: data)
        let subtree = try payload.object("subtree")
        XCTAssertEqual(try subtree.int("ordinal"), 2)
        try subtree.assertMissing("element")
        try subtree.assertMissing("container")
        try subtree.assertMissing("heistId")
        let checks = try subtree.array("checks")
        XCTAssertEqual(checks.count, 2)
        XCTAssertEqual(try checks[0].string("kind"), "label")
        let labelMatch = try checks[0].object("match")
        XCTAssertEqual(try labelMatch.string("mode"), "exact")
        XCTAssertEqual(try labelMatch.string("value"), "Save")
        XCTAssertEqual(try checks[1].string("kind"), "traits")
        XCTAssertEqual(try checks[1].strings("values"), ["button"])
        XCTAssertEqual(try decoder.decode(InterfaceQuery.self, from: data), query)
    }

    func testInterfaceQueryElementSubtreeOmitsAbsentOrdinal() throws {
        let query = InterfaceQuery(subtree: .label("Save"))

        let data = try encoder.encode(query)
        let payload = try JSONProbe(data: data)
        let subtree = try payload.object("subtree")
        try subtree.assertMissing("ordinal")
        try subtree.assertMissing("element")
        try subtree.assertMissing("heistId")
        let checks = try subtree.array("checks")
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(try checks[0].string("kind"), "label")
        let labelMatch = try checks[0].object("match")
        XCTAssertEqual(try labelMatch.string("mode"), "exact")
        XCTAssertEqual(try labelMatch.string("value"), "Save")
        XCTAssertEqual(try decoder.decode(InterfaceQuery.self, from: data), query)
    }

    func testInterfaceQueryContainerSubtreeUsesCanonicalTargetShape() throws {
        let query = InterfaceQuery(
            subtree: .container(
                .matching(.type(.semanticGroup), .semantic(.label("Actions"))),
                ordinal: 1
            )
        )

        let data = try encoder.encode(query)
        let payload = try JSONProbe(data: data)
        let subtree = try payload.object("subtree")
        XCTAssertEqual(try subtree.int("ordinal"), 1)
        let container = try subtree.object("container")
        try subtree.assertMissing("element")
        let checks = try container.array("checks")
        XCTAssertEqual(checks.count, 2)
        XCTAssertEqual(try checks[0].string("kind"), "type")
        XCTAssertEqual(try checks[0].string("type"), "semanticGroup")
        XCTAssertEqual(try checks[1].string("kind"), "semantic")
        let semantic = try checks[1].object("semantic")
        XCTAssertEqual(try semantic.string("kind"), "label")
        let label = try semantic.object("match")
        XCTAssertEqual(try label.string("mode"), "exact")
        XCTAssertEqual(try label.string("value"), "Actions")
        XCTAssertEqual(try decoder.decode(InterfaceQuery.self, from: data), query)
    }

    func testInterfaceQueryContainerSubtreeRequiresPredicateObject() throws {
        let data = Data(#"{"subtree":{"container":"semantic_actions"}}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(InterfaceQuery.self, from: data))
    }

    func testInterfaceQueryContainerSubtreeAcceptsPredicateObject() throws {
        let data = Data(#"{"subtree":{"container":{"checks":[{"kind":"scrollable","value":true}]}}}"#.utf8)
        let decoded = try decoder.decode(InterfaceQuery.self, from: data)

        XCTAssertEqual(decoded.subtree, .container(.scrollable(true)))
    }

    func testInterfaceQueryElementSubtreeRejectsHeistIdField() {
        let json = #"{"subtree":{"heistId":"button_save","checks":["# +
            #"{"kind":"label","match":{"mode":"exact","value":"Save"}}]}}"#
        XCTAssertThrowsError(try decoder.decode(InterfaceQuery.self, from: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("heistId"), "\(error)")
        }
    }

    func testInterfaceQueryElementSubtreeRejectsHeistIdOnlyField() {
        let json = #"{"subtree":{"heistId":"button_save","ordinal":1}}"#
        XCTAssertThrowsError(try decoder.decode(InterfaceQuery.self, from: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("heistId"), "\(error)")
        }
    }

    func testInterfaceQueryElementSubtreeRejectsUnknownTargetField() {
        let json = #"{"subtree":{"checks":["# +
            #"{"kind":"label","match":{"mode":"exact","value":"Save"}}],"# +
            #""unexpectedTargetField":"button_save"}}"#
        XCTAssertThrowsError(try decoder.decode(InterfaceQuery.self, from: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("unexpectedTargetField"), "\(error)")
        }
    }

    func testInterfaceQuerySubtreeRejectsRemovedElementWrapperShape() {
        let json = #"{"subtree":{"element":{"checks":[{"kind":"label","match":{"mode":"exact","value":"Save"}}]}}}"#
        XCTAssertThrowsError(try decoder.decode(InterfaceQuery.self, from: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("element"), "\(error)")
        }
    }

    func testInterfaceQueryContainerSubtreeRejectsNegativeOrdinal() {
        let json = #"{"subtree":{"container":{"checks":[{"kind":"scrollable","value":true}]},"ordinal":-1}}"#
        XCTAssertThrowsError(try decoder.decode(InterfaceQuery.self, from: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("non-negative"), "\(error)")
        }
    }

    func testInterfaceQueryScopedSubtreeRejectsOuterOrdinal() {
        let json = #"{"subtree":{"container":{"checks":[{"kind":"scrollable","value":true}]},"# +
            #""target":{"checks":["# +
            #"{"kind":"label","match":{"mode":"exact","value":"Save"}}]},"ordinal":1}}"#
        XCTAssertThrowsError(try decoder.decode(InterfaceQuery.self, from: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("ordinal"), "\(error)")
        }
    }

    // MARK: - AccessibilityHierarchy

    func testAccessibilityHierarchyLeafRoundTrip() throws {
        let element = makeTestHeistElement(
            description: "Button", label: "OK", value: nil, identifier: nil,
            frameX: 0, frameY: 0, frameWidth: 100, frameHeight: 44, actions: [.activate]
        )
        let node = AccessibilityHierarchy.element(makeTestAccessibilityElement(element), traversalIndex: 0)
        let data = try encoder.encode(node)
        let decoded = try decoder.decode(AccessibilityHierarchy.self, from: data)
        XCTAssertEqual(decoded, node)
    }

    func testAccessibilityHierarchyContainerRoundTrip() throws {
        let elementA = makeTestHeistElement(
            description: "A", label: "A", value: nil, identifier: nil,
            frameX: 0, frameY: 0, frameWidth: 100, frameHeight: 44, actions: []
        )
        let elementB = makeTestHeistElement(
            description: "B", label: "B", value: nil, identifier: nil,
            frameX: 0, frameY: 50, frameWidth: 100, frameHeight: 44, actions: []
        )
        let outer = makeTestAccessibilityContainer(
            type: .list,
            frameWidth: 390,
            frameHeight: 600
        )
        let inner = makeTestAccessibilityContainer(
            type: .semanticGroup(label: nil, value: nil), identifier: nil,
            frameWidth: 390,
            frameHeight: 44
        )
        let node = AccessibilityHierarchy.container(outer, children: [
            .element(makeTestAccessibilityElement(elementA), traversalIndex: 0),
            .container(inner, children: [.element(makeTestAccessibilityElement(elementB), traversalIndex: 1)]),
        ])
        let data = try encoder.encode(node)
        let decoded = try decoder.decode(AccessibilityHierarchy.self, from: data)
        XCTAssertEqual(decoded, node)
    }

    // MARK: - HeistCustomContent

    func testHeistCustomContentRoundTrip() throws {
        let content = HeistCustomContent(label: "Price", value: "$9.99", isImportant: true)
        let data = try encoder.encode(content)
        let decoded = try decoder.decode(HeistCustomContent.self, from: data)
        XCTAssertEqual(decoded.label, "Price")
        XCTAssertEqual(decoded.value, "$9.99")
        XCTAssertTrue(decoded.isImportant)
    }

    // MARK: - PropertyChange / ElementUpdate

    func testPropertyChangeRoundTrip() throws {
        let change = try XCTUnwrap(PropertyChange.value(old: "OK", new: "Cancel"))
        let data = try encoder.encode(change)
        let decoded = try decoder.decode(PropertyChange.self, from: data)
        XCTAssertEqual(decoded, change)
    }

    func testPropertyChangeOmitsEqualValuesAndRejectsEqualWireValues() {
        XCTAssertNil(PropertyChange.value(old: "same", new: "same"))
        let json = #"{"property":"value","old":"same","new":"same"}"#

        XCTAssertThrowsError(try decoder.decode(PropertyChange.self, from: Data(json.utf8)))
    }

    func testTreeChangeTraitsUseCanonicalSetSemantics() throws {
        XCTAssertNil(PropertyChange.traits(
            old: [.selected, .button],
            new: [.button, .selected, .button]
        ))

        let value = ElementPropertyValue.traits([.selected, .button, .button])
        let data = try encoder.encode(value)
        let wire = try JSONProbe(data: data)

        XCTAssertEqual(try wire.strings("traits"), ["button", "selected"])
        XCTAssertEqual(try decoder.decode(ElementPropertyValue.self, from: data), value)
    }

    func testTraitPropertyChangesUseCanonicalSetValues() throws {
        let json = #"{"property":"traits","old":["selected","button","button"],"new":["header"]}"#
        let change = try decoder.decode(PropertyChange.self, from: Data(json.utf8))

        XCTAssertEqual(change.oldValue, .traits([.button, .selected]))
        XCTAssertEqual(change.newValue, .traits([.header]))
        let encoded = try JSONProbe(data: encoder.encode(change))
        XCTAssertEqual(try encoded.strings("old"), ["button", "selected"])
    }

    func testTreeChangePolymorphicPayloadsRejectExtraFields() {
        let incompatibleValue = #"{"kind":"text","value":"Ready","traits":["button"]}"#

        XCTAssertThrowsError(
            try decoder.decode(ElementPropertyValue.self, from: Data(incompatibleValue.utf8))
        ) { error in
            assertDecodingError(error, contains: ["text", "traits"])
        }

        let unknownChange = #"{"property":"value","old":"Ready","new":"Done","display":"Ready -> Done"}"#
        XCTAssertThrowsError(
            try decoder.decode(PropertyChange.self, from: Data(unknownChange.utf8))
        ) { error in
            assertDecodingError(error, contains: ["property change", "display"])
        }
    }

    func testElementPropertyIsGeometry() {
        XCTAssertTrue(ElementProperty.frame.isGeometry)
        XCTAssertTrue(ElementProperty.activationPoint.isGeometry)
        XCTAssertFalse(ElementProperty.value.isGeometry)
        XCTAssertFalse(ElementProperty.traits.isGeometry)
        XCTAssertFalse(ElementProperty.hint.isGeometry)
        XCTAssertFalse(ElementProperty.actions.isGeometry)
        XCTAssertFalse(ElementProperty.rotors.isGeometry)
    }

    func testElementPropertyAllCasesRoundTrip() throws {
        for property in ElementProperty.allCases {
            let data = try encoder.encode(property)
            let decoded = try decoder.decode(ElementProperty.self, from: data)
            XCTAssertEqual(decoded, property)
        }
    }

    func testElementUpdateRoundTrip() throws {
        let before = makeTestHeistElement(
            description: "Button",
            label: "Button",
            value: "A",
            identifier: nil,
            frameX: 0, frameY: 0, frameWidth: 100, frameHeight: 44,
            actions: []
        )
        let after = makeTestHeistElement(
            description: "Button",
            label: "Button",
            value: "B",
            identifier: nil,
            frameX: 0, frameY: 0, frameWidth: 100, frameHeight: 44,
            actions: []
        )
        let update = ElementUpdate(
            before: before,
            after: after,
            changes: [
                try XCTUnwrap(PropertyChange.value(old: "A", new: "B")),
                try XCTUnwrap(PropertyChange.value(old: nil, new: "active")),
            ]
        )
        let data = try encoder.encode(update)
        let decoded = try decoder.decode(ElementUpdate.self, from: data)
        XCTAssertEqual(decoded, update)
    }

}
