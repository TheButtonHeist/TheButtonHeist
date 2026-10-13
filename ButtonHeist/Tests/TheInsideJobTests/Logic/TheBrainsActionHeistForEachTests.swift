#if canImport(UIKit)
import ButtonHeistTestSupport
import XCTest

@testable import AccessibilitySnapshotParser
@_spi(ButtonHeistInternals) @testable import ThePlans
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

final class HeistExecutionForEachTests: XCTestCase {
    func testForEachElementWithNoMatchesCompletesWithoutIterations() throws {
        let plan = try elementLoopPlan(body: [
            .warn(WarnStep(message: "unreachable")),
        ])
        var driver = try HeistExecutionTestDriver(
            plan: plan,
            script: ExecutionRunScript(snapshots: [makeTestObservationSnapshot(labels: ["Keep"])])
        )

        let completion = try driver.run()
        let loop = try XCTUnwrap(completion.steps.first)

        XCTAssertEqual(loop.status, .passed)
        XCTAssertEqual(loop.forEachEvidence?.matchedCount, 0)
        XCTAssertEqual(loop.forEachEvidence?.iterationCount, 0)
        XCTAssertTrue(loop.children.isEmpty)
        XCTAssertEqual(driver.requests.compactMap(\.snapshotScope), [.discovery])
    }

    func testForEachSnapshotEffectIDCannotBeConfusedWithTargetOrdinal() throws {
        let snapshot = makeTestObservationSnapshot(labels: ["Delete", "Delete"])
        let plan = try elementLoopPlan(body: [
            .warn(WarnStep(message: "iteration")),
        ])
        var execution = try HeistExecution(plan: plan)
        let now = ContinuousClock.now
        let firstRequest = try XCTUnwrap(execution.start(at: now, timeout: .default).singleSnapshotRequest)

        guard case .perform(.currentSnapshot(let retainedID, _, _)) = execution.reduce(.currentSnapshot(
            HeistExecution.EffectID(rawValue: 0),
            snapshot,
            at: now
        )), retainedID == firstRequest.id else {
            return XCTFail("Target ordinal zero must not satisfy a snapshot request")
        }

        let secondRequest = try XCTUnwrap(
            execution.reduce(.currentSnapshot(firstRequest.id, snapshot, at: now))
                .singleSnapshotRequest
        )
        XCTAssertNotEqual(secondRequest.id, firstRequest.id)

        guard case .complete(let completion) = execution.reduce(.currentSnapshot(
            secondRequest.id,
            snapshot,
            at: now
        )) else {
            return XCTFail("The second typed snapshot request must complete the loop")
        }
        let loop = try XCTUnwrap(completion.steps.first)
        XCTAssertEqual(
            loop.children.compactMap(\.forEachEvidence?.targetOrdinal),
            [0, 1]
        )
    }

    func testForEachElementLimitFailsBeforeRunningBody() throws {
        let plan = try HeistPlan(body: [
            .forEachElement(try ForEachElementStep(
                matching: .label("Delete"),
                limit: 1,
                parameter: "target",
                body: [.fail(FailStep(message: "body must not run"))]
            )),
            .warn(WarnStep(message: "later")),
        ])
        var driver = try HeistExecutionTestDriver(
            plan: plan,
            script: ExecutionRunScript(snapshots: [
                makeTestObservationSnapshot(labels: ["Delete", "Delete"]),
            ])
        )

        let completion = try driver.run()
        let loop = try XCTUnwrap(completion.steps.first)

        XCTAssertEqual(loop.status, .failed)
        XCTAssertEqual(loop.forEachEvidence?.matchedCount, 2)
        XCTAssertEqual(loop.forEachEvidence?.iterationCount, 0)
        XCTAssertTrue(loop.children.isEmpty)
        XCTAssertEqual(completion.steps.last?.status, .skipped)
    }

    func testForEachStringPreservesAuthoredValueOrder() throws {
        let plan = try HeistPlan(body: [
            .forEachString(try ForEachStringStep(
                values: ["milk", "eggs", "bread"],
                parameter: "item",
                body: [.warn(WarnStep(message: "visited"))]
            )),
        ])
        var driver = try HeistExecutionTestDriver(plan: plan)

        let completion = try driver.run()
        let loop = try XCTUnwrap(completion.steps.first)

        XCTAssertEqual(loop.status, .passed)
        XCTAssertEqual(loop.forEachEvidence?.iterationCount, 3)
        XCTAssertEqual(
            loop.children.compactMap(\.forEachEvidence?.value),
            ["milk", "eggs", "bread"]
        )
        XCTAssertEqual(loop.children.flatMap(\.children).map(\.kind), [
            .warn,
            .warn,
            .warn,
        ])
    }

    func testForEachFailureStopsRemainingIterationsAndRootSiblings() throws {
        let plan = try HeistPlan(body: [
            .forEachString(try ForEachStringStep(
                values: ["first", "second"],
                parameter: "item",
                body: [
                    .fail(FailStep(message: "stop")),
                    .warn(WarnStep(message: "nested later")),
                ]
            )),
            .warn(WarnStep(message: "root later")),
        ])
        var driver = try HeistExecutionTestDriver(plan: plan)

        let completion = try driver.run()
        let loop = try XCTUnwrap(completion.steps.first)

        XCTAssertEqual(loop.status, .failed)
        XCTAssertEqual(loop.children.count, 1)
        XCTAssertEqual(loop.children.first?.children.map(\.status), [.failed, .skipped])
        XCTAssertEqual(completion.steps.last?.status, .skipped)
    }
}

private extension HeistExecutionForEachTests {
    func elementLoopPlan(body: [HeistStep]) throws -> HeistPlan {
        try HeistPlan(body: [
            .forEachElement(try ForEachElementStep(
                matching: .label("Delete"),
                limit: 10,
                parameter: "target",
                body: body
            )),
        ])
    }
}

private extension HeistExecution.Effect {
    var snapshotScope: SemanticObservationScope? {
        guard case .currentSnapshot(_, let scope, _) = self else { return nil }
        return scope
    }
}

#endif // canImport(UIKit)
