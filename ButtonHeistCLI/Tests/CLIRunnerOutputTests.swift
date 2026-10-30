import Foundation
import XCTest

@_spi(ButtonHeistInternals) @_spi(ButtonHeistTooling) import ButtonHeist

@testable import ButtonHeistCLIExe

final class CLIRunnerOutputTests: XCTestCase {

    func testSemanticResponseRendersThroughEachFormat() {
        let semanticOutput = CLIRunner.CommandOutput.response(.targets([:], defaultTarget: nil))

        XCTAssertEqual(
            CLIRunner.renderedOutput(for: semanticOutput, format: .human),
            .text("No targets configured")
        )
        XCTAssertEqual(
            CLIRunner.renderedOutput(for: semanticOutput, format: .compact),
            .text("no targets configured")
        )
        XCTAssertEqual(
            CLIRunner.renderedOutput(
                for: semanticOutput,
                format: .json,
                jsonRenderer: { response in
                    XCTAssertEqual(response.isFailure, false)
                    return .rendered(Data(#"{"status":"ok","targets":{}}"#.utf8))
                }
            ),
            .text(#"{"status":"ok","targets":{}}"#)
        )
    }

    func testJUnitSemanticOutputUsesTheResponseRenderer() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-runner-output-test-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: path) }

        let rendered = CLIRunner.renderedOutput(
            for: .junit(response: .targets([:], defaultTarget: nil), xml: "<testsuites/>", path: path.path),
            format: .compact
        )

        XCTAssertEqual(rendered, .text("no targets configured"))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "<testsuites/>")
    }
}
