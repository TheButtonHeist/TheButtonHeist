import Foundation
import XCTest

@_spi(ButtonHeistInternals) @_spi(ButtonHeistTooling) import ButtonHeist

@testable import ButtonHeistCLIExe

final class CLIRunnerOutputTests: XCTestCase {

    func testSemanticResponseRendersThroughEachFormat() {
        let semanticOutput = CLIRunner.CommandOutput.response(.ok(message: "done"))

        XCTAssertEqual(
            CLIRunner.renderedOutput(for: semanticOutput, format: .human),
            .text("done")
        )
        XCTAssertEqual(
            CLIRunner.renderedOutput(for: semanticOutput, format: .compact),
            .text("done")
        )
        XCTAssertEqual(
            CLIRunner.renderedOutput(
                for: semanticOutput,
                format: .json,
                jsonRenderer: { response, requestId in
                    XCTAssertEqual(response.isFailure, false)
                    XCTAssertNil(requestId)
                    return .rendered(Data(#"{"message":"done","status":"ok"}"#.utf8))
                }
            ),
            .text(#"{"message":"done","status":"ok"}"#)
        )
    }

    func testJSONRequestIdSurvivesSuccessAndFallbackErrorRendering() {
        let successRequestId = PublicRequestId.string("success-17")
        let fallbackRequestId = PublicRequestId.signedInteger(18)

        let success = CLIRunner.renderedOutput(
            for: .response(.ok(message: "done")),
            format: .json,
            requestId: successRequestId,
            jsonRenderer: { _, requestId in
                XCTAssertEqual(requestId, successRequestId)
                return .rendered(Data(#"{"request_id":"success-17","status":"ok"}"#.utf8))
            }
        )
        let fallback = CLIRunner.renderedOutput(
            for: .junit(
                response: .ok(message: "done"),
                xml: "<testsuites/>",
                path: "/dev/null/cli-runner-output-test.xml"
            ),
            format: .json,
            requestId: fallbackRequestId,
            jsonRenderer: { response, requestId in
                XCTAssertTrue(response.isFailure)
                XCTAssertEqual(requestId, fallbackRequestId)
                return .rendered(Data(#"{"request_id":18,"status":"error"}"#.utf8))
            }
        )

        XCTAssertEqual(success, .text(#"{"request_id":"success-17","status":"ok"}"#))
        XCTAssertEqual(fallback, .failedText(#"{"request_id":18,"status":"error"}"#))
    }

    func testJUnitSemanticOutputUsesTheResponseRenderer() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-runner-output-test-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: path) }

        let rendered = CLIRunner.renderedOutput(
            for: .junit(response: .ok(message: "done"), xml: "<testsuites/>", path: path.path),
            format: .compact
        )

        XCTAssertEqual(rendered, .text("done"))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "<testsuites/>")
    }
}
