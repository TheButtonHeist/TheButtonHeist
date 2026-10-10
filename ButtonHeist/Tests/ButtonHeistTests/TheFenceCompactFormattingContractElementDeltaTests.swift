import ButtonHeistTestSupport
import XCTest
import ThePlans
import AccessibilitySnapshotModel
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

extension TheFenceCompactFormattingContractTests {

    func testElementsChangedActionOutputIncludesConcreteElementDelta() throws {
        let added = makeTestHeistElement(
            label: "Barbaresco",
            value: "$55.00",
            identifier: "wine_barbaresco",
            traits: [.staticText]
        )
        let unchanged = (0..<11).map { index in
            makeTestHeistElement(label: "Row \(index)", identifier: "row_\(index)")
        }
        let evidence = makeObservationEvidence(
            before: makeTestInterface(elements: unchanged),
            after: makeTestInterface(elements: unchanged + [added])
        )
        let response = FenceResponse.action(
            result: ActionResult.success(
                payload: .activate,
                observation: .observed(evidence)
            )
        )

        let delta = try publicJSONProbe(response).object("delta")
        let addedJSON = try delta.object("edits").array("added")
        let compact = response.compactFormatted()
        let human = response.humanFormatted()

        XCTAssertEqual(try delta.string("kind"), "elementsChanged")
        XCTAssertEqual(try addedJSON.first?.string("label"), "Barbaresco")
        XCTAssertEqual(try addedJSON.first?.string("identifier"), "wine_barbaresco")
        XCTAssertTrue(compact.contains(#"+ "Barbaresco":"$55.00" staticText id="wine_barbaresco""#), compact)
        XCTAssertTrue(human.contains(#"+ "Barbaresco":"$55.00" staticText id="wine_barbaresco""#), human)
    }

}
