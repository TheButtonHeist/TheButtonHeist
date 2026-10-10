import ButtonHeistTestSupport
import XCTest
import ThePlans
import AccessibilitySnapshotModel
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

extension TheFenceCompactFormattingContractTests {

    func testScreenChangedActionOutputIncludesDestinationSummaryTree() throws {
        let destination = makeTestInterface(elements: [
            makeTestHeistElement(label: "Checkout", identifier: "checkout_title", traits: [.header]),
            makeTestHeistElement(label: "Pay", identifier: "pay_button", traits: [.button], actions: [.activate]),
        ])
        let evidence = makeObservationEvidence(
            before: makeTestInterface(elements: [makeTestHeistElement(label: "Cart", identifier: "cart_title")]),
            after: destination,
            beforeScreenId: "cart",
            afterScreenId: "checkout",
            screenChanged: true
        )
        let response = FenceResponse.action(
            result: ActionResult.success(
                payload: .activate,
                observation: .observed(evidence)
            )
        )

        let delta = try publicJSONProbe(response).object("delta")
        let newInterface = try delta.object("newInterface")
        let compact = response.compactFormatted()
        let human = response.humanFormatted()

        XCTAssertEqual(try delta.string("kind"), "screenChanged")
        XCTAssertEqual(try newInterface.array("tree").count, 2)
        XCTAssertTrue(compact.contains("activate: screen changed\nCheckout\n2 elements"), compact)
        XCTAssertTrue(compact.contains(#""Checkout" header id="checkout_title""#), compact)
        XCTAssertTrue(compact.contains(#""Pay" button id="pay_button""#), compact)
        XCTAssertTrue(human.contains("screen changed]\nCheckout\n2 elements"), human)
        XCTAssertTrue(human.contains(#""Checkout" header id="checkout_title""#), human)
    }

    func testLaterScreenChangeDominatesEarlierElementFacts() throws {
        let toast = makeTestHeistElement(label: "Saved", identifier: "saved_toast", traits: [.staticText])
        let cart = makeTestInterface(elements: [
            makeTestHeistElement(label: "Cart", identifier: "cart_title", traits: [.header]),
        ])
        let cartWithToast = makeTestInterface(elements: [toast] + cart.projectedElements)
        let checkout = makeTestInterface(elements: [
            makeTestHeistElement(label: "Checkout", identifier: "checkout_title", traits: [.header]),
        ])
        let before = observationSnapshot(
            interface: cart,
            screenId: "cart"
        )
        let elementChange = observationSnapshot(
            interface: cartWithToast,
            screenId: "cart"
        )
        let after = observationSnapshot(
            interface: checkout,
            screenId: "checkout"
        )
        let evidence = Observation.Evidence(
            baseline: before,
            events: [
                .elementsChanged(elementChange),
                .screenChanged(ScreenFacts(idAfter: "checkout")),
                .elementsChanged(after),
            ],
            current: after,
            coverage: .incomplete(.historyUnavailable)
        )
        let response = FenceResponse.action(
            result: ActionResult.success(
                payload: .activate,
                observation: .observed(evidence)
            )
        )

        let delta = try publicJSONProbe(response).object("delta")

        XCTAssertEqual(try delta.string("kind"), "screenChanged")
        try delta.assertMissing("edits")
    }
}
