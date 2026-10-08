#if canImport(UIKit)
import ButtonHeistSupport
import ButtonHeistTestSupport
import XCTest
@testable import AccessibilitySnapshotParser
@_spi(ButtonHeistInternals) @testable import ThePlans
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

final class ActionActivationOverrideView: UIView {
    private(set) var activationCount = 0
    var onActivation: (@MainActor () -> Void)?

    override func accessibilityActivate() -> Bool {
        activationCount += 1
        onActivation?()
        return true
    }
}

final class RefusingActivationView: UIView {
    private(set) var activationCount = 0

    override func accessibilityActivate() -> Bool {
        activationCount += 1
        return false
    }
}

final class ActionActivatingTextField: DeterministicTextField {
    private(set) var activationCount = 0

    override func accessibilityActivate() -> Bool {
        activationCount += 1
        return becomeFirstResponder()
    }
}

final class TouchFallbackTextField: DeterministicTextField {
    private(set) var accessibilityActivationCount = 0
    var onBecomeFirstResponder: (@MainActor () -> Void)?

    override func accessibilityActivate() -> Bool {
        accessibilityActivationCount += 1
        return true
    }

    override func becomeFirstResponder() -> Bool {
        onBecomeFirstResponder?()
        return super.becomeFirstResponder()
    }
}

@MainActor
final class ActionTextInputKeyboardImpl: NSObject {
    @MainActor
    private final class TextInputDelegate: NSObject, UIKeyInput {
        private weak var textField: UITextField?
        private let onInput: @MainActor () -> Void

        init(textField: UITextField, onInput: @escaping @MainActor () -> Void) {
            self.textField = textField
            self.onInput = onInput
        }

        var hasText: Bool { textField?.text?.isEmpty == false }

        func insertText(_ text: String) {
            updateText((textField?.text ?? "") + text)
        }

        func deleteBackward() {
            var value = textField?.text ?? ""
            guard !value.isEmpty else { return }
            value.removeLast()
            updateText(value)
        }

        private func updateText(_ text: String) {
            textField?.text = text
            textField?.accessibilityValue = text
            onInput()
        }
    }

    private let inputDelegate: TextInputDelegate
    private weak var textField: UITextField?
    private let onInput: @MainActor () -> Void

    init(textField: UITextField, onInput: @escaping @MainActor () -> Void) {
        self.textField = textField
        self.onInput = onInput
        inputDelegate = TextInputDelegate(textField: textField, onInput: onInput)
    }

    @objc(delegate)
    func delegate() -> AnyObject? {
        textField?.isFirstResponder == true ? inputDelegate : nil
    }

    @objc(addInputString:withFlags:)
    func addInputString(_ text: NSString, flags: UInt) {
        inputDelegate.insertText(text as String)
    }

    @objc(deleteFromInput)
    func deleteFromInput() {
        inputDelegate.deleteBackward()
    }

    @objc(taskQueue)
    func taskQueue() -> AnyObject? {
        self
    }

    @objc(waitUntilAllTasksAreFinished)
    func waitUntilAllTasksAreFinished() {}

    func bridge() -> KeyboardBridge {
        KeyboardBridge(
            impl: self,
            textInjection: UIKeyboardImplTextInjection(impl: self)
        )
    }
}

final class CustomActionTargetObject: NSObject {
    private(set) var invocationCount = 0

    @objc func archive(_ action: UIAccessibilityCustomAction) -> Bool {
        invocationCount += 1
        return true
    }

    @objc func decline(_ action: UIAccessibilityCustomAction) -> Bool {
        invocationCount += 1
        return false
    }
}

final class ActionGeometryView: UIView {
    private let testActivationPoint: CGPoint

    init(activationPoint: CGPoint) {
        self.testActivationPoint = activationPoint
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var accessibilityActivationPoint: CGPoint {
        get { testActivationPoint }
        set {}
    }
}

final class AdjustableGeometryView: UIView {
    private let testActivationPoint: CGPoint
    private(set) var incrementCount = 0

    init(frame: CGRect, activationPoint: CGPoint) {
        self.testActivationPoint = activationPoint
        super.init(frame: frame)
        accessibilityFrame = frame
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var accessibilityActivationPoint: CGPoint {
        get { testActivationPoint }
        set {}
    }

    override func accessibilityIncrement() {
        incrementCount += 1
    }
}

@MainActor
final class HostedVisibleObservationSource {
    private let scripted: VisibleObservationSourceFixture
    private var capturesLive: Bool

    init(observation: InterfaceObservation?, capturesLive: Bool) {
        scripted = VisibleObservationSourceFixture(observation: observation)
        self.capturesLive = capturesLive
    }

    var observation: InterfaceObservation? {
        get { scripted.observation }
        set {
            capturesLive = false
            scripted.observation = newValue
        }
    }

    var captureCount: Int { scripted.captureCount }

    func capture(from vault: TheVault) -> InterfaceObservation? {
        capturesLive ? TheVault.captureVisibleObservation(from: vault) : scripted.capture(from: vault)
    }

    func useLiveCapture() {
        capturesLive = true
    }

