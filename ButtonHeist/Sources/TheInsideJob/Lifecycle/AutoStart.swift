#if canImport(UIKit)
#if DEBUG
import UIKit
import os

import TheScore

private let autoStartLogger = ButtonHeistLog.logger(.insideJob(.autostart))

enum XCTestEnvironmentKey: String, CaseIterable, Sendable {
    case configurationFilePath = "XCTestConfigurationFilePath"
    case sessionIdentifier = "XCTestSessionIdentifier"
}

private extension Dictionary where Key == String, Value == String {
    subscript(_ key: XCTestEnvironmentKey) -> String? {
        self[key.rawValue]
    }
}

/// Holds the auto-start Task handle. Auto-start runs exactly once per
/// process launch from `@_cdecl` (no actor instance is available at that
/// point), so the handle lives at file scope under a lock. The handle is
/// retained until the Task completes so it cannot be torn off mid-launch;
/// the value is set once, never re-read for cancellation.
private let autoStartTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

/// Called from Objective-C +load method to auto-start the server.
/// Configuration via environment variables (highest priority) or Info.plist:
/// - INSIDEJOB_DISABLE / InsideJobDisableAutoStart: Set to true to disable
/// - INSIDEJOB_TOKEN / InsideJobToken: Auth token and TLS PSK input; generated and logged if absent
/// - INSIDEJOB_ID / InsideJobInstanceId: Human-readable instance identifier
/// - INSIDEJOB_PORT / InsideJobPort: Fixed TCP port to listen on (0 or unset = any available)
/// - INSIDEJOB_SCOPE / InsideJobScope: Allowed connection scopes
/// - INSIDEJOB_SESSION_TIMEOUT / InsideJobSessionTimeout: Session release timeout
/// - INSIDEJOB_FINGERPRINTS / InsideJobFingerprintsEnabled: Visual fingerprints overlay
@_cdecl("TheInsideJob_autoStartFromLoad")
func theInsideJobAutoStartFromLoad() {
    if isRunningUnderXCTest() {
        return
    }

    let configuration = InsideJobRuntimeConfiguration.resolve()
    for warning in configuration.warnings {
        autoStartLogger.warning("\(warning.message, privacy: .public)")
    }

    if configuration.disableAutoStart.value {
        autoStartLogger.info("Auto-start disabled via \(configuration.disableAutoStart.source.label, privacy: .public)")
        return
    }

    let task = Task { @MainActor in
        armApplicationAccessibility()
        do {
            try TheInsideJob.configure(runtimeConfiguration: configuration)
            try await TheInsideJob.shared.start()
        } catch {
            autoStartLogger.error("Auto-start failed: \(error)")
        }
    }
    autoStartTask.withLock { $0 = task }
}

func isRunningUnderXCTest(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    XCTestEnvironmentKey.allCases.contains { environment[$0] != nil }
}

#endif // DEBUG
#endif // canImport(UIKit)
