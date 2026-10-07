#if canImport(UIKit)
#if DEBUG
import UIKit

/// Type-safe wrappers for ObjC runtime dispatch to private UIKit APIs.
///
/// Runtime selectors are modeled as typed method values. Each method carries a
/// phantom argument signature, so call sites can only invoke the method with the
/// Swift shape it was declared to accept. Raw Objective-C `id` dispatch,
/// `perform`, and IMP casting stay isolated in `RawObjCMessageBridge`.
enum ObjCRuntime {
    // MARK: - Nested Types

    enum NoArguments {}
    enum IntArgument {}
    enum BoolArgument {}
    enum DoubleArgument {}
    enum PointerArgument {}
    enum PointBoolArguments {}

    struct ObjectArgument<Argument: NSObject> {}
    struct ObjectBoolArguments<Argument: NSObject> {}
    struct ObjectUIntArguments<Argument: NSObject> {}
    struct ObjectReturningBoolArgument<Argument: NSObject> {}
    struct PointRadiusArguments<Result: NSObject> {}

    enum SwizzleInstallationError: Error, Equatable, CustomStringConvertible {
        case classUnavailable(ClassName)
        case methodUnavailable(className: ClassName, method: String)
        case methodIsInherited(className: ClassName, method: String)
        case incompatibleSignature(className: ClassName, method: String)

        var description: String {
            switch self {
            case .classUnavailable(let className):
                return "Objective-C class is unavailable: \(className)"
            case .methodUnavailable(let className, let method):
                return "Objective-C method is unavailable: \(className).\(method)"
            case .methodIsInherited(let className, let method):
                return "Objective-C method must be declared directly on the swizzled class: \(className).\(method)"
            case .incompatibleSignature(let className, let method):
                return "Objective-C method has an incompatible signature: \(className).\(method)"
            }
        }
    }

    enum SwizzleRestoration: Equatable {
        case restored
        case superseded
        case alreadyRestored
    }

    private enum InstanceMethodSwizzlePhase {
        case installed(RawObjCMethodSwizzle)
        case restored
    }

    @MainActor
    struct ObjectArgumentInvocation<Argument: NSObject> {
        let argument: Argument
        private let original: @MainActor () -> Void

        fileprivate init(argument: Argument, original: @escaping @MainActor () -> Void) {
            self.argument = argument
            self.original = original
        }

        func callOriginal() {
            original()
        }
    }

    @MainActor
    struct ObjectBoolArgumentsInvocation<Argument: NSObject> {
        let argument: Argument
        let flag: Bool
        private let original: @MainActor () -> Void

        fileprivate init(argument: Argument, flag: Bool, original: @escaping @MainActor () -> Void) {
            self.argument = argument
            self.flag = flag
            self.original = original
        }

        func callOriginal() {
            original()
        }
    }

    @MainActor
    final class InstanceMethodSwizzle {
        private var phase: InstanceMethodSwizzlePhase

        fileprivate init(_ swizzle: RawObjCMethodSwizzle) {
            phase = .installed(swizzle)
        }

        func restore() -> SwizzleRestoration {
            guard case .installed(let swizzle) = phase else {
                return .alreadyRestored
            }
            let restoration = swizzle.restore()
            phase = .restored
            return restoration
        }
    }

    struct ClassName: Equatable, CustomStringConvertible {
        let rawValue: String

        init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        var description: String { rawValue }
    }

    struct ObjectMethod<Arguments>: CustomStringConvertible {
        let rawValue: String
        fileprivate let selector: Selector

        init(_ rawValue: String) {
            self.rawValue = rawValue
            selector = NSSelectorFromString(rawValue)
        }

        fileprivate init(_ selector: Selector) {
            self.rawValue = NSStringFromSelector(selector)
            self.selector = selector
        }

        var description: String { rawValue }
    }

    struct ClassMethod<Arguments>: CustomStringConvertible {
        let rawValue: String
        fileprivate let selector: Selector

        fileprivate init(_ rawValue: String) {
            self.rawValue = rawValue
            selector = NSSelectorFromString(rawValue)
        }

        var description: String { rawValue }
    }

