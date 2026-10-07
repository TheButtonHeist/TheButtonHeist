import ButtonHeistTestSupport
import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

final class PendingRequestRegistryTests: XCTestCase {

    @ButtonHeistActor
    func testWrongResponseTypeFailsRegisteredExpectation() async throws {
        let registry = TheFence.PendingRequestRegistry()
        let registered = expectation(description: "request registered")

        let task = Task { @ButtonHeistActor in
            try await registry.waitForResponse(
                .pong,
                requestId: "req-mismatch",
                timeout: 5,
                afterRegister: { registered.fulfill() }
            )
        }
        defer { task.cancel() }

        await fulfillment(of: [registered], timeout: 1)

        XCTAssertTrue(registry.resolveTransientResponse(
            .interface(makeTestInterface(elements: [], timestamp: Date())),
            requestId: "req-mismatch"
        ))

        do {
            _ = try await task.value
            XCTFail("Expected protocol mismatch")
        } catch {
            assertProtocolMismatch(
                error,
                contains: [
                    "req-mismatch",
                    "expected pong response",
                    "received interface response",
                ]
            )
        }

        XCTAssertTrue(registry.resolveTransientResponse(.pong(makePong()), requestId: "req-mismatch"))
    }

    @ButtonHeistActor
    func testRequestIdCannotRegisterDifferentResponseShapes() async throws {
        let registry = TheFence.PendingRequestRegistry()
        let requestId: RequestID = "shared-request-id"
        let registered = expectation(description: "original request registered")

        let actionTask = Task { @ButtonHeistActor in
            try await registry.waitForResponse(
                .action,
                requestId: requestId,
                timeout: 5,
                afterRegister: { registered.fulfill() }
            )
        }
        defer { actionTask.cancel() }

        await fulfillment(of: [registered], timeout: 1)

        do {
            _ = try await registry.waitForResponse(
                .pong,
                requestId: requestId,
                timeout: 0.01
            )
            XCTFail("Expected duplicate request id failure")
        } catch {
            guard case TheFence.PendingRequestError.duplicateRequestId(let duplicateId) = error else {
                return XCTFail("Expected duplicate request id error, got \(error)")
            }
            XCTAssertEqual(duplicateId, requestId)
        }

        XCTAssertTrue(registry.resolveTransientResponse(
            .actionResult(ActionResult.success(payload: .activate)),
            requestId: requestId
        ))
        _ = try await actionTask.value
    }

    @ButtonHeistActor
    func testTransientFailureResolvesMatchingRequestOnce() async throws {
        let registry = TheFence.PendingRequestRegistry()
        let failedRegistered = expectation(description: "failed request registered")
        let survivingRegistered = expectation(description: "surviving request registered")

        let failedTask = Task { @ButtonHeistActor in
            try await registry.waitForResponse(
                .pong,
                requestId: "req-failure",
                timeout: 5,
                afterRegister: { failedRegistered.fulfill() }
            )
        }
        let survivingTask = Task { @ButtonHeistActor in
            try await registry.waitForResponse(
                .interface,
                requestId: "req-survives",
                timeout: 5,
                afterRegister: { survivingRegistered.fulfill() }
            )
        }
        defer {
            failedTask.cancel()
            survivingTask.cancel()
        }

        await fulfillment(of: [failedRegistered, survivingRegistered], timeout: 1)

        registry.resolveTransientFailure(
            FenceError(DeviceSendFailure.notConnected),
            requestId: "req-failure"
        )
        registry.resolveTransientFailure(FenceError.actionTimeout, requestId: "req-failure")
        XCTAssertTrue(registry.resolveTransientResponse(
            .interface(makeTestInterface(elements: [], timestamp: Date())),
            requestId: "req-survives"
        ))

        do {
            _ = try await failedTask.value
            XCTFail("Expected send failure")
        } catch FenceError.notConnected {
            // expected
        } catch {
            XCTFail("Expected notConnected, got \(error)")
        }

        let interface = try await survivingTask.value
        XCTAssertTrue(interface.tree.isEmpty)
    }

    @ButtonHeistActor
    func testServerErrorPreservesCanonicalPayload() async throws {
        let registry = TheFence.PendingRequestRegistry()
        let requestId: RequestID = "req-server-error"
        let registered = expectation(description: "request registered")
        let serverError = ServerError(
            kind: .general,
            message: "request failed",
            recoveryHint: "Try again."
        )

        let task = Task { @ButtonHeistActor in
            try await registry.waitForResponse(
                .pong,
                requestId: requestId,
                timeout: 5,
                afterRegister: { registered.fulfill() }
            )
        }
        defer { task.cancel() }

        await fulfillment(of: [registered], timeout: 1)
        XCTAssertTrue(registry.resolveTransientResponse(.error(serverError), requestId: requestId))

        do {
            _ = try await task.value
            XCTFail("Expected server error")
        } catch FenceError.serverError(let receivedError) {
            XCTAssertEqual(receivedError, serverError)
        } catch {
            XCTFail("Expected canonical server error, got \(error)")
        }
    }

