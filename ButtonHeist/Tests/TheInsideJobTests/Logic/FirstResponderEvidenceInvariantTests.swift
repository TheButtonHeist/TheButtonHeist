#if canImport(UIKit)
import XCTest
import UIKit
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
import ThePlans
@testable import TheScore

@MainActor
final class FirstResponderEvidenceInvariantTests: XCTestCase {

    func testParseNormalizesFirstResponderIntoValueSnapshot() async throws {
        let firstPath = TreePath([0])
        let secondPath = TreePath([1])
        let result = TheVault.CaptureResult(
            hierarchy: [
                .element(AccessibilityElement.make(label: "Email", traits: .textEntry), traversalIndex: 0),
                .element(AccessibilityElement.make(label: "Password", traits: .textEntry), traversalIndex: 1),
            ]
        )
        let facts = TheVault.BuildFacts(
            focus: TheVault.FocusFacts(firstResponderPaths: [secondPath])
        )

        let parsed = TheVault.buildObservation(from: result, facts: facts)
        let firstResponderHeistId = try XCTUnwrap(parsed.tree.viewportCapture.heistId(forPath: secondPath))
        let valueOnly = try InterfaceObservation.build(tree: parsed.tree)

        XCTAssertNotEqual(firstResponderHeistId, parsed.tree.viewportCapture.heistId(forPath: firstPath))
        XCTAssertEqual(parsed.tree.viewportCapture.firstResponderHeistId, firstResponderHeistId)
        XCTAssertEqual(valueOnly.tree.viewportCapture.firstResponderHeistId, firstResponderHeistId)
        XCTAssertTrue(valueOnly.liveCapture.dispatchReferences.elementRefs.isEmpty)
    }

    func testFirstResponderSnapshotDoesNotRetainUIKitObject() async {
        let heistId: HeistId = "email_field"
        var responder: UITextField? = UITextField()
        weak let releasedResponder: UITextField? = responder
        let observation = InterfaceObservation.makeForTests(
            [
                InterfaceObservation.TestEntry(
                    label: "Email",
                    heistId: heistId,
                    traits: .textEntry,
                    object: responder
                ),
            ],
            firstResponderHeistId: heistId
        )
        let capture = observation.liveCapture

        XCTAssertTrue(capture.object(for: heistId) === responder)
        responder = nil

        XCTAssertNil(releasedResponder)
        XCTAssertNil(capture.object(for: heistId))
        XCTAssertEqual(observation.tree.viewportCapture.firstResponderHeistId, heistId)
    }

    func testReplacementCaptureDoesNotInheritStaleFirstResponderEvidence() async {
        let heistId: HeistId = "email_field"
        let brains = TheBrains(tripwire: TheTripwire())
        var original: UITextField? = UITextField()
        weak let releasedOriginal: UITextField? = original
        let originalScreen = InterfaceObservation.makeForTests(
            [
                InterfaceObservation.TestEntry(
                    label: "Email",
                    heistId: heistId,
                    traits: .textEntry,
                    object: original
                ),
            ],
            firstResponderHeistId: heistId
        )
        await brains.vault.installObservationForTesting(originalScreen)
        XCTAssertEqual(brains.vault.firstResponderHeistId, heistId)

        let replacement = UITextField()
        let replacementScreen = InterfaceObservation.makeForTests(
            [
                InterfaceObservation.TestEntry(
                    label: "Email",
                    heistId: heistId,
                    traits: .textEntry,
                    object: replacement
                ),
            ],
            firstResponderHeistId: nil
        )
        await brains.vault.installObservationForTesting(replacementScreen)
        original = nil

        XCTAssertNil(releasedOriginal)
        XCTAssertNil(originalScreen.liveCapture.object(for: heistId))
        XCTAssertTrue(brains.vault.currentLiveCapture.object(for: heistId) === replacement)
        XCTAssertNil(brains.vault.firstResponderHeistId)
    }

