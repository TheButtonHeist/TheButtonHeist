#if canImport(UIKit)
import ButtonHeistTestSupport
import XCTest
import ThePlans
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@testable import TheScore

extension ElementEdits {
    var addedOptional: [HeistElement]? { added.isEmpty ? nil : added }
    /// Removed elements are wire `HeistElement`s (no heistId). Project their
    /// labels for assertion convenience.
    var removedOptional: [String]? {
        removed.isEmpty ? nil : removed.map { $0.semantics.assertable.label ?? "" }
    }
    var updatedOptional: [ElementUpdate]? { updated.isEmpty ? nil : updated }
}

extension Array {
    var single: Element? {
        count == 1 ? self[0] : nil
    }
}

extension AccessibilityHierarchy {
    var testLabel: String? {
        guard case .element(let element, _) = self else { return nil }
        return element.label
    }
}

private final class WireActivationOverrideView: UIView {
    override func accessibilityActivate() -> Bool {
        true
    }
}

@MainActor
final class WireConverterTests: XCTestCase {

    typealias WireConversion = TheVault.WireConversion

    struct InterfaceComparison {
        let before: Interface
        let after: Interface
        let edits: ElementEdits
    }

    // MARK: - Helpers

    func makeElement(
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        hint: String? = nil,
        traits: [HeistTrait] = [],
        frameX: Double = 0,
        frameY: Double = 0,
        frameWidth: Double = 0,
        frameHeight: Double = 0,
        activationPoint: CGPoint? = nil,
        customContent: [AccessibilityElement.CustomContent] = [],
        customRotors: [AccessibilityElement.CustomRotor] = [],
        respondsToUserInteraction: Bool = true
    ) -> AccessibilityElement {
        let frame = CGRect(x: frameX, y: frameY, width: frameWidth, height: frameHeight)
        let hasExplicitActivationPoint = activationPoint != nil
        let resolvedActivationPoint = activationPoint ?? CGPoint(x: frame.midX, y: frame.midY)
        return .make(
            label: label,
            value: value,
            identifier: identifier,
            hint: hint,
            traits: UIAccessibilityTraits.fromNames(traits.map(\.rawValue)),
            shape: .frame(AccessibilityRect(frame)),
            activationPoint: resolvedActivationPoint,
            usesDefaultActivationPoint: !hasExplicitActivationPoint,
            customContent: customContent,
            customRotors: customRotors,
            respondsToUserInteraction: respondsToUserInteraction
        )
    }

    func makeScreenElement(
        heistId: HeistId,
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        hint: String? = nil,
        traits: [HeistTrait] = [],
        frameX: Double = 0,
        frameY: Double = 0,
        frameWidth: Double = 0,
        frameHeight: Double = 0,
        activationPoint: CGPoint? = nil,
        customContent: [AccessibilityElement.CustomContent] = [],
        customRotors: [AccessibilityElement.CustomRotor] = [],
        respondsToUserInteraction: Bool = true
    ) -> InterfaceTree.Element {
        let element = makeElement(
            label: label, value: value, identifier: identifier, hint: hint,
            traits: traits, frameX: frameX, frameY: frameY,
            frameWidth: frameWidth, frameHeight: frameHeight,
            activationPoint: activationPoint,
            customContent: customContent,
            customRotors: customRotors,
            respondsToUserInteraction: respondsToUserInteraction
        )
        return InterfaceTree.Element(
            heistId: heistId,
            scrollMembership: nil,
            geometry: testGeometry(
                for: element,
                ownerPath: .root,
                screen: TheVault.onscreenSpace(for: element)
            ),
            element: element
        )
    }

    /// Build a test tree node from a InterfaceTree.Element leaf.
    func wireLeaf(_ element: InterfaceTree.Element) -> TestInterfaceNode {
        .element(
            TheVault.WireConversion.convert(
                element.element,
                geometry: element.geometry
            )
        )
    }

    func makeInterface(
        nodes: [TestInterfaceNode],
        timestamp: Date
    ) -> Interface {
        makeTestInterface(nodes: nodes, timestamp: timestamp)
    }

    func compareInterfaces(
        before: [InterfaceTree.Element],
        after: [InterfaceTree.Element],
        beforeTree: [TestInterfaceNode]? = nil,
        afterTree: [TestInterfaceNode]? = nil
    ) -> InterfaceComparison {
        let resolvedAfterTree: [TestInterfaceNode]
        if let afterTree, !afterTree.isEmpty {
            resolvedAfterTree = afterTree
        } else {
            resolvedAfterTree = after.map(wireLeaf)
        }
        let beforeInterface = makeInterface(nodes: beforeTree ?? before.map(wireLeaf), timestamp: Date(timeIntervalSince1970: 0))
        let afterInterface = makeInterface(nodes: resolvedAfterTree, timestamp: Date(timeIntervalSince1970: 1))
        return InterfaceComparison(
            before: beforeInterface,
            after: afterInterface,
            edits: ElementEdits.between(beforeInterface, afterInterface)
        )
    }

    // MARK: - Trait Mapping

