#if canImport(UIKit)
import ButtonHeistSupport
import XCTest
import ThePlans
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@testable import TheScore

@MainActor
extension TheVaultResolutionTests {

    func testAdmittedNotificationParsesAttachedElementIntoSemanticsOnly() throws {
        let button = UIButton(type: .system)
        button.accessibilityLabel = "Save"
        button.accessibilityValue = "Ready"
        let event = PendingAccessibilityNotificationEvent(
            sequence: 1,
            kind: .layoutChanged,
            timestamp: Date(timeIntervalSince1970: 0),
            notificationData: .string("Updated"),
            associatedElement: .object(AccessibilityNotificationObject(button)),
            provenance: .scoped
        )

        let notification = try XCTUnwrap(vault.admitNotifications([event]).first)

        XCTAssertEqual(notification.text, "Updated")
        XCTAssertEqual(notification.element?.assertable.label, "Save")
        XCTAssertEqual(notification.element?.assertable.value, "Ready")
        XCTAssertEqual(notification.kind, .layoutChanged)
    }

    func testScreenAndAnnouncementTextPublishesWithoutUIKitCorrelationContext() async throws {
        let observation = InterfaceObservation.makeForTests(elements: [
            (element(label: "Stable"), "stable"),
        ])
        _ = await publishVisible(observation)
        let context = UIButton(type: .system)
        context.accessibilityLabel = "BH Demo"
        for (code, text) in [
            (UInt32(1000), "Delayed code: 7429"),
            (UInt32(1008), "Ticket saved."),
        ] {
            let action = vault.accessibilityNotifications.beginActionWindow()
            vault.accessibilityNotifications.recordForTesting(
                code: code,
                notificationData: PendingAccessibilityNotificationPayload(text as NSString),
                associatedElement: PendingAccessibilityNotificationPayload(context)
            )
            let admitted = await action.admitCausallyCovered { coverage in
                await publishVisible(observation, covering: coverage)
            }
            let publication = try XCTUnwrap(admitted)

            let notifications: [Observation.Notification] = publication.events.compactMap { event in
                guard case .notification(let notification) = event else { return nil }
                return notification
            }

            XCTAssertEqual(notifications.count, 1)
            XCTAssertEqual(notifications.first?.text, text)
            XCTAssertNil(notifications.first?.element)
        }
    }

    func testSilentScreenNotificationDoesNotPublishAssociatedUIKitContext() async throws {
        let observation = InterfaceObservation.makeForTests(elements: [
            (element(label: "Stable"), "stable"),
        ])
        _ = await publishVisible(observation)
        let context = UIButton(type: .system)
        context.accessibilityLabel = "BH Demo"
        let action = vault.accessibilityNotifications.beginActionWindow()
        vault.accessibilityNotifications.recordForTesting(
            code: 1000,
            notificationData: .none,
            associatedElement: PendingAccessibilityNotificationPayload(context)
        )
        let admitted = await action.admitCausallyCovered { coverage in
            await publishVisible(observation, covering: coverage)
        }
        let publication = try XCTUnwrap(admitted)

        XCTAssertFalse(publication.events.contains { event in
            if case .notification = event { return true }
            return false
        })
        XCTAssertTrue(publication.events.contains { event in
            if case .screenChanged = event { return true }
            return false
        })
    }

    func testAdmittedNotificationDoesNotRetainUIKitObjectIdentity() throws {
        var button: UIButton? = UIButton(type: .system)
        button?.accessibilityLabel = "Save"
        let identity = AccessibilityNotificationObject(try XCTUnwrap(button))
        let event = PendingAccessibilityNotificationEvent(
            sequence: 1,
            kind: .layoutChanged,
            timestamp: Date(timeIntervalSince1970: 0),
            notificationData: .none,
            associatedElement: .object(identity),
            provenance: .scoped
        )
        button = nil

        let notification = try XCTUnwrap(vault.admitNotifications([event]).first)

        XCTAssertNil(notification.element)
    }