    func testFirstResponderInflationRejectsCurrentResponderUnderWrongHeistId() async throws {
        let expected: HeistId = "email_field"
        let replacement: HeistId = "password_field"
        let brains = TheBrains(tripwire: TheTripwire())
        let expectedObject = UITextField()
        let replacementObject = UITextField()
        let expectedEntry = InterfaceObservation.TestEntry(
            label: "Email",
            heistId: expected,
            traits: .textEntry,
            object: expectedObject
        )
        let expectedScreen = InterfaceObservation.makeForTests(
            [expectedEntry],
            firstResponderHeistId: expected
        )
        await brains.vault.installObservationForTesting(expectedScreen)
        let expectedElement = try XCTUnwrap(brains.vault.interfaceElement(heistId: expected))
        let expectedTarget = try XCTUnwrap(brains.vault.minimumUniqueTarget(for: expectedElement))
            .resolve(in: .empty)
        guard case .resolved(let expectedLiveTarget) = brains.vault.resolveLiveActionTarget(
            for: expectedElement
        ) else {
            return XCTFail("Expected live first-responder target")
        }
        let inflatedTarget = ElementInflation.InflatedElementTarget(
            target: expectedTarget,
            treeElement: expectedElement,
            liveTarget: expectedLiveTarget,
            deadline: SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 1
            ),
            resolution: ActionSubjectResolution(origin: .visible)
        )
        let replacementScreen = InterfaceObservation.makeForTests(
            [
                expectedEntry,
                InterfaceObservation.TestEntry(
                    label: "Password",
                    heistId: replacement,
                    traits: .textEntry,
                    object: replacementObject
                ),
            ],
            firstResponderHeistId: replacement
        )
        let result = await brains.navigation.elementInflation.inflateFirstResponder(
            method: .editAction,
            inflateTarget: { target, method in
                XCTAssertEqual(target, expectedTarget)
                XCTAssertEqual(method, .editAction)
                await brains.vault.installObservationForTesting(replacementScreen)
                return .inflated(inflatedTarget)
            }
        )
        guard case .failed(let failure) = result else {
            return XCTFail("Expected stale first-responder failure, got \(result)")
        }

