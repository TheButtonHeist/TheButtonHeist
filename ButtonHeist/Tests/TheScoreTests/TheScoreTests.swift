import XCTest
import TheScore

final class MessageAdmissionTests: XCTestCase {

    func testErrorMessageRejectsEmptySourceAndJSONValues() {
        XCTAssertThrowsError(try ServerErrorMessage(validating: "")) { error in
            XCTAssertEqual(String(describing: error), "server error message must not be empty")
        }
        let json = #"{"type":"error","payload":{"kind":"general","message":""}}"#

        XCTAssertThrowsError(try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("server error message must not be empty"), "\(error)")
        }
    }

    func testErrorRecoveryHintRejectsEmptySourceAndJSONValues() {
        XCTAssertThrowsError(try ServerErrorRecoveryHint(validating: "")) { error in
            XCTAssertEqual(
                String(describing: error),
                "server error recoveryHint must not be empty"
            )
        }
        let json = #"{"type":"error","payload":{"kind":"general","message":"oops","recoveryHint":""}}"#

        XCTAssertThrowsError(try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("server error recoveryHint must not be empty"), "\(error)")
        }
    }
}