    struct ObjectGetter<Value>: CustomStringConvertible {
        let rawValue: String
        fileprivate let selector: Selector

        fileprivate init(_ rawValue: String) {
            self.rawValue = rawValue
            selector = NSSelectorFromString(rawValue)
        }

        var description: String { rawValue }
    }

    struct ClassGetter<Value>: CustomStringConvertible {
        let rawValue: String
        fileprivate let selector: Selector

        fileprivate init(_ rawValue: String) {
            self.rawValue = rawValue
            selector = NSSelectorFromString(rawValue)
        }

        var description: String { rawValue }
    }

    /// A verified object + typed selector pair. Created by `message(_:to:)`.
    struct Message<Target: NSObject, Arguments> {
        let target: Target
        let method: ObjectMethod<Arguments>
        private let bridge: RawObjCMessageBridge

        fileprivate init?(target: Target, method: ObjectMethod<Arguments>) {
            guard let bridge = RawObjCMessageBridge(target: target, selector: method.selector) else {
                return nil
            }
            self.target = target
            self.method = method
            self.bridge = bridge
        }
    }

    /// A verified object + typed getter pair. Created by `resolve(_:from:)`.
    struct ResolvedObjectGetter<Target: NSObject, Value> {
        let target: Target
        let getter: ObjectGetter<Value>
        private let bridge: RawObjCMessageBridge

        fileprivate init?(target: Target, getter: ObjectGetter<Value>) {
            guard let bridge = RawObjCMessageBridge(target: target, selector: getter.selector) else {
                return nil
            }
            self.target = target
            self.getter = getter
            self.bridge = bridge
        }
    }

    /// A verified class object + typed getter pair. Created by
    /// `resolve(_:on:)`.
    struct ResolvedClassGetter<Value> {
        let getter: ClassGetter<Value>
        private let bridge: RawObjCMessageBridge

        fileprivate init?(targetClass: AnyClass, getter: ClassGetter<Value>) {
            guard let bridge = RawObjCMessageBridge(targetClass: targetClass, selector: getter.selector) else {
                return nil
            }
            self.getter = getter
            self.bridge = bridge
        }
    }

    /// A verified class object + typed selector pair. Created by
    /// `classMessage(_:on:)`.
    struct ClassMessage<Arguments> {
        let method: ClassMethod<Arguments>
        private let bridge: RawObjCMessageBridge

        fileprivate init?(targetClass: AnyClass, method: ClassMethod<Arguments>) {
            guard let bridge = RawObjCMessageBridge(targetClass: targetClass, selector: method.selector) else {
                return nil
            }
            self.method = method
            self.bridge = bridge
        }
    }

    // MARK: - Message Resolution

    static func message<Target: NSObject, Arguments>(
        _ method: ObjectMethod<Arguments>,
        to target: Target
    ) -> Message<Target, Arguments>? {
        Message(target: target, method: method)
    }

    static func resolve<Target: NSObject, Value>(
        _ getter: ObjectGetter<Value>,
        from target: Target
    ) -> ResolvedObjectGetter<Target, Value>? {
        ResolvedObjectGetter(target: target, getter: getter)
    }

    static func get<Target: NSObject, Value: NSObject>(
        _ getter: ObjectGetter<Value>,
        from target: Target
    ) -> Value? {
        resolve(getter, from: target)?.get()
    }

    static func classMessage<Arguments>(
        _ method: ClassMethod<Arguments>,
        on className: ClassName
    ) -> ClassMessage<Arguments>? {
        guard let cls = NSClassFromString(className.rawValue) else { return nil }
        return ClassMessage(targetClass: cls, method: method)
    }

    static func resolve<Value>(
        _ getter: ClassGetter<Value>,
        on className: ClassName
    ) -> ResolvedClassGetter<Value>? {
        guard let cls = NSClassFromString(className.rawValue) else { return nil }
        return ResolvedClassGetter(targetClass: cls, getter: getter)
    }

    static func get<Value: NSObject>(
        _ getter: ClassGetter<Value>,
        on className: ClassName
    ) -> Value? {
        resolve(getter, on: className)?.get()
    }

