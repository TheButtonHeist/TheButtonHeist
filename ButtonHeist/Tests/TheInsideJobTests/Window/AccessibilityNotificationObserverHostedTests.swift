#if canImport(UIKit)
import UIKit
import XCTest

@testable import TheInsideJob

@MainActor
final class AccessibilityNotificationObserverHostedTests: XCTestCase {
    private enum WaitError: Error {
        case timedOut(AccessibilityNotificationKind)
    }

    func testDetachKeepsTheProcessCallbackInstalled() async throws {
        let bus = AccessibilityNotificationBus()

        AccessibilityNotificationObserver.shared.attach(bus)
        let installed = AccessibilityNotificationObserver.shared.isInstalled
        XCTAssertTrue(AccessibilityNotificationObserver.shared.hasDestination)

        AccessibilityNotificationObserver.shared.detach(bus)

        XCTAssertFalse(AccessibilityNotificationObserver.shared.hasDestination)
        XCTAssertEqual(AccessibilityNotificationObserver.shared.isInstalled, installed)
    }

    func testObserverReceivesPostedPayloadShapes() async throws {
        let bus = AccessibilityNotificationBus()

        AccessibilityNotificationObserver.shared.attach(bus)
        defer { AccessibilityNotificationObserver.shared.detach(bus) }
        guard AccessibilityNotificationObserver.shared.isInstalled else {
            return XCTFail("Expected _AXAddNotificationCallback to be available in the supported runtime")
        }
        let cursor = AccessibilityNotificationCursor(sequence: bus.latestSequence)

        UIAccessibility.post(notification: .announcement, argument: "BH announcement string payload")
        let announcement = try await waitForNotification(kind: .announcement, after: cursor, in: bus)
        XCTAssertEqual(announcement.kind, .announcement)
        guard case .string(let value) = announcement.notificationData else {
            return XCTFail("Expected string notification data, got \(announcement.notificationData)")
        }
        XCTAssertEqual(value, "BH announcement string payload")

        let container = NSObject()
        let element = UIAccessibilityElement(accessibilityContainer: container)
        element.accessibilityLabel = "BH layout element payload"
        UIAccessibility.post(notification: .layoutChanged, argument: element)
        let layoutChange = try await waitForNotification(kind: .layoutChanged, after: cursor, in: bus)
        XCTAssertEqual(layoutChange.kind, .layoutChanged)
        guard case .object(let objectIdentity) = layoutChange.notificationData else {
            return XCTFail("Expected element notification data, got \(layoutChange.notificationData)")
        }
        XCTAssertNil(objectIdentity.object)
        XCTAssertTrue(objectIdentity.summary?.contains("AXUIElementRef") == true)

        UIAccessibility.post(notification: .screenChanged, argument: nil)
        let screenChange = try await waitForNotification(kind: .screenChanged, after: cursor, in: bus)
        XCTAssertEqual(screenChange.kind, .screenChanged)
        guard case .none = screenChange.notificationData else {
            return XCTFail("Expected nil screen-change notification data, got \(screenChange.notificationData)")
        }
    }

    private func waitForNotification(
        kind: AccessibilityNotificationKind,
        after cursor: AccessibilityNotificationCursor,
        in bus: AccessibilityNotificationBus
    ) async throws -> PendingAccessibilityNotificationEvent {
        for _ in 0..<100 {
            if let event = bus.checkpoint(after: cursor, selection: .all).events.first(where: { $0.kind == kind }) {
                return event
            }
            await Task.yield()
            _ = await Task.cancellableSleep(for: .milliseconds(10))
        }
        throw WaitError.timedOut(kind)
    }
}

#endif