    func failNextCapture() {
        capturesLive = false
        scripted.failNextCapture()
    }
}

@MainActor
final class TheBrainsActionTests: XCTestCase {

    var brains: TheBrains!
    var visibleObservationSource: HostedVisibleObservationSource!

    override func setUp() async throws {
        try await super.setUp()
        visibleObservationSource = HostedVisibleObservationSource(
            observation: nil,
            capturesLive: false
        )
        brains = TheBrains(
            tripwire: TheTripwire(),
            visibleObservationSource: visibleObservationSource.capture
        )
        await brains.startTestObservation()
    }

    override func tearDown() async throws {
        brains.stopTestObservation()
        brains = nil
        visibleObservationSource = nil
        try await super.tearDown()
    }

    func replaceBrains(keyboardInput: SafecrackerKeyboardInput) async {
        brains.stopTestObservation()
        brains = TheBrains(
            tripwire: TheTripwire(),
            keyboardInput: keyboardInput,
            visibleObservationSource: visibleObservationSource.capture
        )
        await brains.startTestObservation()
    }

    // MARK: - Helpers

    func actionDeadline() -> SemanticObservationDeadline {
        SemanticObservationDeadline(
            start: RuntimeElapsed.now,
            timeoutSeconds: 10
        )
    }

    func registerScreenElement(
        heistId: HeistId,
        element: AccessibilityElement,
        object: NSObject?
    ) async {
        if let object {
            object.accessibilityFrame = element.shape.frame
        }
        await installScreen(elements: [(element, heistId)], objects: [heistId: object])
    }

    func installSyntheticObservation(_ observation: InterfaceObservation) async {
        visibleObservationSource.observation = observation
        await brains.vault.installObservationForTesting(observation)
    }

    func installScreen(
        elements: [(AccessibilityElement, HeistId)],
        objects: [HeistId: NSObject?] = [:]
    ) async {
        let observation = InterfaceObservation.makeForTests(
            elements: elements.map { ($0.0, $0.1) },
            objects: objects
        )
        await installSyntheticObservation(observation)
    }

    func installScreen(
        offViewport: [InterfaceObservation.OffViewportEntry]
    ) async {
        let observation = InterfaceObservation.makeForTests(
            offViewport: offViewport
        )
        await installSyntheticObservation(observation)
    }

    func installModalWindow(rootView: UIView) throws -> UIWindow {
        visibleObservationSource.useLiveCapture()
        let windowScene = try requireForegroundWindowScene()
        let viewController = UIViewController()
        viewController.view = rootView
        viewController.view.frame = UIScreen.main.bounds
        viewController.view.accessibilityViewIsModal = true

        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 45
        window.rootViewController = viewController
        window.frame = UIScreen.main.bounds
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    func makeElement(
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        traits: UIAccessibilityTraits = .none,
        customActions: [String] = [],
        customRotors: [AccessibilityElement.CustomRotor] = []
    ) -> AccessibilityElement {
        let frame = CGRect(x: 20, y: 20, width: 120, height: 44)
        return .make(
            label: label,
            value: value,
            identifier: identifier,
            traits: traits,
            shape: .frame(AccessibilityRect(frame)),
            activationPoint: CGPoint(x: frame.midX, y: frame.midY),
            customActions: customActions.map(AccessibilityElement.CustomAction.init(name:)),
            customRotors: customRotors,
            respondsToUserInteraction: false
        )
    }

    func matcherTarget(
        label: String,
        in observation: InterfaceObservation
    ) throws -> AccessibilityTarget {
        let treeElement = try XCTUnwrap(observation.tree.orderedElements.first { $0.element.label == label })
        let elements = observation.tree.orderedElements.map {
            PredicateSelectionSubjectElement(id: $0.heistId.predicateSelectionElementId, element: $0.element)
        }
        return try XCTUnwrap(
            MinimumPredicateSelector.minimumUniquePredicate(
                for: treeElement.heistId.predicateSelectionElementId,
                in: elements
            )
        ).target
    }

    func heistStepResult(for step: HeistStep, label: String) async throws -> ActionResult {
        let result = try await brains.executeHeistPlan(try HeistPlan(body: [step])).get()
        return try XCTUnwrap(
            result.steps.first?.reportActionResult,
            "Expected heist execution step result for \(label)"
        )
    }

    func waitForSettledSemanticWaiter(
        on vault: TheVault,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = CFAbsoluteTimeGetCurrent() + 1
        while vault.semanticObservationStream.observationWaiterCount == 0,
              CFAbsoluteTimeGetCurrent() < deadline {
            await Task.yield()
            guard await Task.cancellableSleep(for: .milliseconds(5)) else { break }
        }
        XCTAssertEqual(vault.semanticObservationStream.observationWaiterCount, 1, file: file, line: line)
    }

    func withNoTraversableWindows<T>(
        _ operation: () async -> T
    ) async -> T {
        let windows = brains.tripwire.captureTraversableWindows().map(\.window)
        let originalHiddenStates = windows.map(\.isHidden)
        for window in windows {
            window.isHidden = true
        }
        defer {
            for (window, originalIsHidden) in zip(windows, originalHiddenStates) {
                window.isHidden = originalIsHidden
            }
        }
        return await operation()
    }
}

#endif