    @MainActor
    static func swizzle<Argument: NSObject>(
        _ method: ObjectMethod<ObjectArgument<Argument>>,
        on className: ClassName,
        with replacement: @escaping @MainActor (ObjectArgumentInvocation<Argument>) -> Void
    ) throws -> InstanceMethodSwizzle {
        let swizzle = try RawObjCMethodSwizzle.installObjectArgument(
            method: method,
            on: className,
            replacement: replacement
        )
        return InstanceMethodSwizzle(swizzle)
    }

    @MainActor
    static func swizzle<Argument: NSObject>(
        _ method: ObjectMethod<ObjectBoolArguments<Argument>>,
        on className: ClassName,
        with replacement: @escaping @MainActor (ObjectBoolArgumentsInvocation<Argument>) -> Void
    ) throws -> InstanceMethodSwizzle {
        let swizzle = try RawObjCMethodSwizzle.installObjectBoolArguments(
            method: method,
            on: className,
            replacement: replacement
        )
        return InstanceMethodSwizzle(swizzle)
    }
}

// MARK: - Typed Method Catalog

extension ObjCRuntime.ClassName {
    static let uiKeyboardImpl = ObjCRuntime.ClassName("UIKeyboardImpl")
    static let uiHitTestContext = ObjCRuntime.ClassName("_UIHitTestContext")
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.ObjectArgument<NSObject> {
    static let animationDidStart = ObjCRuntime.ObjectMethod<Arguments>("animationDidStart:")
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.ObjectBoolArguments<NSObject> {
    static let animationDidStop = ObjCRuntime.ObjectMethod<Arguments>("animationDidStop:finished:")
}

extension ObjCRuntime.ClassGetter where Value == NSObject {
    static let sharedInstance = ObjCRuntime.ClassGetter<Value>("sharedInstance")
}

extension ObjCRuntime.ClassMethod where Arguments == ObjCRuntime.PointRadiusArguments<NSObject> {
    static let contextWithPointRadius = ObjCRuntime.ClassMethod<Arguments>("contextWithPoint:radius:")
}

extension ObjCRuntime.ObjectGetter where Value == UIEvent {
    static let applicationTouchesEvent = ObjCRuntime.ObjectGetter<Value>("_touchesEvent")
}

extension ObjCRuntime.ObjectGetter where Value == NSObject {
    static let keyboardDelegate = ObjCRuntime.ObjectGetter<Value>("delegate")
    static let keyboardTaskQueue = ObjCRuntime.ObjectGetter<Value>("taskQueue")
    static let accessibilityContainer = ObjCRuntime.ObjectGetter<Value>("accessibilityContainer")
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.NoArguments {
    static let keyboardWaitUntilAllTasksAreFinished = ObjCRuntime.ObjectMethod<Arguments>(
        "waitUntilAllTasksAreFinished"
    )
    static let keyboardDeleteFromInput = ObjCRuntime.ObjectMethod<Arguments>("deleteFromInput")
    static let eventClearTouches = ObjCRuntime.ObjectMethod<Arguments>("_clearTouches")
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.ObjectUIntArguments<NSString> {
    static let keyboardAddLiteralInputString = ObjCRuntime.ObjectMethod<Arguments>(
        "addInputString:withFlags:"
    )
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.ObjectArgument<UIWindow> {
    static let touchSetWindow = ObjCRuntime.ObjectMethod<Arguments>("setWindow:")
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.ObjectArgument<UIResponder> {
    static let touchSetView = ObjCRuntime.ObjectMethod<Arguments>("setView:")
    static let touchSetGestureView = ObjCRuntime.ObjectMethod<Arguments>("setGestureView:")
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.ObjectArgument<NSObject> {
    static let viewHitTestWithContext = ObjCRuntime.ObjectMethod<Arguments>("_hitTestWithContext:")
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.IntArgument {
    static let touchSetPhase = ObjCRuntime.ObjectMethod<Arguments>("setPhase:")
    static let touchSetTapCount = ObjCRuntime.ObjectMethod<Arguments>("setTapCount:")
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.BoolArgument {
    static let touchSetIsFirstTouchForView = ObjCRuntime.ObjectMethod<Arguments>("_setIsFirstTouchForView:")
    static let touchSetIsTap = ObjCRuntime.ObjectMethod<Arguments>("setIsTap:")
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.DoubleArgument {
    static let touchSetTimestamp = ObjCRuntime.ObjectMethod<Arguments>("setTimestamp:")
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.PointerArgument {
    static let eventSetHIDEvent = ObjCRuntime.ObjectMethod<Arguments>("_setHIDEvent:")
    static let touchSetHIDEvent = ObjCRuntime.ObjectMethod<Arguments>("_setHidEvent:")
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.PointBoolArguments {
    static let touchSetLocationInWindow = ObjCRuntime.ObjectMethod<Arguments>(
        "_setLocationInWindow:resetPrevious:"
    )
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.ObjectBoolArguments<UITouch> {
    static let eventAddTouchForDelayedDelivery = ObjCRuntime.ObjectMethod<Arguments>(
        "_addTouch:forDelayedDelivery:"
    )
}

extension ObjCRuntime.ObjectMethod where Arguments == ObjCRuntime.ObjectReturningBoolArgument<UIAccessibilityCustomAction> {
    static func accessibilityCustomAction(_ selector: Selector) -> Self {
        Self(selector)
    }
}

// MARK: - Typed Object Calls

extension ObjCRuntime.Message where Arguments == ObjCRuntime.NoArguments {
    func call() {
        bridge.sendVoid()
    }
}

extension ObjCRuntime.Message {
    func send<Argument: NSObject>(_ argument: Argument) where Arguments == ObjCRuntime.ObjectArgument<Argument> {
        bridge.sendVoid(argument)
    }

    func call<Argument: NSObject, Result: NSObject>(_ argument: Argument) -> Result?
        where Arguments == ObjCRuntime.ObjectArgument<Argument> {
        bridge.sendObject(argument)
    }

    func send<Argument: NSObject>(_ argument: Argument, _ flag: Bool)
        where Arguments == ObjCRuntime.ObjectBoolArguments<Argument> {
        bridge.sendVoid(argument, flag)
    }

    func send<Argument: NSObject>(_ argument: Argument, flags: UInt)
        where Arguments == ObjCRuntime.ObjectUIntArguments<Argument> {
        bridge.sendVoid(argument, flags)
    }

    func call<Argument: NSObject>(_ argument: Argument) -> Bool
        where Arguments == ObjCRuntime.ObjectReturningBoolArgument<Argument> {
        bridge.sendBool(argument)
    }
}

extension ObjCRuntime.Message where Arguments == ObjCRuntime.IntArgument {
    func call(_ value: Int) {
        bridge.sendVoid(value)
    }
}

extension ObjCRuntime.Message where Arguments == ObjCRuntime.BoolArgument {
    func call(_ value: Bool) {
        bridge.sendVoid(value)
    }
}

extension ObjCRuntime.Message where Arguments == ObjCRuntime.DoubleArgument {
    func call(_ value: Double) {
        bridge.sendVoid(value)
    }
}

extension ObjCRuntime.Message where Arguments == ObjCRuntime.PointerArgument {
    func call(_ pointer: UnsafeMutableRawPointer) {
        bridge.sendVoid(pointer)
    }
}

extension ObjCRuntime.Message where Arguments == ObjCRuntime.PointBoolArguments {
    func call(_ point: CGPoint, resetPrevious: Bool) {
        bridge.sendVoid(point, resetPrevious)
    }
}

// MARK: - Typed Getter Reads

extension ObjCRuntime.ResolvedObjectGetter where Value: NSObject {
    func get() -> Value? {
        bridge.sendObject()
    }
}

extension ObjCRuntime.ResolvedClassGetter where Value: NSObject {
    func get() -> Value? {
        bridge.sendObject()
    }
}

extension ObjCRuntime.ResolvedObjectGetter where Value == Int {
    func get() -> Int {
        bridge.sendInt()
    }
}

extension ObjCRuntime.ResolvedClassGetter where Value == Int {
    func get() -> Int {
        bridge.sendInt()
    }
}

// MARK: - Typed Class Calls

extension ObjCRuntime.ClassMessage {
    func call<Result: NSObject>(_ point: CGPoint, radius: CGFloat) -> Result?
        where Arguments == ObjCRuntime.PointRadiusArguments<Result> {
        bridge.sendObject(point, radius: radius)
    }
}

/// Owns one reversible instance-method replacement. All raw runtime types,
/// type-encoding checks, IMP casts, and block bridging stay behind this
/// boundary; callers only see phantom-typed Objective-C methods.
private final class RawObjCMethodSwizzle {
    private typealias RawReceiver = AnyObject
    private typealias ObjectArgumentIMP = @convention(c) (
        RawReceiver,
        Selector,
        RawReceiver
    ) -> Void
    private typealias ObjectBoolArgumentsIMP = @convention(c) (
        RawReceiver,
        Selector,
        RawReceiver,
        Bool
    ) -> Void
    private typealias ObjectArgumentBlock = @convention(block) (
        RawReceiver,
        RawReceiver
    ) -> Void
    private typealias ObjectBoolArgumentsBlock = @convention(block) (
        RawReceiver,
        RawReceiver,
        Bool
    ) -> Void

    private enum Signature {
        case objectArgument
        case objectBoolArguments

        var argumentCount: UInt32 {
            switch self {
            case .objectArgument: 3
            case .objectBoolArguments: 4
            }
        }
    }

    private let targetClass: AnyClass
    private let selector: Selector
    private let original: IMP
    private let replacement: IMP

    private init(
        targetClass: AnyClass,
        selector: Selector,
        original: IMP,
        replacement: IMP
    ) {
        self.targetClass = targetClass
        self.selector = selector
        self.original = original
        self.replacement = replacement
    }

    @MainActor
    static func installObjectArgument<Argument: NSObject>(
        method: ObjCRuntime.ObjectMethod<ObjCRuntime.ObjectArgument<Argument>>,
        on className: ObjCRuntime.ClassName,
        replacement typedReplacement: @escaping @MainActor (
            ObjCRuntime.ObjectArgumentInvocation<Argument>
        ) -> Void
    ) throws -> RawObjCMethodSwizzle {
        let resolved = try resolve(method: method, on: className, signature: .objectArgument)
        let original = unsafeBitCast(resolved.implementation, to: ObjectArgumentIMP.self)
        let block: ObjectArgumentBlock = { receiver, argument in
            guard let argument = argument as? Argument else {
                original(receiver, resolved.selector, argument)
                return
            }
            MainActor.assumeIsolated {
                typedReplacement(ObjCRuntime.ObjectArgumentInvocation(
                    argument: argument,
                    original: { original(receiver, resolved.selector, argument) }
                ))
            }
        }
        return install(resolved: resolved, block: block)
    }

    @MainActor
    static func installObjectBoolArguments<Argument: NSObject>(
        method: ObjCRuntime.ObjectMethod<ObjCRuntime.ObjectBoolArguments<Argument>>,
        on className: ObjCRuntime.ClassName,
        replacement typedReplacement: @escaping @MainActor (
            ObjCRuntime.ObjectBoolArgumentsInvocation<Argument>
        ) -> Void
    ) throws -> RawObjCMethodSwizzle {
        let resolved = try resolve(method: method, on: className, signature: .objectBoolArguments)
        let original = unsafeBitCast(resolved.implementation, to: ObjectBoolArgumentsIMP.self)
        let block: ObjectBoolArgumentsBlock = { receiver, argument, flag in
            guard let argument = argument as? Argument else {
                original(receiver, resolved.selector, argument, flag)
                return
            }
            MainActor.assumeIsolated {
                typedReplacement(ObjCRuntime.ObjectBoolArgumentsInvocation(
                    argument: argument,
                    flag: flag,
                    original: { original(receiver, resolved.selector, argument, flag) }
                ))
            }
        }
        return install(resolved: resolved, block: block)
    }

    func restore() -> ObjCRuntime.SwizzleRestoration {
        guard
            let method = class_getInstanceMethod(targetClass, selector),
            Self.sameIMP(method_getImplementation(method), replacement)
        else {
            // A later swizzler may retain this IMP as its original. Removing
            // the block would invalidate that chain, so a superseded token
            // deliberately leaves it alive and does not clobber the method.
            return .superseded
        }
        method_setImplementation(method, original)
        imp_removeBlock(replacement)
        return .restored
    }

    private struct ResolvedMethod {
        let targetClass: AnyClass
        let selector: Selector
        let method: Method
        let implementation: IMP
    }

    private static func resolve<Arguments>(
        method: ObjCRuntime.ObjectMethod<Arguments>,
        on className: ObjCRuntime.ClassName,
        signature: Signature
    ) throws -> ResolvedMethod {
        guard let targetClass = NSClassFromString(className.rawValue) else {
            throw ObjCRuntime.SwizzleInstallationError.classUnavailable(className)
        }
        guard let resolvedMethod = class_getInstanceMethod(targetClass, method.selector) else {
            throw ObjCRuntime.SwizzleInstallationError.methodUnavailable(
                className: className,
                method: method.rawValue
            )
        }
        guard declares(method.selector, on: targetClass) else {
            throw ObjCRuntime.SwizzleInstallationError.methodIsInherited(
                className: className,
                method: method.rawValue
            )
        }
        guard has(signature, method: resolvedMethod) else {
            throw ObjCRuntime.SwizzleInstallationError.incompatibleSignature(
                className: className,
                method: method.rawValue
            )
        }
        return ResolvedMethod(
            targetClass: targetClass,
            selector: method.selector,
            method: resolvedMethod,
            implementation: method_getImplementation(resolvedMethod)
        )
    }

    private static func install<Block>(
        resolved: ResolvedMethod,
        block: Block
    ) -> RawObjCMethodSwizzle {
        let replacement = imp_implementationWithBlock(block)
        method_setImplementation(resolved.method, replacement)
        return RawObjCMethodSwizzle(
            targetClass: resolved.targetClass,
            selector: resolved.selector,
            original: resolved.implementation,
            replacement: replacement
        )
    }

    private static func declares(_ selector: Selector, on targetClass: AnyClass) -> Bool {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(targetClass, &count) else { return false }
        defer { free(methods) }
        return (0..<Int(count)).contains { method_getName(methods[$0]) == selector }
    }

    private static func has(_ signature: Signature, method: Method) -> Bool {
        guard
            method_getNumberOfArguments(method) == signature.argumentCount,
            typeEncoding(ofReturnValueFor: method) == "v",
            typeEncoding(ofArgument: 0, for: method) == "@",
            typeEncoding(ofArgument: 1, for: method) == ":",
            typeEncoding(ofArgument: 2, for: method)?.hasPrefix("@") == true
        else {
            return false
        }
        switch signature {
        case .objectArgument:
            return true
        case .objectBoolArguments:
            let boolEncoding = typeEncoding(ofArgument: 3, for: method)
            return boolEncoding == "B" || boolEncoding == "c"
        }
    }

    private static func typeEncoding(ofReturnValueFor method: Method) -> String? {
        var buffer = [CChar](repeating: 0, count: 32)
        method_getReturnType(method, &buffer, buffer.count)
        return decodeTypeEncoding(buffer)
    }

    private static func typeEncoding(ofArgument index: UInt32, for method: Method) -> String? {
        var buffer = [CChar](repeating: 0, count: 32)
        method_getArgumentType(method, index, &buffer, buffer.count)
        return decodeTypeEncoding(buffer)
    }

    private static func decodeTypeEncoding(_ buffer: [CChar]) -> String? {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func sameIMP(_ lhs: IMP, _ rhs: IMP) -> Bool {
        unsafeBitCast(lhs, to: UnsafeRawPointer.self) == unsafeBitCast(rhs, to: UnsafeRawPointer.self)
    }
}

/// The only raw Objective-C bridge primitive in this file.
///
/// It owns raw Objective-C receiver dispatch, `perform`, and IMP casting so
/// the rest of the runtime bridge can expose NSObject-backed Swift APIs.
private struct RawObjCMessageBridge {

    private typealias RawObjectiveCReceiver = AnyObject

    private typealias IMPInt = @convention(c) (RawObjectiveCReceiver, Selector, Int) -> Void
    private typealias IMPIntReturn = @convention(c) (RawObjectiveCReceiver, Selector) -> Int
    private typealias IMPBool = @convention(c) (RawObjectiveCReceiver, Selector, Bool) -> Void
    private typealias IMPDouble = @convention(c) (RawObjectiveCReceiver, Selector, Double) -> Void
    private typealias IMPPointer = @convention(c) (RawObjectiveCReceiver, Selector, UnsafeMutableRawPointer) -> Void
    private typealias IMPPointBool = @convention(c) (RawObjectiveCReceiver, Selector, CGPoint, Bool) -> Void
    private typealias IMPObjectBoolVoid = @convention(c) (
        RawObjectiveCReceiver,
        Selector,
        RawObjectiveCReceiver,
        Bool
    ) -> Void
    private typealias IMPObjectUIntVoid = @convention(c) (
        RawObjectiveCReceiver,
        Selector,
        RawObjectiveCReceiver,
        UInt
    ) -> Void
    private typealias IMPObjectBool = @convention(c) (
        RawObjectiveCReceiver,
        Selector,
        RawObjectiveCReceiver
    ) -> Bool
    private typealias IMPPointRadiusObject = @convention(c) (
        RawObjectiveCReceiver,
        Selector,
        CGPoint,
        CGFloat
    ) -> RawObjectiveCReceiver?

    private let target: RawObjectiveCReceiver
    private let selector: Selector

    init?<Target: NSObject>(target: Target, selector: Selector) {
        let receiver = target as RawObjectiveCReceiver
        guard receiver.responds(to: selector) else { return nil }
        self.target = receiver
        self.selector = selector
    }

    init?(targetClass: AnyClass, selector: Selector) {
        let receiver = targetClass as RawObjectiveCReceiver
        guard receiver.responds(to: selector) else { return nil }
        self.target = receiver
        self.selector = selector
    }

    func sendVoid() {
        _ = target.perform(selector)
    }

    func sendVoid<Argument: NSObject>(_ argument: Argument) {
        _ = target.perform(selector, with: argument)
    }

    func sendVoid(_ value: Int) {
        imp(as: IMPInt.self)(target, selector, value)
    }

    func sendInt() -> Int {
        imp(as: IMPIntReturn.self)(target, selector)
    }

    func sendVoid(_ value: Bool) {
        imp(as: IMPBool.self)(target, selector, value)
    }

    func sendVoid(_ value: Double) {
        imp(as: IMPDouble.self)(target, selector, value)
    }

    func sendVoid(_ pointer: UnsafeMutableRawPointer) {
        imp(as: IMPPointer.self)(target, selector, pointer)
    }

    func sendVoid(_ point: CGPoint, _ flag: Bool) {
        imp(as: IMPPointBool.self)(target, selector, point, flag)
    }

    func sendVoid<Argument: NSObject>(_ argument: Argument, _ flag: Bool) {
        imp(as: IMPObjectBoolVoid.self)(target, selector, argument, flag)
    }

    func sendVoid<Argument: NSObject>(_ argument: Argument, _ flags: UInt) {
        imp(as: IMPObjectUIntVoid.self)(target, selector, argument, flags)
    }

    func sendObject<Result: NSObject>() -> Result? {
        target.perform(selector)?.takeUnretainedValue() as? Result
    }

    func sendObject<Argument: NSObject, Result: NSObject>(_ argument: Argument) -> Result? {
        target.perform(selector, with: argument)?.takeUnretainedValue() as? Result
    }

    func sendObject<Result: NSObject>(_ point: CGPoint, radius: CGFloat) -> Result? {
        imp(as: IMPPointRadiusObject.self)(target, selector, point, radius) as? Result
    }

    func sendBool<Argument: NSObject>(_ argument: Argument) -> Bool {
        imp(as: IMPObjectBool.self)(target, selector, argument)
    }

    private func imp<Function>(as type: Function.Type) -> Function {
        unsafeBitCast(target.method(for: selector), to: Function.self)
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
