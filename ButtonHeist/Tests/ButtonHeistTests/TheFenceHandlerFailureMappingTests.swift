import ButtonHeistTestSupport
import XCTest
import Network
import ButtonHeistSupport
@_spi(ButtonHeistInternals) @_spi(ButtonHeistTooling) @testable import ButtonHeist
@_spi(ButtonHeistInternals) import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension TheFenceHandlerTests {
    // MARK: - Public Failure Mapping

    func testDiagnosticFailureIsDiagnosticFailureBoundaryValue() {
        let details = FailureDetails(
            code: .requestValidationError,
            hint: "Fix the request."
        )

        let diagnostic = DiagnosticFailure(message: "Invalid request", details: details)
        let diagnosticFailure: DiagnosticFailure = diagnostic

        XCTAssertEqual(diagnosticFailure.message, "Invalid request")
        XCTAssertEqual(diagnosticFailure.details, details)
        XCTAssertEqual(diagnosticFailure.details.code, .requestValidationError)
        XCTAssertEqual(diagnosticFailure.details.errorCode, "request.validation_error")
        XCTAssertEqual(diagnosticFailure.details.code.kind, .request)
        XCTAssertEqual(diagnosticFailure.details.phase, .request)
        XCTAssertFalse(diagnosticFailure.details.retryable)
        XCTAssertEqual(diagnosticFailure.details.hint, "Fix the request.")
    }

    func testJSONEncodingFallbackReturnsItsTypedFailure() throws {
        let failure = DiagnosticFailure(
            message: "encoding failed",
            details: FailureDetails(code: .formattingJSONEncodingFailed)
        )

        let rendering = try PublicJSONSerializer.render(
            encoding: ThrowingEncodable(),
            outputFormatting: [.sortedKeys],
            encodingFailure: failure
        )
        let json = try JSONProbe(data: rendering.data)

        XCTAssertEqual(rendering.failure, failure)
        XCTAssertEqual(try json.string("status"), "error")
        XCTAssertEqual(try json.string("code"), "formatting.json_encoding_failed")
    }

    func testHandoffConnectionFailureProjectsOnceToDiagnosticFailure() {
        let connectionError = HandoffConnectionError.ambiguousDeviceTarget(
            filter: "Demo",
            matches: ["Demo#one", "Demo#two"]
        )

        let diagnostic = DiagnosticFailure(connectionError: connectionError)

        XCTAssertEqual(diagnostic.message, "Ambiguous device target 'Demo' (matches: Demo#one, Demo#two)")
        XCTAssertEqual(diagnostic.details.code, .discoveryAmbiguousDeviceTarget)
        XCTAssertEqual(diagnostic.details.phase, .discovery)
        XCTAssertFalse(diagnostic.details.retryable)
        XCTAssertEqual(diagnostic.details.hint, KnownFailureCode.discoveryAmbiguousDeviceTarget.defaultHint)
    }

    func testFenceErrorRendersTypedHintAtDisplayBoundary() throws {
        let error = FenceError(HandoffConnectionError.timeout)
        let diagnostic = error.diagnosticFailure
        let hint = try XCTUnwrap(diagnostic.details.hint)

        XCTAssertEqual(diagnostic.message, "Connection timed out")
        XCTAssertEqual(error.errorDescription, "Connection timed out\n  Hint: \(hint)")
    }

    func testErrorResponseCarriesTypedDiagnosticFailure() throws {
        let details = FailureDetails(
            code: .requestInvalid
        )
        let failure = DiagnosticFailure(message: "schema validation failed", details: details)

        let response = FenceResponse.error(failure)

        guard case .error(let encodedFailure) = response else {
            return XCTFail("Expected typed error response")
        }
        XCTAssertEqual(encodedFailure, failure)

        let data = try response.jsonData()
        let encoded = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let responseObject) = encoded,
              let detailsValue = responseObject["details"],
              case .object(let detailsObject) = detailsValue else {
            return XCTFail("Expected canonical public failure object")
        }
        XCTAssertEqual(Set(responseObject.keys), ["status", "message", "code", "details"])
        XCTAssertEqual(Set(detailsObject.keys), ["kind", "phase", "retryable", "hint"])

        let json = try JSONProbe(data: data).object()
        XCTAssertEqual(failure.details.code, .requestInvalid)
        XCTAssertEqual(try json.string("status"), "error")
        XCTAssertEqual(try json.string("message"), failure.message)
        XCTAssertEqual(try json.string("code"), failure.details.errorCode)
        try json.assertMissing("errorCode")
        try json.assertMissing("kind")
        try json.assertMissing("phase")
        try json.assertMissing("retryable")
        try json.assertMissing("hint")

        let detailsJSON = try json.object("details")
        try detailsJSON.assertMissing("code")
        try detailsJSON.assertMissing("errorCode")
        XCTAssertEqual(try detailsJSON.string("kind"), failure.details.code.kind.rawValue)
        XCTAssertEqual(try detailsJSON.string("phase"), failure.details.phase.rawValue)
        XCTAssertEqual(try detailsJSON.bool("retryable"), failure.details.retryable)
        XCTAssertEqual(try detailsJSON.string("hint"), failure.details.hint)
        try detailsJSON.assertMissing("buildDiagnostics")
    }

    func testHeistBuildDiagnosticsPreservedThroughFailurePipeline() throws {
        let diagnostics = [
            HeistBuildDiagnostic(
                code: .sourceInvalidSyntax,
                phase: .sourceCompilation,
                sourceSpan: HeistBuildSourceSpan(
                    sourceName: "inline.heist",
                    offset: 12,
                    line: 2,
                    column: 5,
                    length: 3
                ),
                message: "expected an identifier",
                hint: "Use valid ButtonHeist DSL."
            ),
            HeistBuildDiagnostic(
                code: .planRuntimeSafety,
                kind: .warning,
                phase: .planValidation,
                path: "flow.heist",
                message: "runtime safety warning"
            ),
        ]
        let response = FenceResponse.failure(FenceError.heistBuildDiagnostics(diagnostics))
        guard case .error(let failure) = response else {
            return XCTFail("Expected typed error response")
        }
        let expectedFailureCode = KnownFailureCode.requestInvalid.rawValue

        XCTAssertEqual(failure.details.code, .requestInvalid)
        XCTAssertEqual(failure.details.errorCode, expectedFailureCode)
        XCTAssertEqual(failure.details.code.kind, .request)
        XCTAssertEqual(failure.details.phase, .request)
        XCTAssertFalse(failure.details.retryable)
        XCTAssertEqual(failure.details.hint, diagnostics[0].hint)
        XCTAssertEqual(failure.buildDiagnostics, diagnostics)
        XCTAssertTrue(failure.message.contains("expected an identifier"), failure.message)

        let json = try publicJSONProbe(response).object()
        XCTAssertEqual(try json.string("code"), expectedFailureCode)
        try json.assertMissing("errorCode")
        try json.assertMissing("kind")
        try json.assertMissing("phase")
        try json.assertMissing("retryable")
        try json.assertMissing("hint")

        let detailsJSON = try json.object("details")
        try detailsJSON.assertMissing("code")
        try detailsJSON.assertMissing("errorCode")
        XCTAssertEqual(try detailsJSON.string("kind"), DiagnosticFailureKind.request.rawValue)
        XCTAssertEqual(try detailsJSON.string("phase"), FailurePhase.request.rawValue)
        XCTAssertFalse(try detailsJSON.bool("retryable"))
        XCTAssertEqual(try detailsJSON.string("hint"), diagnostics[0].hint)

        let buildDiagnostics = try detailsJSON.array("buildDiagnostics")
        XCTAssertEqual(buildDiagnostics.count, 2)

        let first = try buildDiagnostics[0].object()
        XCTAssertEqual(try first.string("code"), diagnostics[0].code.rawValue)
        XCTAssertEqual(try first.string("kind"), HeistBuildDiagnosticKind.error.rawValue)
        XCTAssertEqual(try first.string("phase"), HeistBuildPhase.sourceCompilation.rawValue)
        XCTAssertEqual(try first.string("message"), diagnostics[0].message)
        XCTAssertEqual(try first.string("hint"), diagnostics[0].hint)
        try first.assertMissing("path")
        let sourceSpan = try first.object("sourceSpan")
        XCTAssertEqual(try sourceSpan.string("sourceName"), "inline.heist")
        XCTAssertEqual(try sourceSpan.int("offset"), 12)
        XCTAssertEqual(try sourceSpan.int("line"), 2)
        XCTAssertEqual(try sourceSpan.int("column"), 5)
        XCTAssertEqual(try sourceSpan.int("length"), 3)

        let second = try buildDiagnostics[1].object()
        XCTAssertEqual(try second.string("code"), diagnostics[1].code.rawValue)
        XCTAssertEqual(try second.string("kind"), HeistBuildDiagnosticKind.warning.rawValue)
        XCTAssertEqual(try second.string("phase"), HeistBuildPhase.planValidation.rawValue)
        XCTAssertEqual(try second.string("message"), diagnostics[1].message)
        XCTAssertEqual(try second.string("path"), "flow.heist")
        try second.assertMissing("hint")
        try second.assertMissing("sourceSpan")
    }

    func testKnownFailureCodesExposeTypedClassification() throws {
        let expected = Self.knownFailureCodeClassificationExpectations

        XCTAssertEqual(Set(expected.keys), Set(KnownFailureCode.allCases))

        for knownCode in KnownFailureCode.allCases {
            let expectation = try XCTUnwrap(expected[knownCode])
            let code = knownCode
            let details = FailureDetails(code: knownCode)

            XCTAssertEqual(code.rawValue, knownCode.rawValue)
            XCTAssertEqual(code, knownCode)
            XCTAssertEqual(code.kind, expectation.kind)
            XCTAssertEqual(code.phase, expectation.phase)
            XCTAssertEqual(code.retryable, expectation.retryable)
            XCTAssertEqual(code.defaultHint, expectation.hint)
            XCTAssertEqual(details.code, code)
            XCTAssertEqual(details.code.rawValue, knownCode.rawValue)
            XCTAssertEqual(details.phase, expectation.phase)
            XCTAssertEqual(details.retryable, expectation.retryable)
            XCTAssertEqual(details.hint, expectation.hint)
        }
    }

    func testUnknownFailureCodeDecodeFailsAtBoundary() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(
            KnownFailureCode.self,
            from: Data(#""plugin.custom_failure""#.utf8)
        )) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("plugin.custom_failure"))
        }
    }

    func testKnownFailuresExposeCompleteDiagnosticFields() throws {
        for expected in Self.expectedDiagnosticFailures {
            guard case .error(let failure) = expected.response else {
                return XCTFail("Expected typed error response: \(expected.name)")
            }
            let json = try publicJSONProbe(expected.response).object()
            let detailsJSON = try json.object("details")

            XCTAssertEqual(failure.message, expected.message, expected.name)
            XCTAssertEqual(failure.details.code, expected.code, expected.name)
            XCTAssertEqual(failure.details.code.rawValue, expected.code.rawValue, expected.name)
            XCTAssertEqual(failure.details.errorCode, expected.code.rawValue, expected.name)
            XCTAssertEqual(failure.details.code.kind, expected.kind, expected.name)
            XCTAssertEqual(failure.details.phase, expected.phase, expected.name)
            XCTAssertEqual(failure.details.retryable, expected.retryable, expected.name)
            XCTAssertFalse(failure.details.errorCode.isEmpty, expected.name)
            XCTAssertFalse(failure.details.code.kind.rawValue.isEmpty, expected.name)
            XCTAssertFalse(failure.message.isEmpty, expected.name)
            XCTAssertEqual(try json.string("status"), "error", expected.name)
            XCTAssertEqual(try json.string("message"), expected.message, expected.name)
            XCTAssertEqual(try json.string("code"), expected.code.rawValue, expected.name)
            XCTAssertNoThrow(try json.assertMissing("errorCode"), expected.name)
            XCTAssertNoThrow(try json.assertMissing("kind"), expected.name)
            XCTAssertNoThrow(try json.assertMissing("phase"), expected.name)
            XCTAssertNoThrow(try json.assertMissing("retryable"), expected.name)
            XCTAssertNoThrow(try json.assertMissing("hint"), expected.name)
            XCTAssertNoThrow(try detailsJSON.assertMissing("code"), expected.name)
            XCTAssertNoThrow(try detailsJSON.assertMissing("errorCode"), expected.name)
            XCTAssertEqual(try detailsJSON.string("kind"), expected.kind.rawValue, expected.name)
            XCTAssertEqual(try detailsJSON.string("phase"), expected.phase.rawValue, expected.name)
            XCTAssertEqual(try detailsJSON.bool("retryable"), expected.retryable, expected.name)
        }
    }

    func testAmbiguousDeviceTargetKeepsDistinctFailureProjection() throws {
        let response = FenceResponse.failure(HandoffConnectionError.ambiguousDeviceTarget(
            filter: "Demo",
            matches: ["Demo#one", "Demo#two"]
        ))
        guard case .error(let failure) = response else {
            return XCTFail("Expected typed error response")
        }

        XCTAssertEqual(failure.details.code, .discoveryAmbiguousDeviceTarget)
        XCTAssertNotEqual(failure.details.code, .discoveryNoMatchingDevice)
        XCTAssertEqual(failure.details.errorCode, KnownFailureCode.discoveryAmbiguousDeviceTarget.rawValue)
        XCTAssertEqual(failure.details.code.kind, .discovery)
        XCTAssertEqual(failure.details.phase, .discovery)
        XCTAssertFalse(failure.details.retryable)
        XCTAssertEqual(failure.details.hint, KnownFailureCode.discoveryAmbiguousDeviceTarget.defaultHint)
        XCTAssertEqual(failure.message, "Ambiguous device target 'Demo' (matches: Demo#one, Demo#two)")

        let json = try publicJSONProbe(response).object()
        XCTAssertEqual(try json.string("status"), "error")
        XCTAssertEqual(try json.string("code"), KnownFailureCode.discoveryAmbiguousDeviceTarget.rawValue)
        let detailsJSON = try json.object("details")
        XCTAssertEqual(try detailsJSON.string("kind"), DiagnosticFailureKind.discovery.rawValue)
        XCTAssertEqual(try detailsJSON.string("phase"), FailurePhase.discovery.rawValue)
    }

    func testTransportDisconnectFailureUsesNetworkDiagnosticShape() throws {
        let transportFailure = NetworkTransportFailure(.posix(.ECONNRESET))
        let response = FenceResponse.failure(HandoffConnectionError.disconnected(.networkError(transportFailure)))
        guard case .error(let failure) = response else {
            return XCTFail("Expected typed error response")
        }

        XCTAssertEqual(failure.details.code, .transportNetworkError)
        XCTAssertEqual(failure.details.errorCode, KnownFailureCode.transportNetworkError.rawValue)
        XCTAssertEqual(failure.details.code.kind, .connection)
        XCTAssertEqual(failure.details.phase, .transport)
        XCTAssertTrue(failure.details.retryable)
        XCTAssertEqual(failure.details.hint, KnownFailureCode.transportNetworkError.defaultHint)
        XCTAssertTrue(failure.message.contains("posix"), failure.message)
        XCTAssertTrue(failure.message.contains("connection failed in transport"), failure.message)
    }
    func testAuthFailureMappingPreservesSourceHint() throws {
        let hint = "Retry with the configured token."
        let response = FenceResponse.failure(HandoffConnectionError.disconnected(
            .authFailed("Invalid token", hint: hint)
        ))
        guard case .error(let failure) = response else {
            return XCTFail("Expected typed error response")
        }

        XCTAssertEqual(failure.details.code, .authFailed)
        XCTAssertEqual(failure.details.errorCode, KnownFailureCode.authFailed.rawValue)
        XCTAssertEqual(failure.details.code.kind, .authentication)
        XCTAssertEqual(failure.details.phase, .authentication)
        XCTAssertFalse(failure.details.retryable)
        XCTAssertEqual(failure.details.hint, hint)

        let json = try publicJSONProbe(response).object()
        XCTAssertEqual(try json.string("code"), KnownFailureCode.authFailed.rawValue)
        try json.assertMissing("kind")
        try json.assertMissing("phase")
        try json.assertMissing("hint")

        let detailsJSON = try json.object("details")
        try detailsJSON.assertMissing("code")
        try detailsJSON.assertMissing("errorCode")
        XCTAssertEqual(try detailsJSON.string("kind"), DiagnosticFailureKind.authentication.rawValue)
        XCTAssertEqual(try detailsJSON.string("phase"), FailurePhase.authentication.rawValue)
        XCTAssertEqual(try detailsJSON.string("hint"), hint)
    }

    func testAuthFailureMappingPreservesReason() throws {
        let reason = "Invalid token"
        let response = FenceResponse.failure(HandoffConnectionError.disconnected(
            .authFailed(reason, hint: "Retry with the configured token.")
        ))
        guard case .error(let failure) = response else {
            return XCTFail("Expected typed error response")
        }

        XCTAssertEqual(failure.details.code, .authFailed)
        XCTAssertTrue(failure.message.contains(reason), failure.message)
        XCTAssertEqual(failure.details.hint, "Retry with the configured token.")

        let json = try publicJSONProbe(response).object()
        XCTAssertEqual(try json.string("code"), KnownFailureCode.authFailed.rawValue)
        XCTAssertEqual(
            try json.object("details").string("kind"),
            DiagnosticFailureKind.authentication.rawValue
        )
        XCTAssertTrue(try json.string("message").contains(reason))
    }

    @ButtonHeistActor
    func testTransportSendFailureUsesNetworkDiagnosticShape() async throws {
        let (fence, mockConn) = makeConnectedFence(configuration: .init(autoReconnect: false))
        mockConn.sendOutcome = .failed(.transportFailed(NetworkTransportFailure(.posix(.ECONNRESET))))

        let response: FenceResponse
        do {
            response = try await fence.execute(command: .getInterface)
        } catch {
            response = FenceResponse.failure(error)
        }
        guard case .error(let failure) = response else {
            return XCTFail("Expected typed error response")
        }

        XCTAssertEqual(failure.details.code, .transportNetworkError)
        XCTAssertNotEqual(failure.details.code, .requestActionFailed)
        XCTAssertEqual(failure.details.errorCode, KnownFailureCode.transportNetworkError.rawValue)
        XCTAssertEqual(failure.details.code.kind, .connection)
        XCTAssertEqual(failure.details.phase, .transport)
        XCTAssertTrue(failure.details.retryable)
        XCTAssertEqual(failure.details.hint, KnownFailureCode.transportNetworkError.defaultHint)
        XCTAssertTrue(failure.message.contains("posix"), failure.message)
        XCTAssertFalse(failure.message.contains(KnownFailureCode.requestActionFailed.rawValue), failure.message)

        let json = try publicJSONProbe(response).object()
        XCTAssertEqual(try json.string("status"), "error")
        XCTAssertEqual(try json.string("code"), KnownFailureCode.transportNetworkError.rawValue)
        try json.assertMissing("errorCode")
        try json.assertMissing("kind")
        try json.assertMissing("phase")
        try json.assertMissing("retryable")
        try json.assertMissing("hint")

        let detailsJSON = try json.object("details")
        try detailsJSON.assertMissing("code")
        try detailsJSON.assertMissing("errorCode")
        XCTAssertEqual(try detailsJSON.string("kind"), DiagnosticFailureKind.connection.rawValue)
        XCTAssertEqual(try detailsJSON.string("phase"), FailurePhase.transport.rawValue)
        XCTAssertTrue(try detailsJSON.bool("retryable"))
        XCTAssertEqual(try detailsJSON.string("hint"), KnownFailureCode.transportNetworkError.defaultHint)
    }

    @ButtonHeistActor
    func testDirectActionExpectIsRejectedBeforeDispatch() async throws {
        await assertValidationError(
            command: .scroll,
            arguments: [
                "expect": .object([
                    "type": .string("exists"),
                    "target": elementPredicateValue(label: "Receipt"),
                ]),
            ],
            equals: "command \"scroll\" direct dispatch does not support expect"
        )
    }

    func testSchemaFailureConstructsDiagnosticFailure() throws {
        let validationError = SchemaValidationError(
            field: "target",
            observed: "integer 7",
            expected: "object"
        )
        let response = FenceResponse.failure(validationError)
        guard case .error(let failure) = response else {
            return XCTFail("Expected typed error response")
        }

        XCTAssertEqual(failure.details.code, .requestValidationError)
        XCTAssertEqual(failure.details.errorCode, KnownFailureCode.requestValidationError.rawValue)
        XCTAssertEqual(failure.details.code.kind, .request)
        XCTAssertEqual(failure.message, validationError.message)
        XCTAssertEqual(failure.details.phase, .request)
        XCTAssertEqual(failure.details.retryable, false)
        XCTAssertEqual(failure.details.hint, "Fix the request so it satisfies the server-side validation rules.")
    }

}

private struct ThrowingEncodable: Encodable {
    func encode(to _: Encoder) throws {
        throw EncodingError.invalidValue(
            "value",
            EncodingError.Context(codingPath: [], debugDescription: "test failure")
        )
    }
}
