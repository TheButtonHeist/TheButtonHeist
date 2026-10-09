import Foundation
import XCTest

@_spi(ButtonHeistTooling) @testable import ButtonHeist

final class PublicJSONInputLimitsTests: XCTestCase {

    func testDecodeObjectRejectsArrayRoot() {
        XCTAssertThrowsError(try PublicJSONInputDecoder.decodeObject(
            from: #"["alpha","beta"]"#,
            rootMismatchMessage: "Expected JSON object input"
        )) { error in
            XCTAssertEqual((error as? PublicJSONInputError)?.message, "Expected JSON object input")
        }
    }

    func testValidateObjectAcceptsStringWithinRemainingLimits() {
        let json = #"{"text":"alpha beta"}"#

        XCTAssertNoThrow(try PublicJSONInputDecoder.decodeObject(
            from: Data(json.utf8),
            context: "Public JSON input",
            maxBytes: 32,
            maxNestingDepth: 2,
            maxTotalObjectKeys: 1
        ))
    }

}
