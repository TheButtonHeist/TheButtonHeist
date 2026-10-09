import Foundation
import XCTest

@_spi(ButtonHeistInternals) @_spi(ButtonHeistTooling) import ButtonHeist
import TheScore

@testable import ButtonHeistCLIExe

final class GetScreenCommandTests: XCTestCase {

    func testIncludeInterfaceFlagIsNotACommandSurface() {
        XCTAssertThrowsError(try GetScreenCommand.parse(["--include-interface"]))
    }

    func testInlineRejectsOutputPath() {
        XCTAssertThrowsError(try GetScreenCommand.parse(["--inline", "--output", "/tmp/screen.png"]))
    }

    func testAccessibilityFlagSetsScreenMode() throws {
        let command = try GetScreenCommand.parse(["--accessibility"])

        let arguments = try command.requestArguments()

        XCTAssertEqual(arguments.value(for: .mode), .string("accessibility"))
    }

    func testInlineCommandResultWritesScreenshotDataAsBinary() throws {
        let expectedData = Data([0x89, 0x50, 0x4E, 0x47])
        let response = FenceResponse.screenshotData(
            payload: try XCTUnwrap(ScreenPayload.admit(
                pngData: expectedData.base64EncodedString(),
                width: 2,
                height: 1
            ))
        )

        let result = try GetScreenCommand.inlineCommandOutput(for: response)

        guard case .binary(let data) = result else {
            return XCTFail("expected inline screenshot to produce binary output")
        }
        XCTAssertEqual(data, expectedData)
    }

    func testInlineCommandResultPreservesStructuredFailureResponse() throws {
        let failure = DiagnosticFailure(
            message: "screenshot failed",
            details: FailureDetails(code: .requestActionFailed)
        )
        let result = try GetScreenCommand.inlineCommandOutput(for: .error(failure))

        guard case .response(let failureResponse) = result else {
            return XCTFail("expected failure to stay on semantic response path")
        }
        guard case .error(let renderedFailure) = failureResponse else {
            return XCTFail("expected error response, got \(failureResponse)")
        }
        XCTAssertEqual(renderedFailure, failure)
        XCTAssertEqual(
            CLIRunner.renderedOutput(for: result, format: .human),
            .failedText("Error[request.action_failed request retryable=false]: screenshot failed")
        )
        XCTAssertTrue(failureResponse.isFailure)
    }

    func testJSONEncodingFallbackMarksSuccessfulCommandAsFailed() {
        let result = CLIRunner.CommandOutput.response(.ok(message: "done"))
        let fallbackText =
            #"{"code":"formatting.json_encoding_failed","message":"encoding failed","status":"error"}"#
        let fallbackJSON = Data(fallbackText.utf8)

        let rendered = CLIRunner.renderedOutput(
            for: result,
            format: .json,
            jsonRenderer: { _ in
                .fallback(
                    fallbackJSON,
                    DiagnosticFailure(
                        message: "encoding failed",
                        details: FailureDetails(code: .formattingJSONEncodingFailed)
                    )
                )
            }
        )

        XCTAssertEqual(rendered, .failedText(fallbackText))
        XCTAssertTrue(rendered.isFailure)
    }

    func testInlineCommandResultRejectsMalformedScreenshotData() throws {
        let response = FenceResponse.screenshotData(
            payload: try XCTUnwrap(ScreenPayload.admit(pngData: "not-base64", width: 1, height: 1))
        )

        XCTAssertThrowsError(try GetScreenCommand.inlineCommandOutput(for: response)) { error in
            XCTAssertTrue(String(describing: error).contains("Failed to decode screenshot data"))
        }
    }
}
