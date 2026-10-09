import XCTest

@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

final class CommandArgumentEnvelopeLimitsTests: XCTestCase {

    func testValidateReportsDepthLimitAsSchemaValidationError() {
        let arguments = TheFence.CommandArgumentEnvelope(values: [
            "argument": .object(["child": .string("leaf")]),
        ])

        XCTAssertThrowsError(try CommandArgumentEnvelopeLimits.validate(
            arguments,
            field: "run_heist",
            maxBytes: PublicJSONInputLimits.maxRequestBytes,
            maxDepth: 2,
            maxObjectKeys: PublicJSONInputLimits.maxTotalObjectKeys
        )) { error in
            assertSchemaError(
                error,
                message: "schema validation failed for run_heist: observed nesting depth 3; expected nesting depth <= 2"
            )
        }
    }

    func testValidateReportsByteLimitAsSchemaValidationError() {
        let arguments = TheFence.CommandArgumentEnvelope(values: [
            "text": .string("xxxx"),
        ])

        XCTAssertThrowsError(try CommandArgumentEnvelopeLimits.validate(
            arguments,
            field: "run_heist",
            maxBytes: 5,
            maxDepth: PublicJSONInputLimits.maxNestingDepth,
            maxObjectKeys: PublicJSONInputLimits.maxTotalObjectKeys
        )) { error in
            assertSchemaError(
                error,
                message: "schema validation failed for run_heist: observed 15 bytes; expected JSON request <= 5 bytes"
            )
        }
    }

    func testValidateReportsObjectKeyLimitAsSchemaValidationError() {
        let arguments = TheFence.CommandArgumentEnvelope(values: [
            "argument": .object([
                "one": .int(1),
                "two": .int(2),
            ]),
        ])

        XCTAssertThrowsError(try CommandArgumentEnvelopeLimits.validate(
            arguments,
            field: "run_heist",
            maxBytes: PublicJSONInputLimits.maxRequestBytes,
            maxDepth: PublicJSONInputLimits.maxNestingDepth,
            maxObjectKeys: 2
        )) { error in
            let expected = "schema validation failed for run_heist: observed object key count 3; " +
                "expected object key count <= 2"
            assertSchemaError(
                error,
                message: expected
            )
        }
    }

    func testValidateReportsNonFiniteNumberAsSchemaValidationError() {
        let arguments = TheFence.CommandArgumentEnvelope(values: [
            "number": .double(.nan),
        ])

        XCTAssertThrowsError(try CommandArgumentEnvelopeLimits.validate(
            arguments,
            field: "run_heist",
            maxBytes: PublicJSONInputLimits.maxRequestBytes,
            maxDepth: PublicJSONInputLimits.maxNestingDepth,
            maxObjectKeys: PublicJSONInputLimits.maxTotalObjectKeys
        )) { error in
            assertSchemaError(
                error,
                message: "schema validation failed for run_heist: observed number nan; expected finite JSON number"
            )
        }
    }

    private func assertSchemaError(
        _ error: Error,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let schemaError = error as? SchemaValidationError else {
            XCTFail("Expected SchemaValidationError, got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(schemaError.message, message, file: file, line: line)
    }

}
