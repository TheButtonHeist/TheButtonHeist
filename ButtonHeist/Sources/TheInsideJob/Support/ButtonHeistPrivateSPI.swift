#if canImport(UIKit)
#if DEBUG
import Darwin
import Foundation

/// Central inventory and dynamic-loading primitives for private Apple SPI used by TheInsideJob.
///
/// Keep private C symbols, framework install names, `dlopen`, `dlsym`, and
/// unsafe C function casts in this one static namespace. Callers still own their
/// domain-specific behavior on top of these primitives.
enum ButtonHeistPrivateSPI {

    // AccessibilitySupport boolean setter.
    typealias AccessibilitySetEnabledFunction = @convention(c) (
        Int32 // enabled
    ) -> Void

    // UIAccessibility notification observer block.
    typealias AccessibilityNotificationCallbackBlock = @convention(block) (
        UInt32, // notificationCode
        AnyObject?, // notificationData
        AnyObject? // associatedElement
    ) -> Void

    // AXAddNotificationCallback.
    typealias AddAccessibilityNotificationCallbackFunction = @convention(c) (
        AccessibilityNotificationCallbackBlock, // callbackBlock
        AnyObject // observerKey
    ) -> Void

    // IOHIDEventCreateDigitizerEvent.
    typealias IOHIDEventCreateDigitizerEventFunction = @convention(c) (
        CFAllocator?, // allocator
        UInt64, // timestamp
        UInt32, // transducerType
        UInt32, // index
        UInt32, // identity
        UInt32, // eventMask
        UInt32, // buttonMask
        Float, // x
        Float, // y
        Float, // z
        Float, // tipPressure
        Float, // barrelPressure
        Float, // twist
        Bool, // range
        Bool, // touch
        UInt32 // options
    ) -> UnsafeMutableRawPointer?

    // IOHIDEventCreateDigitizerFingerEventWithQuality.
    typealias IOHIDEventCreateDigitizerFingerEventWithQualityFunction = @convention(c) (
        CFAllocator?, // allocator
        UInt64, // timestamp
        UInt32, // index
        UInt32, // identity
        UInt32, // eventMask
        Float, // x
        Float, // y
        Float, // z
        Float, // tipPressure
        Float, // twist
        Float, // majorRadius
        Float, // minorRadius
        Float, // quality
        Float, // density
        Float, // irregularity
        Bool, // range
        Bool, // touch
        UInt32 // options
    ) -> UnsafeMutableRawPointer?

    // IOHIDEventAppendEvent.
    typealias IOHIDEventAppendEventFunction = @convention(c) (
        UnsafeMutableRawPointer, // parentEvent
        UnsafeMutableRawPointer, // childEvent
        UInt32 // options
    ) -> Void

    // IOHIDEventSetFloatValue.
    typealias IOHIDEventSetFloatValueFunction = @convention(c) (
        UnsafeMutableRawPointer, // event
        UInt32, // field
        Float // value
    ) -> Void

    enum SPISymbolName: String {
        case accessibilityAddNotificationCallback = "AXAddNotificationCallback"
        case accessibilitySetApplicationAccessibilityEnabled = "_AXSSetApplicationAccessibilityEnabled"
        case accessibilitySetUnitTestMode = "_AXSSetInUnitTestMode"
        case ioHIDEventAppendEvent = "IOHIDEventAppendEvent"
        case ioHIDEventCreateDigitizerEvent = "IOHIDEventCreateDigitizerEvent"
        case ioHIDEventCreateDigitizerFingerEventWithQuality = "IOHIDEventCreateDigitizerFingerEventWithQuality"
        case ioHIDEventSetFloatValue = "IOHIDEventSetFloatValue"
    }

    enum SPIFrameworkPath: String, CaseIterable {
        case ioKit = "/System/Library/Frameworks/IOKit.framework/IOKit"
        case libAccessibility = "/usr/lib/libAccessibility.dylib"
        case uiAccessibility = "/System/Library/PrivateFrameworks/UIAccessibility.framework/UIAccessibility"

        var usesSimulatorRoot: Bool {
            self == .libAccessibility
        }
    }

    struct LibraryHandle: CustomStringConvertible {
        let source: String
        fileprivate let rawValue: UnsafeMutableRawPointer

        fileprivate init(source: String, rawValue: UnsafeMutableRawPointer) {
            self.source = source
            self.rawValue = rawValue
        }