        XCTAssertEqual(failure.failedStep, .staleRefresh)
        XCTAssertEqual(failure.failureKind, .elementNotFound)
        XCTAssertEqual(
            failure.message,
            "element inflation failed [staleRefresh]: first responder no longer matches captured HeistId "
                + "email_field after inflation"
        )
    }

    func testFirstResponderInflationRejectsInflatedTargetUnderWrongHeistId() async throws {
        let expected: HeistId = "email_field"
        let replacement: HeistId = "password_field"
        let brains = TheBrains(tripwire: TheTripwire())
        let expectedObject = UITextField()
        let replacementObject = UITextField()
        let screen = InterfaceObservation.makeForTests(
            [
                InterfaceObservation.TestEntry(
                    label: "Email",
                    heistId: expected,
                    traits: .textEntry,
                    object: expectedObject
                ),
                InterfaceObservation.TestEntry(
                    label: "Password",
                    heistId: replacement,
                    traits: .textEntry,
                    object: replacementObject
                ),
            ],
            firstResponderHeistId: expected
        )
        await brains.vault.installObservationForTesting(screen)
        let expectedElement = try XCTUnwrap(brains.vault.interfaceElement(heistId: expected))
        let expectedAuthoredTarget = try XCTUnwrap(brains.vault.minimumUniqueTarget(for: expectedElement))
        let expectedTarget = try expectedAuthoredTarget.resolve(in: .empty)
        let replacementElement = try XCTUnwrap(brains.vault.interfaceElement(heistId: replacement))
        guard case .resolved(let replacementLiveTarget) = brains.vault.resolveLiveActionTarget(
            for: replacementElement
        ) else {
            return XCTFail("Expected live replacement target")
        }
        let inflatedTarget = ElementInflation.InflatedElementTarget(
            target: expectedTarget,
            treeElement: replacementElement,
            liveTarget: replacementLiveTarget,
            deadline: SemanticObservationDeadline(
                start: RuntimeElapsed.now,
                timeoutSeconds: 1
            ),
            resolution: ActionSubjectResolution(origin: .visible)
        )

        let result = await brains.navigation.elementInflation.inflateFirstResponder(
            method: .editAction,
            inflateTarget: { target, method in
                XCTAssertEqual(target, expectedTarget)
                XCTAssertEqual(method, .editAction)
                return .inflated(inflatedTarget)
            }
        )
        guard case .failed(let failure) = result else {
            return XCTFail("Expected mismatched first-responder failure, got \(result)")
        }

        XCTAssertEqual(failure.failedStep, .staleRefresh)
        XCTAssertEqual(failure.failureKind, .elementNotFound)
        XCTAssertEqual(
            failure.message,
            "element inflation failed [staleRefresh]: first responder no longer matches captured HeistId "
                + "email_field after inflation"
        )
    }

    func testSemanticObservationUsesCanonicalFirstResponderTarget() async throws {
        let brains = TheBrains(tripwire: TheTripwire())
        let screen = InterfaceObservation.makeForTests(
            elements: [
                (AccessibilityElement.make(label: "Email", traits: .textEntry), "email_field"),
                (AccessibilityElement.make(label: "Continue", traits: .button), "continue_button"),
            ],
            firstResponderHeistId: "email_field"
        )
        let expectedAuthoredTarget = AccessibilityTarget.label("Email")
        let expectedResolvedTarget = literalTarget(ResolvedElementPredicate.label("Email"))

        let publication = await brains.vault.semanticObservationStream
            .commitVisibleObservationForTesting(screen)
        let authoredTarget = try XCTUnwrap(brains.vault.firstResponderTarget(in: screen.tree))
        let resolvedTarget = try authoredTarget.resolve(in: .empty)

        XCTAssertEqual(authoredTarget, expectedAuthoredTarget)
        XCTAssertEqual(resolvedTarget, expectedResolvedTarget)
        XCTAssertEqual(publication.current.snapshot.context.firstResponder, authoredTarget)
        XCTAssertEqual(publication.current.snapshot.context.keyboardVisible, false)
    }

    func testAmbiguousLiveResponderEvidenceIsNotGuessed() async {
        let firstPath = TreePath([0])
        let secondPath = TreePath([1])
        let result = TheVault.CaptureResult(
            hierarchy: [
                .element(AccessibilityElement.make(label: "Email", traits: .textEntry), traversalIndex: 0),
                .element(AccessibilityElement.make(label: "Password", traits: .textEntry), traversalIndex: 1),
            ]
        )
        let facts = TheVault.BuildFacts(
            focus: TheVault.FocusFacts(
                firstResponderPaths: [firstPath, secondPath]
            )
        )

        let parsed = TheVault.buildObservation(from: result, facts: facts)

        XCTAssertNil(parsed.tree.viewportCapture.firstResponderHeistId)
    }

    func testFilteringPreservesOnlyFirstResponderStillInCommittedTree() async {
        let brains = TheBrains(tripwire: TheTripwire())
        let screen = InterfaceObservation.makeForTests(
            elements: [
                (AccessibilityElement.make(label: "Email", traits: .textEntry), "email_field"),
                (AccessibilityElement.make(label: "Continue", traits: .button), "continue_button"),
            ],
            firstResponderHeistId: "email_field"
        )

        let retained = screen.removingElements(withIds: ["continue_button"])
        let removed = screen.removingElements(withIds: ["email_field"])

        XCTAssertEqual(retained.tree.viewportCapture.firstResponderHeistId, "email_field")
        XCTAssertEqual(ScreenClassifier.snapshot(of: retained.tree).firstResponderHeistId, "email_field")
        XCTAssertNil(removed.tree.viewportCapture.firstResponderHeistId)
        XCTAssertNil(ScreenClassifier.snapshot(of: removed.tree).firstResponderHeistId)
        XCTAssertNil(brains.vault.firstResponderTarget(in: removed.tree))
    }

}

#endif
