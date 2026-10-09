import ButtonHeistTestSupport
import XCTest
import ThePlans
import AccessibilitySnapshotModel
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

extension TheFenceCompactFormattingContractTests {

    func testHeistActionStructuredOutputIncludesConcreteElementDeltaWithoutDumpingSuccessCompact() throws {
        let unchanged = (0..<3).map { index in
            makeTestHeistElement(label: "Row \(index)", identifier: "row_\(index)")
        }
        let lazyRow = makeTestHeistElement(
            label: "Lazy Row",
            value: "Loaded by scroll",
            identifier: "lazy_row",
            traits: [.staticText]
        )
        let evidence = makeObservationEvidence(
            before: makeTestInterface(elements: unchanged),
            after: makeTestInterface(elements: unchanged + [lazyRow]),
            afterScreenId: "screen"
        )
        let command = HeistActionCommand.activate(.predicate(ElementPredicate(label: "Load More")))
        let plan = try HeistPlan(body: [.action(ActionStep(command: command))])
        let result = try HeistResult(
            steps: [
                HeistResultFixture.action(
                    command: command,
                    result: ActionResult.success(
                        payload: .activate,
                        observation: .observed(evidence)
                    )
                ),
            ],
            durationMs: 8
        )
        let response = FenceResponse.heistExecution(plan: plan, report: HeistReport.project(result: result))

        let compact = response.compactFormatted()
        let report = try publicHeistReportJSON(response)
        let node = try XCTUnwrap(try report.array("nodes").first)
        let action = try node.object("evidence").object("action")
        let actionResult = try action.object("result")
        let delta = try actionResult.object("delta")

        try assertPublicHeistSummary(
            report.object("summary"),
            executedTopLevelStepCount: 1,
            executedNodeCount: 1,
            outputNodeCount: 1,
            durationMs: 8,
            abortedAtPath: nil
        )
        XCTAssertEqual(try node.string("path"), "$.body[0]")
        XCTAssertEqual(try node.string("kind"), "action")
        XCTAssertEqual(try node.string("status"), "passed")
        try node.assertMissing("durationMs")
        XCTAssertEqual(try action.string("commandName"), "activate")
        XCTAssertEqual(try actionResult.string("status"), "ok")
        XCTAssertEqual(try actionResult.string("method"), "activate")
        XCTAssertEqual(try actionResult.string("screenId"), "screen")
        XCTAssertEqual(try delta.string("kind"), "elementsChanged")
        XCTAssertEqual(try delta.int("elementCount"), 4)
        let added = try delta.object("edits").array("added")
        XCTAssertEqual(added.count, 1)
        try assertPublicElement(
            try XCTUnwrap(added.first),
            traits: ["staticText"],
            label: "Lazy Row",
            value: "Loaded by scroll",
            identifier: "lazy_row"
        )
        try node.assertMissing("action")
        XCTAssertTrue(compact.contains("-> elements changed"), compact)
        XCTAssertFalse(compact.contains(#"+ "Lazy Row":"Loaded by scroll" staticText id="lazy_row""#), compact)
    }

    func testPublicHeistJSONBoundsActionDeltaAndReportsOmissions() throws {
        let addedRows = (0..<8).map { index in
            makeTestHeistElement(
                label: "Lazy Row \(index)",
                value: "Loaded \(index)",
                identifier: "lazy_row_\(index)",
                traits: [.staticText]
            )
        }
        let evidence = makeObservationEvidence(
            before: makeTestInterface(elements: []),
            after: makeTestInterface(elements: addedRows),
            afterScreenId: "screen"
        )
        let command = HeistActionCommand.activate(.predicate(ElementPredicate(label: "Load More")))
        let plan = try HeistPlan(body: [.action(ActionStep(command: command))])
        let response = FenceResponse.heistExecution(
            plan: plan,
            report: HeistReport.project(result: try HeistResult(
                steps: [
                    HeistResultFixture.action(
                        command: command,
                        result: ActionResult.success(
                            payload: .activate,
                            observation: .observed(evidence)
                        )
                    ),
                ],
                durationMs: 8
            ))
        )

        let json = try publicJSONProbe(response)
        let report = try json.object("report")
        let node = try XCTUnwrap(try report.array("nodes").first)
        let actionResult = try node.object("evidence").object("action").object("result")
        let delta = try actionResult.object("delta")
        let edits = try delta.object("edits")
        let added = try edits.array("added")
        let omitted = try edits.object("omitted")

        XCTAssertEqual(try actionResult.string("status"), "ok")
        XCTAssertEqual(try actionResult.string("method"), "activate")
        XCTAssertEqual(try actionResult.string("screenId"), "screen")
        XCTAssertEqual(try delta.string("kind"), "elementsChanged")
        XCTAssertEqual(try delta.int("elementCount"), 8)
        XCTAssertEqual(added.count, 5)
        for index in 0..<5 {
            try assertPublicElement(
                added[index],
                traits: ["staticText"],
                label: "Lazy Row \(index)",
                value: "Loaded \(index)",
                identifier: "lazy_row_\(index)"
            )
        }
        XCTAssertEqual(try omitted.int("added"), 3)
        XCTAssertEqual(
            try omitted.strings("addedKeys"),
            ["identifier:lazy_row_5", "identifier:lazy_row_6", "identifier:lazy_row_7"]
        )
        try node.assertMissing("action")
        try delta.assertMissing("newInterface")
        try json.assertRecursivelyMissingKeys(["captures"])
    }

    func testPublicHeistJSONUsesBoundedScreenProjectionForActionDelta() throws {
        let afterRows = (0..<8).map { index in
            makeTestHeistElement(
                label: "Checkout Row \(index)",
                identifier: "checkout_row_\(index)",
                traits: [.staticText]
            )
        }
        let evidence = makeObservationEvidence(
            before: makeTestInterface(elements: []),
            after: makeTestInterface(elements: afterRows),
            beforeScreenId: "before",
            afterScreenId: "checkout",
            screenChanged: true
        )
        let command = HeistActionCommand.activate(.predicate(ElementPredicate(label: "Checkout")))
        let plan = try HeistPlan(body: [.action(ActionStep(command: command))])
        let response = FenceResponse.heistExecution(
            plan: plan,
            report: HeistReport.project(result: try HeistResult(
                steps: [
                    HeistResultFixture.action(
                        command: command,
                        result: ActionResult.success(
                            payload: .activate,
                            observation: .observed(evidence)
                        )
                    ),
                ],
                durationMs: 8
            ))
        )

        let json = try publicJSONProbe(response)
        let report = try json.object("report")
        let node = try XCTUnwrap(try report.array("nodes").first)
        let actionResult = try node.object("evidence").object("action").object("result")
        let delta = try actionResult.object("delta")
        let screen = try delta.object("screen")
        let elements = try screen.array("elements")

        XCTAssertEqual(try actionResult.string("status"), "ok")
        XCTAssertEqual(try actionResult.string("method"), "activate")
        XCTAssertEqual(try actionResult.string("screenId"), "checkout")
        XCTAssertEqual(try delta.string("kind"), "screenChanged")
        XCTAssertEqual(try delta.int("elementCount"), 8)
        XCTAssertEqual(try screen.int("elementCount"), 8)
        XCTAssertEqual(elements.count, 5)
        for index in 0..<5 {
            try assertPublicElement(
                elements[index],
                traits: ["staticText"],
                label: "Checkout Row \(index)",
                identifier: "checkout_row_\(index)"
            )
        }
        XCTAssertEqual(try screen.int("omittedElementCount"), 3)
        try node.assertMissing("action")
        try delta.assertMissing("newInterface")
        try json.assertRecursivelyMissingKeys(["tree", "captures"])
    }

    func testFailedHeistActionCompactOutputIncludesConcreteElementDeltaEvidence() throws {
        let unchanged = (0..<3).map { index in
            makeTestHeistElement(label: "Row \(index)", identifier: "row_\(index)")
        }
        let lazyRow = makeTestHeistElement(
            label: "Lazy Row",
            value: "Loaded by scroll",
            identifier: "lazy_row",
            traits: [.staticText]
        )
        let evidence = makeObservationEvidence(
            before: makeTestInterface(elements: unchanged),
            after: makeTestInterface(elements: unchanged + [lazyRow])
        )
        let command = HeistActionCommand.activate(.predicate(ElementPredicate(label: "Load More")))
        let plan = try HeistPlan(body: [.action(ActionStep(command: command))])
        let result = try HeistResult(
            steps: [
                HeistResultFixture.action(
                    command: command,
                    result: ActionResult.failure(
                        payload: .activate,
                        failureKind: .actionFailed,
                        message: "target stopped responding",
                        observation: .observed(evidence)
                    ),
                    failure: HeistFailureDetail(
                        category: .action,
                        contract: "activate command succeeds",
                        observed: "target stopped responding"
                    )
                ),
            ],
            durationMs: 8
        )

        let compact = FenceResponse.heistExecution(plan: plan, report: HeistReport.project(result: result)).compactFormatted()

        XCTAssertTrue(
            compact.contains("-> error[request.action_failed request retryable=false]: target stopped responding"),
            compact
        )
        XCTAssertTrue(compact.contains("evidence: elements changed"), compact)
        XCTAssertTrue(compact.contains(#"+ "Lazy Row":"Loaded by scroll" staticText id="lazy_row""#), compact)
    }

    func testFailedHeistActionReportsCanonicalActionResultActivationTrace() throws {
        let activationTrace = ActivationTrace(.activationPointFallback(
            axActivateReturned: false,
            tapActivationPoint: ScreenPoint(x: 195, y: 139),
            tapActivationSucceeded: true
        ))
        let command = HeistActionCommand.activate(.predicate(ElementPredicate(label: "Search all items")))
        let plan = try HeistPlan(body: [.action(ActionStep(command: command))])
        let response = FenceResponse.heistExecution(
            plan: plan,
            report: HeistReport.project(result: try HeistResult(
                steps: [
                    HeistResultFixture.action(
                        command: command,
                        result: ActionResult.activationFailure(
                            failureKind: .actionFailed,
                            message: "text entry failed: observed focus=none keyboardVisible=false activeTextInput=false",
                            observation: .none,
                            activationTrace: activationTrace
                        ),
                        failure: HeistFailureDetail(
                            category: .action,
                            contract: "action dispatch succeeds",
                            observed: "text entry failed: observed focus=none keyboardVisible=false activeTextInput=false"
                        )
                    ),
                ],
                durationMs: 8
            ))
        )

        let compact = response.compactFormatted()
        let node = try XCTUnwrap(try publicJSONProbe(response).object("report").array("nodes").first)
        let actionResult = try node.object("evidence").object("action").object("result")
        let renderedActivationTrace = try actionResult.object("activationTrace")

        try node.object("failure").assertMissing("activationTrace")
        XCTAssertEqual(try renderedActivationTrace.bool("axActivateReturned"), false)
        XCTAssertEqual(try renderedActivationTrace.bool("tapActivationDispatched"), true)
        XCTAssertEqual(try renderedActivationTrace.bool("tapActivationSucceeded"), true)
        XCTAssertEqual(try renderedActivationTrace.object("tapActivationPoint").double("x"), 195)
        XCTAssertEqual(try renderedActivationTrace.object("tapActivationPoint").double("y"), 139)
        XCTAssertTrue(compact.contains("activation: axActivateReturned=false"), compact)
        XCTAssertTrue(compact.contains("tapActivationDispatched=true"), compact)
        XCTAssertTrue(compact.contains("tapActivationSucceeded=true"), compact)
        XCTAssertTrue(compact.contains("tapActivationPoint=point(195,139)"), compact)
    }
}