    func testNotificationEvidencePreservesAuthoredOrderBeforeObservation() async throws {
        let observation = InterfaceObservation.makeForTests(elements: [
            (element(label: "Stable"), "stable"),
        ])
        let baseline = await publishVisible(observation)
        let boundary = vault.semanticObservationStream.observationBoundary(
            scope: .visible
        )
        let action = vault.accessibilityNotifications.beginActionWindow()
        vault.accessibilityNotifications.recordForTesting(
            code: 1008,
            notificationData: PendingAccessibilityNotificationPayload("Saved" as NSString),
            associatedElement: .none
        )
        let admitted = await action.admitCausallyCovered { coverage in
            await publishVisible(observation, covering: coverage)
        }
        let publication = try XCTUnwrap(admitted)

        XCTAssertEqual(publication.events.count, 2)
        XCTAssertEqual(
            publication.events[0],
            .notification(try XCTUnwrap(Observation.Notification(
                text: "Saved",
                element: nil
            )))
        )
        XCTAssertEqual(publication.events[1], .noChange)

        let evidence = vault.state.evidence(after: boundary)
        XCTAssertEqual(evidence.events, publication.events)
        XCTAssertEqual(evidence.baseline, baseline.current.snapshot)
        XCTAssertEqual(evidence.current, publication.current.snapshot)
        XCTAssertEqual(evidence.notificationTexts, ["Saved"])
        XCTAssertEqual(evidence.coverage, .complete)
    }

    func testScopedIngressBeyondAmbientLimitCommitsCompleteOrderedVaultHistory() async {
        vault.state = TheVault.State(retentionLimit: 128)
        let observation = InterfaceObservation.makeForTests(elements: [
            (element(label: "Stable"), "stable"),
        ])
        _ = await publishVisible(observation)
        let boundary = vault.semanticObservationStream.observationBoundary(
            scope: .visible
        )
        let action = vault.accessibilityNotifications.beginActionWindow()
        let expectedText = (0..<65).map { "Action announcement \($0)" }
        for text in expectedText {
            vault.accessibilityNotifications.recordForTesting(
                code: 1008,
                notificationData: PendingAccessibilityNotificationPayload(text as NSString),
                associatedElement: .none
            )
        }

        let admitted = await action.admitCausallyCovered { coverage -> Bool? in
            guard await publishVisible(observation, covering: coverage) != nil else {
                return nil
            }
            let evidence = vault.state.evidence(after: boundary)

            XCTAssertEqual(coverage.after.sequence, 0)
            XCTAssertEqual(coverage.through.sequence, 65)
            XCTAssertEqual(coverage.scopedScreenChangedThrough, 0)
            XCTAssertEqual(evidence.notificationTexts, expectedText)
            XCTAssertEqual(evidence.coverage, .complete)
            return true
        }

        XCTAssertEqual(admitted, true)
    }

    func testNotificationProjectionReadsOrderedCanonicalHistory() async {
        let observation = InterfaceObservation.makeForTests(elements: [
            (element(label: "Stable"), "stable"),
        ])
        _ = await publishVisible(observation)

        let elementOnlyButton = UIButton(type: .system)
        elementOnlyButton.accessibilityLabel = "Subtotal"
        elementOnlyButton.accessibilityValue = "$12"

        let action = vault.accessibilityNotifications.beginActionWindow()
        vault.accessibilityNotifications.recordForTesting(
            code: 1008,
            notificationData: PendingAccessibilityNotificationPayload("Saved" as NSString),
            associatedElement: .none
        )
        vault.accessibilityNotifications.recordForTesting(
            code: 1001,
            notificationData: .none,
            associatedElement: PendingAccessibilityNotificationPayload(elementOnlyButton)
        )
        vault.accessibilityNotifications.recordForTesting(
            code: 1008,
            notificationData: PendingAccessibilityNotificationPayload("Ready to pay" as NSString),
            associatedElement: .none
        )
        let committed = await action.admitCausallyCovered { coverage in
            await publishVisible(observation, covering: coverage)
        }
        XCTAssertNotNil(committed)

        let notifications = vault.state.notifications

        XCTAssertEqual(notifications.map(\.text), ["Saved", nil, "Ready to pay"])
        XCTAssertEqual(notifications[0].element, nil)
        XCTAssertEqual(notifications[1].element?.assertable.label, "Subtotal")
        XCTAssertEqual(notifications[1].element?.assertable.value, "$12")
        XCTAssertNil(notifications[2].element)
    }

    func testNotificationProjectionContainsOnlyRetainedHistory() async {
        vault.state = TheVault.State(retentionLimit: 4)
        let observation = InterfaceObservation.makeForTests(elements: [
            (element(label: "Stable"), "stable"),
        ])
        _ = await publishVisible(observation)

        for text in ["First", "Second", "Third"] {
            let action = vault.accessibilityNotifications.beginActionWindow()
            vault.accessibilityNotifications.recordForTesting(
                code: 1008,
                notificationData: PendingAccessibilityNotificationPayload(text as NSString),
                associatedElement: .none
            )
            let committed = await action.admitCausallyCovered { coverage in
                await publishVisible(observation, covering: coverage)
            }
            XCTAssertNotNil(committed)
        }

        XCTAssertEqual(
            vault.state.notifications.compactMap(\.text),
            ["Second", "Third"]
        )
    }

