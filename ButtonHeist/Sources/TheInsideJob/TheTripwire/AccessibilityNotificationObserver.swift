#if canImport(UIKit)
#if DEBUG
import Foundation
import os
import TheScore
import UIKit

private let accessibilityNotificationLogger = ButtonHeistLog.logger(.insideJob(.accessibility))

typealias AccessibilityNotificationCallback = @MainActor (
    UInt32,
    AnyObject?,
    AnyObject?
) -> Void

/// Retains one private callback payload until it can cross onto the main
/// dispatch queue. The values are immutable references and are normalized by
/// the main-actor handler before entering Button Heist's retained evidence.
private final class PendingAccessibilityNotificationCallback: @unchecked Sendable {
    let code: UInt32
    let notificationData: AnyObject?
    let associatedElement: AnyObject?

    init(
        code: UInt32,
        notificationData: AnyObject?,
        associatedElement: AnyObject?
    ) {
        self.code = code
        self.notificationData = notificationData
        self.associatedElement = associatedElement
    }

    @MainActor
    func deliver(to handler: AccessibilityNotificationCallback) {
        dispatchPrecondition(condition: .onQueue(.main))
        autoreleasepool {
            handler(code, notificationData, associatedElement)
        }
    }
}

/// The private UIAccessibility callback is not actor-isolated. Normalize its
/// delivery onto the main dispatch queue before giving UIKit-owned objects to
/// the main-actor observer. Dispatch's serial FIFO ordering is the observer's
/// callback order.
enum AccessibilityNotificationCallbackIngress {
    static func enqueue(
        code: UInt32,
        notificationData: AnyObject?,
        associatedElement: AnyObject?,
        handler: @escaping AccessibilityNotificationCallback
    ) {
        let pending = PendingAccessibilityNotificationCallback(
            code: code,
            notificationData: notificationData,
            associatedElement: associatedElement
        )
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                pending.deliver(to: handler)
            }
        }
    }
}

/// Owns the one process callback and routes it to the active Vault bus.
@MainActor
final class AccessibilityNotificationObserver {
    private struct CallbackInstallation {
        let retainedCallback: AccessibilityNotificationPrivateSPI.InstalledCallback?
    }

    private typealias CallbackInstaller = @MainActor (
        _ callback: @escaping AccessibilityNotificationCallback
    ) throws -> CallbackInstallation

    static let shared = AccessibilityNotificationObserver()

    private let callbackInstaller: CallbackInstaller
    private weak var destination: AccessibilityNotificationBus?
    private var installation: CallbackInstallation?
    private var installationAttempted = false

    var hasDestination: Bool {
        destination != nil
    }

    var isInstalled: Bool {
        installation != nil
    }

    private convenience init() {
        self.init { callback in
            let armed = AccessibilityNotificationPrivateSPI.enableUnitTestModeIfAvailable()
            if !armed {
                accessibilityNotificationLogger.info("Private accessibility unit-test mode SPI is unavailable")
            }
            let callback = try AccessibilityNotificationPrivateSPI.installNotificationCallback(
                callback
            )
            return CallbackInstallation(
                retainedCallback: callback
            )
        }
    }

    private init(callbackInstaller: @escaping CallbackInstaller) {
        self.callbackInstaller = callbackInstaller
    }

    convenience init(
        installCallbackForTesting: @escaping @MainActor () throws -> Void
    ) {
        self.init { _ in
            try installCallbackForTesting()
            return CallbackInstallation(retainedCallback: nil)
        }
    }

    convenience init(
        installCallbackForTesting: @escaping @MainActor (
            _ callback: @escaping AccessibilityNotificationCallback
        ) -> Void
    ) {
        self.init { callback in
            installCallbackForTesting(callback)
            return CallbackInstallation(retainedCallback: nil)
        }
    }

    convenience init(
        installPrivateCallbackForTesting: @escaping @MainActor (
            _ callback: @escaping ButtonHeistPrivateSPI.AccessibilityNotificationCallbackBlock
        ) -> Void
    ) {
        self.init { handler in
            let callback: ButtonHeistPrivateSPI.AccessibilityNotificationCallbackBlock = { code, notificationData, associatedElement in
                AccessibilityNotificationCallbackIngress.enqueue(
                    code: code,
                    notificationData: notificationData,
                    associatedElement: associatedElement,
                    handler: handler
                )
            }
            installPrivateCallbackForTesting(callback)
            return CallbackInstallation(retainedCallback: nil)
        }
    }

    func attach(_ bus: AccessibilityNotificationBus) {
        if let destination {
            precondition(
                destination === bus,
                "Only one live Vault may own accessibility notification ingress"
            )
        }
        destination = bus
        installCallbackIfNeeded()
    }

    func detach(_ bus: AccessibilityNotificationBus) {
        guard destination === bus else { return }
        destination = nil
    }