    func testSingleTraitMapped() throws {
        let traits = AccessibilityTraits.button.heistTraits
        XCTAssertEqual(traits, [.button])
    }

    func testMultipleTraitsMapped() throws {
        let traits: AccessibilityTraits = [.button, .selected]
        let heistTraits = traits.heistTraits
        XCTAssertTrue(heistTraits.contains(.button))
        XCTAssertTrue(heistTraits.contains(.selected))
        XCTAssertEqual(heistTraits.count, 2)
    }

    func testBackButtonPrivateTraitMapped() throws {
        let traits = AccessibilityTraits(rawValue: 1 << 27).heistTraits
        XCTAssertEqual(traits, [.backButton])
    }

    func testNoTraitsReturnsEmpty() throws {
        let traits = AccessibilityTraits().heistTraits
        XCTAssertTrue(traits.isEmpty)
    }

    func testTraitMappingDeclarationOrder() throws {
        let traits: AccessibilityTraits = [.button, .selected]
        let heistTraits = traits.heistTraits
        XCTAssertEqual(heistTraits[0], .button)
        XCTAssertEqual(heistTraits[1], .selected)
    }

    // MARK: - Trait Name Sync

    func testHeistTraitAllCasesMatchParser() throws {
        let parserNames = AccessibilityTraits.knownTraitNames
        let wireNames = Set(HeistTrait.allCases.map(\.rawValue))
        XCTAssertEqual(wireNames, parserNames,
                       "HeistTrait.allCases must match parser's UIKit knownTraitNames")
    }

    // MARK: - Unknown Trait Bits

    /// Trait bits outside the current contract do not become public trait
    /// values. The parser may observe them, but the wire model exposes only
    /// named `HeistTrait` cases.
    func testUnknownTraitBitDoesNotBecomeWireTrait() throws {
        let unknownBit: UInt64 = 1 << 42
        let traits = UIAccessibilityTraits(rawValue: unknownBit)
        let wire = AccessibilityTraits(traits).heistTraits
        XCTAssertTrue(wire.isEmpty, "Unknown trait bits must stay out of the wire contract, got: \(wire)")
    }

    /// Mixing a known trait with an unknown bit emits only the known name from
    /// the current contract.
    func testKnownPlusUnknownTraitMixEmitsKnownTraitOnly() throws {
        let mixed = UIAccessibilityTraits(rawValue: UIAccessibilityTraits.button.rawValue | (1 << 42))
        let wire = AccessibilityTraits(mixed).heistTraits
        XCTAssertEqual(wire, [.button], "Only named contract traits should appear, got: \(wire)")
    }

    /// All known bits stay in the named contract.
    func testAllKnownTraitsRoundTripThroughCurrentContract() throws {
        for trait in HeistTrait.allCases {
            let bitmask = UIAccessibilityTraits.fromNames([trait.rawValue])
            let wire = AccessibilityTraits(bitmask).heistTraits
            XCTAssertEqual(wire, [trait], "Known trait \(trait.rawValue) must round-trip, got: \(wire)")
        }
    }

    // MARK: - Action Conversion

    func testSemanticInterfaceDoesNotInferElementActionsFromLiveObject() throws {
        let element = makeElement(
            label: "Plain action",
            respondsToUserInteraction: false
        )
        let liveObject = WireActivationOverrideView()
        let parse = TheVault.CaptureTree(
            hierarchy: [.element(element, traversalIndex: 0)],
            objectsByPath: [TreePath([0]): liveObject],
        )
        let screen = TheVault.buildObservation(from: parse)

        let elements = screen.tree.semanticInterface(timestamp: Date()).projectedElements

        XCTAssertEqual(elements.first?.semantics.assertable.actions, [])
    }

    func testToWireIncludesActivateFromParsedInteractivity() throws {
        let element = makeScreenElement(
            heistId: "button",
            label: "Button",
            respondsToUserInteraction: true
        )

        let wire = WireConversion.convert(
            element.element,
            geometry: element.geometry
        )

        XCTAssertEqual(wire.semantics.assertable.actions, [.activate])
    }

    func testToWireIncludesTypeTextForEveryTextInputTrait() throws {
        for trait in [.textEntry, .searchField, .secureTextField, .textArea] as [HeistTrait] {
            let element = makeScreenElement(
                heistId: HeistId(rawValue: trait.rawValue),
                label: trait.rawValue,
                traits: [trait],
                respondsToUserInteraction: false
            )

            let wire = WireConversion.convert(
                element.element,
                geometry: element.geometry
            )

            XCTAssertTrue(
                wire.semantics.assertable.actions.contains(.typeText),
                "Expected typeText for \(trait.rawValue)"
            )
        }
    }

    func testToWireDoesNotInferTypeTextFromUnrelatedTraits() throws {
        let element = makeScreenElement(
            heistId: "button",
            label: "Button",
            traits: [.button],
            respondsToUserInteraction: false
        )

        let wire = WireConversion.convert(
            element.element,
            geometry: element.geometry
        )

        XCTAssertFalse(wire.semantics.assertable.actions.contains(.typeText))
    }

}

#endif
