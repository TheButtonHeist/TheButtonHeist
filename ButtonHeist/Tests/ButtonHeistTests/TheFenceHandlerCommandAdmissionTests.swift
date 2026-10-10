import ButtonHeistTestSupport
import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
@_spi(ButtonHeistInternals) import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension TheFenceHandlerTests {

    @ButtonHeistActor
    func testActionRequiresCanonicalActionObject() async {
        await assertValidationError(
            command: .action,
            equals: "schema validation failed for action: observed missing; expected object"
        )
    }

    @ButtonHeistActor
    func testActionRejectsUnknownActionTypeBeforeDispatch() async throws {
        let (fence, connection) = makeConnectedFence()
        let response = try await fence.execute(command: .action, values: [
            "action": .object(["type": .string("legacyTap")]),
        ])

        assertValidationFailure(response) { failure in
            XCTAssertEqual(failure.details.code, .requestValidationError)
            XCTAssertTrue(failure.message.contains("legacyTap"))
            XCTAssertTrue(failure.message.contains("not a heist action command"))
        }
        XCTAssertTrue(connection.sent.isEmpty)
    }

    @ButtonHeistActor
    func testActionRejectsMalformedNestedPayloadBeforeDispatch() async throws {
        let (fence, connection) = makeConnectedFence()
        let response = try await fence.execute(command: .action, values: [
            "action": .object([
                "type": .string("scroll"),
                "payload": .object(["direction": .string("diagonal")]),
            ]),
        ])

        assertValidationFailure(response) { failure in
            XCTAssertEqual(failure.details.code, .requestValidationError)
            XCTAssertTrue(failure.message.contains("action.payload.direction"))
            XCTAssertTrue(failure.message.contains("diagonal"))
        }
        XCTAssertTrue(connection.sent.isEmpty)
    }

    @ButtonHeistActor
    func testDurableActionUsesTheHeistWirePipeline() async throws {
        let (fence, connection) = makeConnectedFence()
        let action = HeistActionCommand.activate(.identifier("myElement"))

        _ = try await fence.execute(command: .action, values: try actionArguments(action))

        XCTAssertEqual(connection.sent.count, 1)
        guard case .heistPlan(let run) = connection.sent.first?.0,
              case .action(let step) = run.plan.body.first else {
            return XCTFail("Expected the canonical single-step heist wire message")
        }
        XCTAssertEqual(step.command, action)
    }

    @ButtonHeistActor
    func testTransientActionUsesTheRuntimeActionWirePipeline() async throws {
        let (fence, connection) = makeConnectedFence()
        let action = HeistActionCommand.scroll(ScrollTarget(direction: .down))

        _ = try await fence.execute(command: .action, values: try actionArguments(action))

        XCTAssertEqual(connection.sent.count, 1)
        guard case .runtimeAction(let command) = connection.sent.first?.0 else {
            return XCTFail("Expected the canonical runtime action wire message")
        }
        XCTAssertEqual(command, action)
        XCTAssertNotNil(command.durableHeistActionFailure)
    }

    @ButtonHeistActor
    func testTransientActionRejectsExpectationBeforeDispatch() async throws {
        let (fence, connection) = makeConnectedFence()
        var arguments = try actionArguments(.scroll(ScrollTarget(direction: .down)))
        arguments["expect"] = try TheFence.HeistValuePayloadEncoder.encode(
            AccessibilityPredicate.exists(.label("Done"))
        )

        let response = try await fence.execute(command: .action, values: arguments)

        guard case .error(let failure) = response else {
            return XCTFail("Expected direct action expectation rejection")
        }
        XCTAssertEqual(failure.message, "command \"action\" direct dispatch does not support expect")
        XCTAssertTrue(connection.sent.isEmpty)
    }

    @ButtonHeistActor
    func testDurableActionPreservesExpectationInSingleStepPlan() async throws {
        let (fence, connection) = makeConnectedFence()
        var arguments = try actionArguments(.activate(.identifier("myElement")))
        let expectation = AccessibilityPredicate.exists(.label("Done"))
        arguments["expect"] = try TheFence.HeistValuePayloadEncoder.encode(expectation)
        arguments["timeout"] = .double(2)

        _ = try await fence.execute(command: .action, values: arguments)

        guard case .heistPlan(let run) = connection.sent.first?.0,
              case .action(let step) = run.plan.body.first,
              case .expect(let policy) = step.expectationPolicy else {
            return XCTFail("Expected one action with its admitted expectation")
        }
        XCTAssertEqual(policy.predicate, expectation)
        XCTAssertEqual(policy.timeout, .explicit(try .seconds(2)))
    }

    @ButtonHeistActor
    func testMalformedExpectationUsesFieldQualifiedFailure() async throws {
        let (fence, connection) = makeConnectedFence()
        var arguments = try actionArguments(.dismiss)
        arguments["expect"] = .object(["type": .string("eventually")])

        let response = try await fence.execute(command: .action, values: arguments)

        assertValidationFailure(response) { failure in
            XCTAssertEqual(failure.details.code, .requestValidationError)
            XCTAssertTrue(failure.message.contains("expect.type"))
            XCTAssertTrue(failure.message.contains("Predicate type \"eventually\" is not valid"))
        }
        XCTAssertTrue(connection.sent.isEmpty)
    }

    private func actionArguments(_ action: HeistActionCommand) throws -> [String: HeistValue] {
        ["action": try TheFence.HeistValuePayloadEncoder.encode(action)]
    }

    private func assertValidationFailure(
        _ response: FenceResponse,
        assertions: (DiagnosticFailure) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .error(let failure) = response else {
            return XCTFail("Expected validation failure, got \(response)", file: file, line: line)
        }
        assertions(failure)
    }
}