    @ButtonHeistActor
    func testProtocolTrafficDoesNotConsumePendingResponse() async throws {
        let registry = TheFence.PendingRequestRegistry()
        let requestId: RequestID = "req-protocol-traffic"
        let registered = expectation(description: "request registered")

        let task = Task { @ButtonHeistActor in
            try await registry.waitForResponse(
                .pong,
                requestId: requestId,
                timeout: 5,
                afterRegister: { registered.fulfill() }
            )
        }
        defer { task.cancel() }

        await fulfillment(of: [registered], timeout: 1)
        XCTAssertFalse(registry.resolveTransientResponse(.serverHello, requestId: requestId))
        XCTAssertTrue(registry.resolveTransientResponse(.pong(makePong()), requestId: requestId))
        _ = try await task.value
    }

    @ButtonHeistActor
    func testCancelAllCancelsOutstandingRequests() async throws {
        let registry = TheFence.PendingRequestRegistry()
        let pongRegistered = expectation(description: "pong request registered")
        let interfaceRegistered = expectation(description: "interface request registered")

        let pongTask = Task { @ButtonHeistActor in
            try await registry.waitForResponse(
                .pong,
                requestId: "req-pong",
                timeout: 5,
                afterRegister: { pongRegistered.fulfill() }
            )
        }
        let interfaceTask = Task { @ButtonHeistActor in
            try await registry.waitForResponse(
                .interface,
                requestId: "req-interface",
                timeout: 5,
                afterRegister: { interfaceRegistered.fulfill() }
            )
        }
        defer {
            pongTask.cancel()
            interfaceTask.cancel()
        }

        await fulfillment(of: [pongRegistered, interfaceRegistered], timeout: 1)

        registry.cancelAll(error: FenceError.notConnected)

        do {
            _ = try await pongTask.value
            XCTFail("Expected pong request cancellation")
        } catch FenceError.notConnected {
            // expected
        } catch {
            XCTFail("Expected notConnected, got \(error)")
        }

        do {
            _ = try await interfaceTask.value
            XCTFail("Expected interface request cancellation")
        } catch FenceError.notConnected {
            // expected
        } catch {
            XCTFail("Expected notConnected, got \(error)")
        }
    }

    @ButtonHeistActor
    func testTimeoutReleasesRequestIdForAReplacementOwner() async throws {
        let registry = TheFence.PendingRequestRegistry()
        let requestId: RequestID = "req-timeout"

        do {
            _ = try await registry.waitForResponse(
                .pong,
                requestId: requestId,
                timeout: 0
            )
            XCTFail("Expected action timeout")
        } catch FenceError.actionTimeout {
            // expected
        } catch {
            XCTFail("Expected actionTimeout, got \(error)")
        }

        XCTAssertTrue(registry.resolveTransientResponse(.pong(makePong()), requestId: requestId))

        let replacementRegistered = expectation(description: "replacement request registered")
        let replacementTask = Task { @ButtonHeistActor in
            try await registry.waitForResponse(
                .pong,
                requestId: requestId,
                timeout: 5,
                afterRegister: { replacementRegistered.fulfill() }
            )
        }
        defer { replacementTask.cancel() }

        await fulfillment(of: [replacementRegistered], timeout: 1)
        XCTAssertTrue(registry.resolveTransientResponse(.pong(makePong()), requestId: requestId))
        _ = try await replacementTask.value
    }

    @ButtonHeistActor
    func testCancellationReleasesOnlyTheCancelledRequestOwner() async throws {
        let registry = TheFence.PendingRequestRegistry()
        let requestId: RequestID = "req-cancelled"
        let registered = expectation(description: "cancelled request registered")

        let cancelledTask = Task { @ButtonHeistActor in
            try await registry.waitForResponse(
                .pong,
                requestId: requestId,
                timeout: 5,
                afterRegister: { registered.fulfill() }
            )
        }
        await fulfillment(of: [registered], timeout: 1)
        cancelledTask.cancel()

        do {
            _ = try await cancelledTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let replacementRegistered = expectation(description: "replacement request registered")
        let replacementTask = Task { @ButtonHeistActor in
            try await registry.waitForResponse(
                .pong,
                requestId: requestId,
                timeout: 5,
                afterRegister: { replacementRegistered.fulfill() }
            )
        }
        defer { replacementTask.cancel() }

        await fulfillment(of: [replacementRegistered], timeout: 1)
        XCTAssertTrue(registry.resolveTransientResponse(.pong(makePong()), requestId: requestId))
        _ = try await replacementTask.value
    }

    private func assertProtocolMismatch(
        _ error: Error,
        contains expectedSubstrings: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case FenceError.connectionFailure(let failure) = error else {
            return XCTFail("Expected protocol mismatch FenceError, got \(error)", file: file, line: line)
        }

        XCTAssertEqual(failure.details.code, .protocolMismatch, file: file, line: line)
        XCTAssertEqual(failure.details.phase, .protocolNegotiation, file: file, line: line)
        XCTAssertFalse(failure.details.retryable, file: file, line: line)
        XCTAssertEqual(failure.details.hint, KnownFailureCode.protocolMismatch.defaultHint, file: file, line: line)
        for substring in expectedSubstrings {
            XCTAssertTrue(
                failure.message.contains(substring),
                "Expected message to contain '\(substring)', got '\(failure.message)'",
                file: file,
                line: line
            )
        }
    }

    private func makePong() -> PongPayload {
        PongPayload(
            buttonHeistVersion: "0.0.1",
            appName: "MockApp",
            bundleIdentifier: "com.test.mock",
            appVersion: "1.0",
            appBuild: "1",
            serverInstanceIdentifier: "mock-server",
            serverTimestampMs: 1_700_000_000_000
        )
    }
}