        var description: String { source }
    }

    struct CFunction<Signature>: CustomStringConvertible {
        let symbolName: SPISymbolName

        fileprivate init(_ symbolName: SPISymbolName) {
            self.symbolName = symbolName
        }

        var description: String { symbolName.rawValue }
    }

    static func path(
        _ frameworkPath: SPIFrameworkPath,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard frameworkPath.usesSimulatorRoot,
              let simulatorRoot = environment[AccessibilityEnvironmentKey.iPhoneSimulatorRoot.rawValue]
        else {
            return frameworkPath.rawValue
        }
        return (simulatorRoot as NSString).appendingPathComponent(frameworkPath.rawValue)
    }

    static func open(
        _ frameworkPath: SPIFrameworkPath,
        flags: Int32 = RTLD_NOW | RTLD_LOCAL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LibraryHandle? {
        openLibrary(at: path(frameworkPath, environment: environment), flags: flags)
    }

    static func openLibrary(at path: String, flags: Int32 = RTLD_NOW | RTLD_LOCAL) -> LibraryHandle? {
        guard let handle = dlopen(path, flags) else { return nil }
        return LibraryHandle(source: path, rawValue: handle)
    }

    static func function<Signature>(
        _ function: CFunction<Signature>,
        in handle: LibraryHandle
    ) -> Signature? {
        guard let symbol = symbol(function.symbolName, in: handle) else {
            return nil
        }
        return cast(symbol, to: Signature.self)
    }

    static func function<Signature>(
        _ function: CFunction<Signature>,
        in frameworkPath: SPIFrameworkPath,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> Signature? {
        guard let symbol = resolveSymbol(function.symbolName, in: frameworkPath, environment: environment) else {
            return nil
        }
        return cast(symbol, to: Signature.self)
    }

    private static func symbol(_ name: SPISymbolName, in handle: LibraryHandle) -> UnsafeMutableRawPointer? {
        dlsym(handle.rawValue, name.rawValue)
    }

    private static func resolveSymbol(
        _ name: SPISymbolName,
        in frameworkPath: SPIFrameworkPath,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UnsafeMutableRawPointer? {
        guard let handle = open(frameworkPath, environment: environment),
              let symbol = symbol(name, in: handle)
        else {
            return nil
        }
        return symbol
    }

    private static func cast<Function>(_ symbol: UnsafeMutableRawPointer, to type: Function.Type) -> Function {
        unsafeBitCast(symbol, to: type)
    }
}

extension ButtonHeistPrivateSPI.CFunction where Signature == ButtonHeistPrivateSPI.AccessibilitySetEnabledFunction {
    static let accessibilitySetApplicationAccessibilityEnabled = Self(
        .accessibilitySetApplicationAccessibilityEnabled
    )
    static let accessibilitySetUnitTestMode = Self(.accessibilitySetUnitTestMode)
}

extension ButtonHeistPrivateSPI.CFunction
where Signature == ButtonHeistPrivateSPI.AddAccessibilityNotificationCallbackFunction {
    static let accessibilityAddNotificationCallback = Self(.accessibilityAddNotificationCallback)
}

extension ButtonHeistPrivateSPI.CFunction
where Signature == ButtonHeistPrivateSPI.IOHIDEventCreateDigitizerEventFunction {
    static let ioHIDEventCreateDigitizerEvent = Self(.ioHIDEventCreateDigitizerEvent)
}

extension ButtonHeistPrivateSPI.CFunction
where Signature == ButtonHeistPrivateSPI.IOHIDEventCreateDigitizerFingerEventWithQualityFunction {
    static let ioHIDEventCreateDigitizerFingerEventWithQuality = Self(
        .ioHIDEventCreateDigitizerFingerEventWithQuality
    )
}

extension ButtonHeistPrivateSPI.CFunction
where Signature == ButtonHeistPrivateSPI.IOHIDEventAppendEventFunction {
    static let ioHIDEventAppendEvent = Self(.ioHIDEventAppendEvent)
}

extension ButtonHeistPrivateSPI.CFunction
where Signature == ButtonHeistPrivateSPI.IOHIDEventSetFloatValueFunction {
    static let ioHIDEventSetFloatValue = Self(.ioHIDEventSetFloatValue)
}

#endif // DEBUG
#endif // canImport(UIKit)
