import AccessibilitySnapshotModel
@_spi(ButtonHeistInternals) @_spi(ButtonHeistTooling) import ButtonHeist
import Foundation
import MCP
import Testing
import TheScore
@testable import ButtonHeistMCP

struct RenderResponseTests {

    @Test("inline screenshot render includes image content and interface text")
    func inlineScreenshotRenderIncludesImageAndInterfaceText() throws {
        let response = FenceResponse.screenshotData(
            payload: try #require(ScreenPayload.admit(
                pngData: "abc",
                width: 100,
                height: 200,
                interface: try Self.interfaceFixture()
            )),
            options: .init(includeInterface: true)
        )

        let result = ButtonHeistMCPServer.renderResponse(response)

        #expect(result.content.count == 2)
        guard case .image(let data, let mimeType, _, _) = result.content[0] else {
            Issue.record("expected first content item to be image")
            return
        }
        #expect(data == "abc")
        #expect(mimeType == "image/png")
        guard case .text(let text, _, _) = result.content[1] else {
            Issue.record("expected second content item to be text")
            return
        }
        #expect(text.contains(#"── group "Actions" id="actions" "semantic_actions__actions" frame=(0,40,200,100) ──"#))
    }

    @Test("heist render attaches bounded structured report")
    func heistRenderAttachesBoundedStructuredReport() throws {
        let row = Self.staticText(label: "Row 0", identifier: "row_0")
        let lazyRow = Self.staticText(
            label: "Lazy Row",
            value: "Loaded by scroll",
            identifier: "lazy_row"
        )
        let baseline = Observation.Snapshot(
            interface: try Self.interface([row]),
            context: .empty
        )
        let current = Observation.Snapshot(
            interface: try Self.interface([row, lazyRow]),
            context: .empty
        )
        let observationEvidence = Observation.Evidence(
            baseline: baseline,
            events: [.elementsChanged(current)],
            current: current,
            coverage: .complete
        )
        let command = HeistActionCommand.activate(.predicate(ElementPredicate(label: "Load More")))
        let plan = try HeistPlan(body: [.action(ActionStep(command: command))])
        let response = FenceResponse.heistExecution(
            plan: plan,
            report: HeistReport.project(
                result: try Self.passedExecutionResult(
                    command: command,
                    observationEvidence: observationEvidence
                )
            )
        )

        let result = ButtonHeistMCPServer.renderResponse(response)
        let root = try #require(result.structuredContent?.objectValue)
        let report = try #require(root["report"]?.objectValue)
        let nodes = try #require(report["nodes"]?.arrayValue)
        let node = try #require(nodes.first?.objectValue)
        let evidence = try #require(node["evidence"]?.objectValue)
        let action = try #require(evidence["action"]?.objectValue)
        let actionResult = try #require(action["result"]?.objectValue)
        let delta = try #require(actionResult["delta"]?.objectValue)
        let edits = try #require(delta["edits"]?.objectValue)
        let added = try #require(edits["added"]?.arrayValue)
        let addedElement = try #require(added.first?.objectValue)
        #expect(root["status"]?.stringValue == "ok")
        #expect(node["action"] == nil)
        #expect(actionResult["method"]?.stringValue == "activate")
        #expect(delta["kind"]?.stringValue == "elementsChanged")
        #expect(delta["elementCount"] == Value.int(2))
        #expect(addedElement["label"]?.stringValue == "Lazy Row")
        #expect(addedElement["value"]?.stringValue == "Loaded by scroll")
        #expect(addedElement["identifier"]?.stringValue == "lazy_row")
        #expect(actionResult["omitted"] == nil)
        #expect(!containsObjectKey("events", in: result.structuredContent))
        #expect(!containsObjectKey("baseline", in: result.structuredContent))
        guard case .text(let text, _, _)? = result.content.first else {
            Issue.record("expected compact text content")
            return
        }
        #expect(text.contains("-> elements changed"))
        #expect(!text.contains(#"+ "Lazy Row""#))
    }

    @Test("summary heist catalog render stays a compact menu")
    func summaryHeistCatalogRenderStaysCompactMenu() throws {
        let plan = try HeistPlan(
            name: "root",
            definitions: [
                HeistPlan(
                    name: "checkout",
                    parameter: .string(name: "item"),
                    body: [.action(ActionStep(command: .activate(.label("Checkout"))))]
                ),
            ],
            body: [.warn(WarnStep(message: "ready"))]
        )
        let response = FenceResponse.heistCatalog(
            try plan.heistDescriptions(),
            detail: .summary
        )

        let result = ButtonHeistMCPServer.renderResponse(response)

        guard let first = result.content.first, case .text(let text, _, _) = first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("checkout"))
        #expect(text.contains("summary=Reusable heist capability requiring string argument"))
        #expect(!text.contains("actions:"))
        #expect(!text.contains("nested RunHeist:"))
        #expect(!text.contains("semantic surfaces:"))
        #expect(!text.contains("predicate("))
        #expect(!text.contains("invoke"))
    }

    @Test("detailed heist catalog render includes safe derived fields")
    func detailedHeistCatalogRenderIncludesSafeDerivedFields() throws {
        let confirmation = try HeistPlan(
            name: "confirm",
            body: [.action(ActionStep(command: .activate(.identifier("confirm_button"))))]
        )
        let checkout = try HeistPlan(
            name: "checkout",
            definitions: [confirmation],
            body: [
                .action(ActionStep(
                    command: .activate(.label("Checkout")),
                    expectationPolicy: .expect(ActionExpectation(predicate: .exists(.label("Done"))))
                )),
                .invoke(HeistInvocationStep(path: "confirm")),
            ]
        )
        let plan = try HeistPlan(
            name: "root",
            definitions: [checkout],
            body: [.warn(WarnStep(message: "ready"))]
        )
        let response = FenceResponse.heistCatalog(
            try plan.heistDescriptions(),
            detail: .detailed
        )

        let result = ButtonHeistMCPServer.renderResponse(response)

        guard let first = result.content.first, case .text(let text, _, _) = first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("nested RunHeist: checkout.confirm"))
        #expect(text.contains("actions: activate"))
        #expect(text.contains("waits=0 expectations=1"))
        #expect(!text.contains("validation="))
        #expect(!text.contains("predicate("))
        #expect(!text.contains("point("))
        #expect(!text.contains("heistId"))

        let root = try #require(result.structuredContent?.objectValue)
        let heists = try #require(root["heists"]?.arrayValue)
        let entry = try #require(heists.first?.objectValue)
        #expect(entry["requiresArgument"] == .bool(false))
        #expect(entry["validationStatus"] == nil)
    }

    @Test("error render uses canonical public failure mapping")
    func errorRenderUsesCanonicalDiagnosticFailureMapping() throws {
        let response = FenceResponse.failure(FenceError.diagnostic(DiagnosticFailure(
            message: "Connection timed out",
            details: FailureDetails(code: .setupTimeout)
        )))
        guard case .error(let expected) = response else {
            Issue.record("Expected error response")
            return
        }

        let result = ButtonHeistMCPServer.renderResponse(response)
        let root = try #require(result.structuredContent?.objectValue)
        let details = try #require(root["details"]?.objectValue)

        #expect(result.isError == true)
        #expect(root["status"]?.stringValue == "error")
        #expect(root["message"]?.stringValue == expected.message)
        #expect(root["code"]?.stringValue == expected.details.errorCode)
        #expect(root["errorCode"] == nil)
        #expect(root["kind"] == nil)
        #expect(root["phase"] == nil)
        #expect(root["retryable"] == nil)
        #expect(root["hint"] == nil)
        #expect(details["code"] == nil)
        #expect(details["kind"]?.stringValue == expected.details.code.kind.rawValue)
        #expect(details["phase"]?.stringValue == expected.details.phase.rawValue)
        #expect(details["retryable"] == Value.bool(expected.details.retryable))
        #expect(details["hint"]?.stringValue == expected.details.hint)
    }

    @Test("invalid heist validation sets MCP error and preserves structured report")
    @ButtonHeistActor
    func invalidHeistValidationIsMCPErrorWithStructuredReport() async throws {
        let configuration = try EnvironmentConfig.resolve(autoReconnect: false)
        let fence = TheFence(configuration: configuration.fenceConfiguration)
        let request = try fence.admit(FenceCommandInput(
            command: .validateHeist,
            arguments: .init(values: [
                "plan": .string("HeistPlan { Activate( }"),
            ])
        ))
        let response = try await fence.execute(request)

        let result = ButtonHeistMCPServer.renderResponse(response)
        let root = try #require(result.structuredContent?.objectValue)

        #expect(result.isError == true)
        #expect(root["status"]?.stringValue == "ok")
        #expect(root["admissible"] == Value.bool(false))
        #expect(root["canonicalPlan"] == nil)
    }

    @Test("canonical JSON fallback replaces text and error status")
    func structuredEncodingFallbackReplacesTextAndErrorStatus() throws {
        let failure = DiagnosticFailure(
            message: "Failed to encode structured tool response: fallback failed",
            details: FailureDetails(code: .formattingJSONEncodingFailed)
        )
        let fallback = try FenceResponse.error(failure).jsonData(profile: .mcp, outputFormatting: [])
        let result = ButtonHeistMCPServer.renderResponse(
            .ok(message: "done"),
            jsonRenderer: { _ in .fallback(fallback, failure) }
        )
        let root = try #require(result.structuredContent?.objectValue)
        let details = try #require(root["details"]?.objectValue)

        #expect(result.isError == true)
        #expect(root["status"]?.stringValue == "error")
        #expect(root["code"]?.stringValue == "formatting.json_encoding_failed")
        #expect(root["errorCode"] == nil)
        #expect(root["kind"] == nil)
        #expect(root["phase"] == nil)
        #expect(root["retryable"] == nil)
        #expect(details["code"] == nil)
        #expect(details["kind"]?.stringValue == "client")
        #expect(details["phase"]?.stringValue == "client")
        #expect(details["retryable"] == Value.bool(false))
        guard case .text(let text, _, _)? = result.content.first else {
            Issue.record("expected diagnostic text content")
            return
        }
        #expect(text.contains("formatting.json_encoding_failed"))
        #expect(!text.contains("done"))
    }

    @Test("structured projection failure returns the canonical formatting diagnostic")
    func structuredProjectionFailureReturnsCanonicalFormattingDiagnostic() throws {
        let result = ButtonHeistMCPServer.renderResponse(
            .ok(message: "done"),
            jsonRenderer: { _ in throw StructuredProjectionTestError.failed }
        )
        let root = try #require(result.structuredContent?.objectValue)

        #expect(result.isError == true)
        #expect(root["status"]?.stringValue == "error")
        #expect(root["code"]?.stringValue == "formatting.json_encoding_failed")
        #expect(root["message"]?.stringValue?.contains("Failed to project structured tool response") == true)
        guard case .text(let text, _, _)? = result.content.first else {
            Issue.record("expected diagnostic text content")
            return
        }
        #expect(text.contains("formatting.json_encoding_failed"))
        #expect(!text.contains("done"))
    }

    private static func interfaceFixture() throws -> Interface {
        var elementAnnotations: [InterfaceElementAnnotation] = []
        let button = AccessibilityElement(
            description: "Submit",
            label: "Submit",
            value: nil,
            traits: AccessibilityTraits.fromNames(["button"]),
            identifier: nil,
            hint: nil,
            userInputLabels: nil,
            shape: .frame(AccessibilityRect(x: 0, y: 0, width: 100, height: 44)),
            activationPoint: AccessibilityPoint(x: 50, y: 22),
            usesDefaultActivationPoint: true,
            customActions: [],
            customContent: [],
            customRotors: [],
            accessibilityLanguage: nil,
            respondsToUserInteraction: true
        )
        elementAnnotations.append(InterfaceElementAnnotation(
            path: try #require(TreePath(validating: [0, 0])),
            actions: [.activate],
            geometry: geometry(
                ownerPath: try #require(TreePath(validating: [0]))
            )
        ))

        let container = AccessibilityContainer(
            type: .semanticGroup(label: "Actions", value: nil),
            identifier: "actions",
            frame: AccessibilityRect(x: 0, y: 40, width: 200, height: 100)
        )
        return try Interface(
            timestamp: Date(timeIntervalSince1970: 0),
            tree: [
                .container(container, children: [
                    .element(button, traversalIndex: 0),
                ]),
            ],
            annotations: InterfaceAnnotations(
                elements: elementAnnotations,
                containers: [
                    InterfaceContainerAnnotation(
                        path: try #require(TreePath(validating: [0])),
                        containerName: "semantic_actions__actions"
                    ),
                ]
            )
        )
    }

    private static func passedExecutionResult(
        command: HeistActionCommand,
        observationEvidence: Observation.Evidence
    ) throws -> HeistResult {
        let encoder = JSONEncoder()
        let settledObservationEvidence = Observation.Evidence(
            baseline: observationEvidence.baseline,
            events: observationEvidence.events + [.noChange],
            current: observationEvidence.current,
            coverage: observationEvidence.coverage
        )
        let expectation = try JSONDecoder().decode(
            HeistExpectationEvidence.self,
            from: JSONSerialization.data(withJSONObject: [
                "bindings": ["targets": [:], "strings": [:]],
                "observation": try jsonObject(settledObservationEvidence, encoder: encoder),
                "terminalCause": "observed",
                "timing": [
                    "budgetMs": 3,
                    "elapsedMs": 3,
                    "lastTreeChangeElapsedMs": 3,
                ],
            ])
        )
        let evidence = HeistActionEvidence.completed(
            result: .success(
                payload: .activate,
                observation: .observed(observationEvidence)
            ),
            expectation: expectation
        )
        let step: [String: Any] = [
            "path": "$.body[0]",
            "node": [
                "type": HeistExecutionStepKind.action.rawValue,
                "command": try jsonObject(command, encoder: encoder),
                "outcome": "passed",
                "evidence": try jsonObject(evidence, encoder: encoder),
                "children": [],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "steps": [step],
            "durationMs": 3,
        ])
        return try JSONDecoder().decode(HeistResult.self, from: data)
    }

    private static func jsonObject<Value: Encodable>(
        _ value: Value,
        encoder: JSONEncoder
    ) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: encoder.encode(value))
        return try #require(object as? [String: Any])
    }

    private static func interface(_ elements: [AccessibilityElement]) throws -> Interface {
        try Interface(
            timestamp: Date(timeIntervalSince1970: 0),
            tree: elements.enumerated().map { index, element in
                .element(element, traversalIndex: index)
            },
            annotations: InterfaceAnnotations(
                elements: elements.indices.map { index in
                    InterfaceElementAnnotation(
                        path: try #require(TreePath(validating: [index])),
                        actions: [],
                        geometry: geometry(ownerPath: .root)
                    )
                }
            )
        )
    }

    private static func geometry(ownerPath: TreePath) -> HeistElement.Geometry {
        HeistElement.Geometry(
            screen: .onscreen(
                frame: .available(ScreenRect(x: 0, y: 0, width: 100, height: 44)),
                activationPoint: .defaultCenter(ScreenPoint(x: 50, y: 22))
            ),
            view: .available(.init(
                ownerPath: ownerPath,
                frame: ViewRect(x: 0, y: 0, width: 100, height: 44),
                activationPoint: ViewPoint(x: 50, y: 22)
            ))
        )
    }

    private static func staticText(
        label: String,
        value: String? = nil,
        identifier: String? = nil
    ) -> AccessibilityElement {
        AccessibilityElement(
            description: label,
            label: label,
            value: value,
            traits: AccessibilityTraits.fromNames(["staticText"]),
            identifier: identifier,
            hint: nil,
            userInputLabels: nil,
            shape: .frame(AccessibilityRect(x: 0, y: 0, width: 100, height: 44)),
            activationPoint: AccessibilityPoint(x: 50, y: 22),
            usesDefaultActivationPoint: true,
            customActions: [],
            customContent: [],
            customRotors: [],
            accessibilityLanguage: nil,
            respondsToUserInteraction: false
        )
    }
}

private enum StructuredProjectionTestError: Error {
    case failed
}

private func containsObjectKey(_ key: String, in value: Value?) -> Bool {
    guard let value else { return false }
    switch value {
    case .object(let object):
        return object[key] != nil || object.values.contains { containsObjectKey(key, in: $0) }
    case .array(let values):
        return values.contains { containsObjectKey(key, in: $0) }
    default:
        return false
    }
}
