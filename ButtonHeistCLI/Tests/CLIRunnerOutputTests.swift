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
                jsonRenderer: { response in
                    XCTAssertEqual(response.isFailure, false)
                    return .rendered(Data(#"{"message":"done","status":"ok"}"#.utf8))
                }
            ),
            .text(#"{"message":"done","status":"ok"}"#)
        )
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
