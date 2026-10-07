import ButtonHeistTestSupport
import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

final class GetScreenArtifactResponseTests: XCTestCase {

    @ButtonHeistActor
    func testDefaultGetScreenWritesArtifactAndIncludesVisibleInterface() async throws {
        let tempDirectory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let interface = makeTestInterface(elements: [
            makeTestHeistElement(label: "Pay", traits: [.button], actions: []),
        ])
        let fence = Self.makeFence(
            tempDirectory: tempDirectory,
            pngData: pngBytes.base64EncodedString(),
            interface: interface
        )

        let response = try await fence.execute(command: .getScreen)

        guard case .screenshot(let path, let payload, let options) = response else {
            return XCTFail("Expected screenshot artifact response, got \(response)")
        }
        XCTAssertEqual(payload.width, 393)
        XCTAssertEqual(payload.height, 852)
        XCTAssertEqual(payload.interface?.projectedElements.count, 1)
        XCTAssertTrue(options.includeInterface)
        let artifactURL = URL(fileURLWithPath: path)
        XCTAssertEqual(try Data(contentsOf: artifactURL), pngBytes)
        XCTAssertEqual(try Self.posixPermissions(at: artifactURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try Self.posixPermissions(at: artifactURL), 0o600)

        let json = try publicJSONProbe(response).object()
        XCTAssertEqual(try json.string("status"), "ok")
        XCTAssertEqual(try json.string("path"), path)
        XCTAssertEqual(try json.double("width"), 393)
        XCTAssertEqual(try json.double("height"), 852)
        try json.assertMissing("pngData")
        try json.assertPresent("interface")
    }

    @ButtonHeistActor
    func testInlineGetScreenIncludesVisibleInterface() async throws {
        let tempDirectory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let pngData = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let interface = makeTestInterface(elements: [
            makeTestHeistElement(label: "Pay", traits: [.button], actions: []),
        ])
        let fence = Self.makeFence(tempDirectory: tempDirectory, pngData: pngData, interface: interface)

        let inlineResponse = try await fence.execute(command: .getScreen, values: [
            "inlineData": .bool(true),
        ])

        guard case .screenshotData(let inlinePayload, let inlineOptions) = inlineResponse else {
            return XCTFail("Expected inline screenshot response, got \(inlineResponse)")
        }
        XCTAssertEqual(inlinePayload.pngData, pngData)
        XCTAssertEqual(inlinePayload.interface?.projectedElements.count, 1)
        XCTAssertTrue(inlineOptions.includeInterface)

        let inlineJson = try publicJSONProbe(inlineResponse).object()
        XCTAssertEqual(try inlineJson.string("pngData"), pngData)
        try inlineJson.assertMissing("path")
        try inlineJson.assertPresent("interface")
    }

    @ButtonHeistActor
    func testAccessibilityModeRequestsAccessibilityScreenshot() async throws {
        let tempDirectory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let pngData = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let interface = makeTestInterface(elements: [
            makeTestHeistElement(label: "Pay", traits: [.button], actions: []),
        ])
        let config = TheFence.Configuration(artifactBaseDirectory: tempDirectory)
        let (fence, mockConnection) = makeConnectedFence(configuration: config)
        mockConnection.responseScript = { message in
            switch message {
            case .requestScreen:
                return .screen(ScreenPayload(
                    pngData: pngData,
                    width: 393,
                    height: 852,
                    interface: interface
                ))
            case .requestInterface:
                return .interface(makeTestInterface(elements: [], timestamp: Date()))
            default:
                return .actionResult(ActionResult.success(payload: .activate))
            }
        }

        let response = try await fence.execute(command: .getScreen, values: [
            "inlineData": .bool(true),
            "mode": .string("accessibility"),
        ])

        guard case .screenshotData(let payload, _) = response else {
            return XCTFail("Expected inline screenshot response, got \(response)")
        }
        XCTAssertEqual(payload.pngData, pngData)
        XCTAssertEqual(mockConnection.sentRequestScreenPayloads.last??.mode, .accessibility)
    }

    @ButtonHeistActor
    func testGetScreenPreservesObservationTimeoutAndAddsTransportHeadroom() async throws {
        let authoredTimeout: TimeInterval = 0.25
        let transportHeadroom: TimeInterval = 1
        let screen = ScreenPayload(
            pngData: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(),
            width: 393,
            height: 852,
            interface: makeTestInterface(elements: [], timestamp: Date())
        )
        let (fence, mockConnection) = makeConnectedFence(configuration: .init(
            postActionExpectationTimeoutBuffer: transportHeadroom
        ))
        fence.handoff.connect(to: TheFenceFixtures.testDevice)
        mockConnection.responseScript = { message in
            guard case .requestScreen = message else { return nil }
            return .screen(screen)
        }

        let response = try await fence.handleGetScreen(
            .init(destination: .inlineData, mode: .raw),
            timeout: authoredTimeout
        )

        XCTAssertEqual(
            mockConnection.sentRequestScreenPayloads.last??.timeout.seconds,
            authoredTimeout
        )
        XCTAssertEqual(
            fence.screenTransportTimeout(
                for: try WaitTimeout(validatingSeconds: authoredTimeout)
            ),
            authoredTimeout + transportHeadroom
        )
        guard case .screenshotData(let payload, _) = response else {
            return XCTFail("Expected inline screenshot response, got \(response)")
        }
        XCTAssertEqual(payload, screen)
    }

    @ButtonHeistActor
    func testInlineGetScreenRejectsOutputBeforeDispatch() async throws {
        let (fence, mockConnection) = makeConnectedFence()

        let response = try await fence.execute(command: .getScreen, values: [
            "inlineData": .bool(true),
            "output": .string("/tmp/buttonheist-screen.png"),
        ])

        guard case .error(let failure) = response else {
            return XCTFail("Expected inline/output contract error, got \(response)")
        }
        XCTAssertEqual(
            failure.message,
            "schema validation failed for inlineData/output: observed inlineData=true with output; " +
                "expected choose output for an artifact path or inlineData=true for inline PNG data, not both"
        )
        XCTAssertTrue(mockConnection.sent.isEmpty)
    }

    @ButtonHeistActor
    func testInlineGetScreenRejectsOversizePayloadBeforeDelivery() async throws {
        let tempDirectory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let oversizedPayload = String(
            repeating: "A",
            count: TheFence.DecodeLimits.maxInlineScreenshotBase64Bytes + 1
        )
        let fence = Self.makeFence(
            tempDirectory: tempDirectory,
            pngData: oversizedPayload,
            interface: makeTestInterface(elements: [], timestamp: Date())
        )

        let response = try await fence.execute(command: .getScreen, values: [
            "inlineData": .bool(true),
        ])

        guard case .error(let failure) = response else {
            return XCTFail("Expected oversize inline error, got \(response)")
        }
        XCTAssertTrue(failure.message.contains("Inline screenshot payload is too large"))
        XCTAssertEqual(failure.details.code, .screenInlinePayloadTooLarge)
        XCTAssertEqual(failure.details.phase, .client)
        XCTAssertEqual(failure.details.retryable, false)

        let json = try publicJSONProbe(response).object()
        XCTAssertEqual(try json.string("status"), "error")
        XCTAssertEqual(try json.string("code"), "screen.inline_payload_too_large")
        try json.assertMissing("pngData")
        try json.assertMissing("path")
    }

    @ButtonHeistActor
    func testGetScreenInvalidOutputThrowsTypedInvalidRequest() async throws {
        let tempDirectory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fence = Self.makeFence(
            tempDirectory: tempDirectory,
            pngData: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(),
            interface: makeTestInterface(elements: [], timestamp: Date())
        )

        do {
            _ = try await fence.execute(command: .getScreen, values: [
                "output": .string("/tmp/../buttonheist-screen.png"),
            ])
            XCTFail("Expected invalid output path to throw")
        } catch let error as FenceError {
            guard case .invalidRequest(let message) = error else {
                return XCTFail("Expected invalidRequest, got \(error)")
            }
            XCTAssertTrue(message.contains("Invalid output path"))
        } catch {
            XCTFail("Expected FenceError.invalidRequest, got \(error)")
        }
    }

    @ButtonHeistActor
    func testGetScreenInvalidBase64ThrowsTypedServerError() async throws {
        let tempDirectory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fence = Self.makeFence(
            tempDirectory: tempDirectory,
            pngData: "not base64",
            interface: makeTestInterface(elements: [], timestamp: Date())
        )

        do {
            _ = try await fence.execute(command: .getScreen)
            XCTFail("Expected invalid screenshot base64 to throw")
        } catch let error as FenceError {
            guard case .serverError(let serverError) = error else {
                return XCTFail("Expected serverError, got \(error)")
            }
            XCTAssertEqual(serverError.kind, .general)
            XCTAssertEqual(serverError.message, "Failed to decode screenshot data")
        } catch {
            XCTFail("Expected FenceError.serverError, got \(error)")
        }
    }

    private static func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("buttonheist-get-screen-\(UUID().uuidString)", isDirectory: true)
    }

    private static func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let permissions = attributes[.posixPermissions] as? Int {
            return permissions & 0o777
        }
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    @ButtonHeistActor
    private static func makeFence(
        tempDirectory: URL,
        pngData: String,
        interface: Interface
    ) -> TheFence {
        let config = TheFence.Configuration(artifactBaseDirectory: tempDirectory)
        let (fence, mockConnection) = makeConnectedFence(configuration: config)
        mockConnection.responseScript = { message in
            switch message {
            case .requestScreen:
                return .screen(ScreenPayload(
                    pngData: pngData,
                    width: 393,
                    height: 852,
                    interface: interface
                ))
            case .requestInterface:
                return .interface(makeTestInterface(elements: [], timestamp: Date()))
            default:
                return .actionResult(ActionResult.success(payload: .activate))
            }
        }
        return fence
    }
}
