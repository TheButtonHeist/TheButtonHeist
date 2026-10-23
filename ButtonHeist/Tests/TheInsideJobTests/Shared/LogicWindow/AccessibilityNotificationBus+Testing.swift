#if canImport(UIKit)
import Foundation
@testable import TheInsideJob

extension AccessibilityNotificationBus {
    func recordForTesting(
        code: UInt32,
        timestamp: Date = Date(),
        notificationData: PendingAccessibilityNotificationPayload,
        associatedElement: PendingAccessibilityNotificationPayload
    ) {
        record(
            rawCode: code,
            timestamp: timestamp,
            notificationData: notificationData,
            associatedElement: associatedElement
        )
    }
}
#endif