    func testElementUpdateNotificationRereadsAccessibilityValue() async throws {
        let before = InterfaceObservation.makeForTests(elements: [
            (element(label: "Volume", value: "50%", traits: .adjustable), "volume"),
        ])
        let after = InterfaceObservation.makeForTests(elements: [
            (element(label: "Volume", value: "75%", traits: .adjustable), "volume"),
        ])
        _ = await publishVisible(before)

        let action = vault.accessibilityNotifications.beginActionWindow()
        vault.accessibilityNotifications.recordForTesting(
            code: 1005,
            notificationData: .none,
            associatedElement: .none
        )
        let admitted = await action.admitCausallyCovered { coverage in
            await publishVisible(after, covering: coverage)
        }
        let publication = try XCTUnwrap(admitted)

        guard case .elementsChanged(let snapshot)? = publication.events.last else {
            return XCTFail("Expected the value notification to trigger semantic rereading")
        }
        XCTAssertEqual(
            snapshot.interface.projectedElements.first?.semantics.assertable.value,
            "75%"
        )
        XCTAssertEqual(publication.current.snapshot, snapshot)
    }

    func testScreenChangedPublishesDepartureBoundaryAndActualArrival() async throws {
        let first = InterfaceObservation.makeForTests(elements: [
            (element(label: "Menu", traits: .header), "menu"),
        ])
        let baseline = await publishVisible(first)
        let action = vault.accessibilityNotifications.beginActionWindow()
        vault.accessibilityNotifications.recordForTesting(
            code: 1000,
            notificationData: .none,
            associatedElement: .none
        )
        let second = InterfaceObservation.makeForTests(elements: [
            (element(label: "Checkout", traits: .header), "checkout"),
        ])
        let admitted = await action.admitCausallyCovered { coverage in
            await publishVisible(second, covering: coverage)
        }
        let replacement = try XCTUnwrap(admitted)

        XCTAssertEqual(replacement.events.count, 3)
        guard case .elementsChanged(let departure) = replacement.events[0],
              case .screenChanged(let screen) = replacement.events[1],
              case .elementsChanged(let arrival) = replacement.events[2] else {
            return XCTFail("Expected departure, screen boundary, and actual arrival")
        }
        XCTAssertTrue(departure.interface.tree.isEmpty)
        XCTAssertEqual(departure.context, baseline.current.snapshot.context)
        XCTAssertEqual(screen.idAfter, "Checkout")
        XCTAssertEqual(arrival, replacement.current.snapshot)

        var history = Observation.History(retentionLimit: 8)
        _ = history.record(baseline.events, protectedBy: nil)
        let replacementRecord = history.record(replacement.events, protectedBy: nil)
        XCTAssertEqual(
            Array(try history.events(after: replacementRecord.lowerBound)),
            replacement.events
        )
        XCTAssertEqual(
            history.evidence(
                in: replacementRecord,
                baseline: baseline.current.snapshot,
                current: replacement.current.snapshot
            ).events,
            replacement.events
        )
    }

    func testPublishedSnapshotCarriesFirstResponderAsSemanticContext() async {
        let observation = InterfaceObservation.makeForTests(
            [
                .init(label: "Email", heistId: "email", traits: .textEntry),
                .init(label: "Continue", heistId: "continue", traits: .button),
            ],
            firstResponderHeistId: "email"
        )

        let publication = await publishVisible(observation)

        XCTAssertNotNil(publication.current.snapshot.context.firstResponder)
    }

    private func publishVisible(
        _ observation: InterfaceObservation
    ) async -> Observation.Publication {
        await vault.semanticObservationStream
            .commitVisibleObservationForTesting(observation)
    }

    private func publishVisible(
        _ observation: InterfaceObservation,
        covering coverage: AccessibilityNotificationCoverage
    ) async -> Observation.Publication? {
        let publication = await publishVisible(observation)
        guard vault.semanticObservationStream.currentObservation(
            covering: coverage
        ) != nil else {
            return nil
        }
        return publication
    }
}

#endif
