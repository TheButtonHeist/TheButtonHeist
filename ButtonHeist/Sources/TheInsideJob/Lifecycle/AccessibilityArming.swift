#if canImport(UIKit)
#if DEBUG
import Foundation
import os

import TheScore

private let accessibilityArmingLogger = ButtonHeistLog.logger(.insideJob(.accessibility))

enum AccessibilityEnvironmentKey: String, Sendable {
    case iPhoneSimulatorRoot = "IPHONE_SIMULATOR_ROOT"
}

// MARK: - Accessibility Arming

/// Arms the accessibility runtime so the live accessibility tree is populated.
///
/// SwiftUI (and parts of UIKit) only build their accessibility tree when an assistive technology is
/// active. The AccessibilitySnapshot parser ships its own enabler in an ObjC `+load`, but its
/// framework is not load-time-linked into Button Heist, so the `+load` never fires. Without this,
/// `get_interface` returns zero elements on a freshly launched app until accessibility is enabled
/// out-of-band.
///
/// This toggles the accessibility arming SPI directly. The call is idempotent, so arming when an
/// external harness already enabled accessibility is harmless. DEBUG-only; called once during
/// server auto-start.
func armApplicationAccessibility(environment: [String: String] = ProcessInfo.processInfo.environment) {
    let path = libAccessibilityPath(environment: environment)
    guard let handle = ButtonHeistPrivateSPI.open(.libAccessibility, flags: RTLD_LOCAL, environment: environment) else {
        accessibilityArmingLogger.error("Could not dlopen libAccessibility at \(path, privacy: .public)")
        return
    }

    setAccessibilityFlag(handle, function: .accessibilitySetApplicationAccessibilityEnabled)
}

/// Computes the path to `libAccessibility.dylib`, prefixing the simulator root when running in a
/// simulator (where system dylibs live under `IPHONE_SIMULATOR_ROOT`).
func libAccessibilityPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    ButtonHeistPrivateSPI.path(.libAccessibility, environment: environment)
}

// MARK: - Private Helpers

private func setAccessibilityFlag(
    _ handle: ButtonHeistPrivateSPI.LibraryHandle,
    function: ButtonHeistPrivateSPI.CFunction<ButtonHeistPrivateSPI.AccessibilitySetEnabledFunction>
) {
    guard let setEnabled = ButtonHeistPrivateSPI.function(function, in: handle) else {
        accessibilityArmingLogger.debug("\(function.description, privacy: .public) not found in libAccessibility")
        return
    }
    setEnabled(1)
}

#endif // DEBUG
#endif // canImport(UIKit)