    private func installCallbackIfNeeded() {
        guard !installationAttempted else { return }
        installationAttempted = true
        do {
            installation = try callbackInstaller { [weak self] code, notificationData, associatedElement in
                self?.publish(
                    code: code,
                    notificationData: notificationData,
                    associatedElement: associatedElement
                )
            }
        } catch {
            accessibilityNotificationLogger.info(
                "accessibility notification callback install failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func publish(
        code: UInt32,
        notificationData: AnyObject?,
        associatedElement: AnyObject?
    ) {
        guard let destination else { return }

        let timestamp = Date()
        let capturedNotificationData = CapturedAccessibilityNotificationPayload(notificationData)
        let capturedAssociatedElement = CapturedAccessibilityNotificationPayload(associatedElement)
        if let description = AccessibilityNotificationProbe.description(
            rawCode: code,
            notificationData: capturedNotificationData,
            associatedElement: capturedAssociatedElement
        ) {
            accessibilityNotificationLogger.info("\(description, privacy: .public)")
        }
        let notificationPayload = capturedNotificationData.pendingPayload
        let associatedElementPayload = capturedAssociatedElement.pendingPayload
        destination.record(
            rawCode: code,
            timestamp: timestamp,
            notificationData: notificationPayload,
            associatedElement: associatedElementPayload
        )
    }
}

/// Safe Swift wrapper around the private accessibility notification SPI.
///
/// This deliberately acknowledges the risk: these are private Apple symbols,
/// may disappear or change ABI between OS releases, and must never become a
/// correctness dependency. Button Heist treats this as DEBUG-only tripwire
/// signal. If the SPI is absent or shape assumptions fail, installation fails
/// closed and the rest of the evidence pipeline continues without notification
/// hints.
///
/// Notification-specific private API handling lives in this type:
/// - C ABI function typealiases for UIAccessibility's private callbacks
/// - UIAccessibility's private block registration
/// - accessibility unit-test-mode arming
///
/// Raw private symbol names, framework paths, `dlopen`, `dlsym`, and C function
/// casts are centralized in `ButtonHeistPrivateSPI`.
///
/// Everything outside this wrapper gets safe Swift operations:
/// `enableUnitTestModeIfAvailable()` and `installNotificationCallback(...)`.
/// Live Objective-C payloads are converted inside an `autoreleasepool` before
/// leaving the callback so strong references stay as short-lived as possible.
///
/// Guarantees:
/// - Exact symbol names only; no fuzzy search and no executable-memory writes.
/// - Main-thread registration, matching the apparent framework usage.
/// - Callback delivery is moved onto the main dispatch queue before payload
///   normalization; UIAccessibility does not promise its invocation queue.
/// - The process-global callback is installed once and retained for the
///   lifetime of the observer.
/// - Private payload objects leave this wrapper only as normalized, weakly-held
///   notification evidence.
private enum AccessibilityNotificationPrivateSPI {
    enum InstallError: Error, CustomStringConvertible {
        case callbackSymbolUnavailable(source: String)

        var description: String {
            switch self {
            case .callbackSymbolUnavailable(let source):
                return "callbackSymbolUnavailable(source=\(source))"
            }
        }
    }

    @MainActor
    final class InstalledCallback {
        private let frameworkHandle: ButtonHeistPrivateSPI.LibraryHandle
        private let retainedCallback: ButtonHeistPrivateSPI.AccessibilityNotificationCallbackBlock

        fileprivate init(
            frameworkHandle: ButtonHeistPrivateSPI.LibraryHandle,
            retainedCallback: @escaping ButtonHeistPrivateSPI.AccessibilityNotificationCallbackBlock
        ) {
            self.frameworkHandle = frameworkHandle
            self.retainedCallback = retainedCallback
        }
    }

    @discardableResult
    @MainActor
    static func enableUnitTestModeIfAvailable() -> Bool {
        guard let setUnitTestMode = ButtonHeistPrivateSPI.function(
            .accessibilitySetUnitTestMode,
            in: .libAccessibility
        ) else {
            return false
        }
        setUnitTestMode(1)
        return true
    }

    @MainActor
    static func installNotificationCallback(
        _ handler: @escaping AccessibilityNotificationCallback
    ) throws -> InstalledCallback {
        let source = ButtonHeistPrivateSPI.path(.uiAccessibility)
        guard let handle = ButtonHeistPrivateSPI.open(.uiAccessibility),
              let addCallback = ButtonHeistPrivateSPI.function(
                  .accessibilityAddNotificationCallback,
                  in: handle
              )
        else {
            throw InstallError.callbackSymbolUnavailable(source: source)
        }
        let observerKey = "com.buttonheist.accessibility-notification-observer" as NSString
        let callback: ButtonHeistPrivateSPI.AccessibilityNotificationCallbackBlock = { code, notificationData, associatedElement in
            AccessibilityNotificationCallbackIngress.enqueue(
                code: code,
                notificationData: notificationData,
                associatedElement: associatedElement,
                handler: handler
            )
        }

        addCallback(callback, observerKey)
        return InstalledCallback(
            frameworkHandle: handle,
            retainedCallback: callback
        )
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
