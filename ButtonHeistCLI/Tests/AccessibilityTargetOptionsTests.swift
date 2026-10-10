import XCTest
import ThePlans
@testable import ButtonHeistCLIExe

final class AccessibilityTargetOptionsTests: XCTestCase {

    func testGetInterfaceDoesNotExposeHeistIDTargeting() {
        XCTAssertThrowsError(try GetInterfaceCommand.parse(["--heist-id", "button_save"]))
    }

    func testGetInterfaceRejectsPositionalTargets() {
        XCTAssertThrowsError(try GetInterfaceCommand.parse(["button_save"]))
    }

    func testMatcherOptionsParseToTypedSubtreeTarget() throws {
        let command = try GetInterfaceCommand.parse([
            "--identifier", "saveButton",
            "--label", "Save",
            "--traits", "button", "selected",
            "--exclude-traits", "notEnabled", "header",
            "--ordinal", "1",
        ])

        XCTAssertEqual(
            try command.subtree.parsedTarget(),
            .predicate(
                ElementPredicate([
                    .label("Save"),
                    .identifier("saveButton"),
                    .traits([.button, .selected]),
                    .exclude(.traits([.header, .notEnabled])),
                ]),
                ordinal: 1
            )
        )
    }

    func testOrdinalOnlyIsRejectedAtTypedTargetBoundary() throws {
        let command = try GetInterfaceCommand.parse(["--ordinal", "0"])

        XCTAssertThrowsError(try command.subtree.parsedTarget()) { error in
            XCTAssertTrue(String(describing: error).contains("requires a predicate"))
        }
    }
}
