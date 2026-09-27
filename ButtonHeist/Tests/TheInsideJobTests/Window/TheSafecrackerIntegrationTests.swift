#if canImport(UIKit)
// Integration tests for TheSafecracker's touch injection, text input, and gesture pipeline.
// Requires the BH Demo test host for a live UIWindow and UIApplication.sendEvent pipeline.
import XCTest
import UIKit
@testable import TheInsideJob
import ThePlans
import TheScore

@MainActor
final class TheSafecrackerIntegrationTests: XCTestCase {

    private var safecracker: TheSafecracker!
    private var tripwire: TheTripwire!
    private var window: UIWindow!
    private var hostView: UIView!

    override func setUp() async throws {
        safecracker = TheSafecracker()
        tripwire = TheTripwire()
        tripwire.startPulse()
        safecracker.startKeyboardObservation()

        _ = await retireKeyboard {
            safecracker.dismissKeyboard()
        }

        let windowScene = try requireForegroundWindowScene()
        let viewController = UIViewController()
        viewController.view.backgroundColor = .white

        let window = UIWindow(windowScene: windowScene)
        window.frame = UIScreen.main.bounds
        window.windowLevel = .alert + 80
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        self.window = window
        hostView = viewController.view
    }

    override func tearDown() async throws {
        _ = await retireKeyboard {
            window?.endEditing(true)
            return safecracker.dismissKeyboard()
        }
        safecracker.stopKeyboardObservation()
        safecracker = nil
        tripwire.stopPulse()
        tripwire = nil
        hostView = nil
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    // MARK: - Touch Injection

    func testCancellingBeforeTapBeginsEmitsNoTouch() async {
        let control = makeTouchLifecycleControl()
        defer { control.removeFromSuperview() }
        let point = screenPoint(in: control, x: 0.5, y: 0.5)
        let task = Task { @MainActor in await safecracker.tap(at: point) }
        task.cancel()

        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertTrue(control.phases.isEmpty)
        XCTAssertEqual(control.actionCount, 0)
    }

    func testCancellingTapTerminatesTouchAndLeavesNextTapUsable() async {
        let control = makeTouchLifecycleControl()
        await assertCancellationThenSuccess(on: control) {
            await self.safecracker.tap(at: self.screenPoint(in: control, x: 0.5, y: 0.5))
        }
    }

    func testCancellingLongPressTerminatesTouchAndLeavesNextLongPressUsable() async {
        let control = makeTouchLifecycleControl()
        await assertCancellationThenSuccess(on: control) {
            await self.safecracker.longPress(
                at: self.screenPoint(in: control, x: 0.5, y: 0.5),
                duration: 1
            )
        }
    }

    func testCancellingSwipeTerminatesTouchAndLeavesNextSwipeUsable() async {
        let control = makeTouchLifecycleControl()
        await assertCancellationThenSuccess(on: control) {
            await self.safecracker.swipe(
                from: self.screenPoint(in: control, x: 0.8, y: 0.5),
                to: self.screenPoint(in: control, x: 0.2, y: 0.5),
                duration: 1
            )
        }
    }

    func testCancellingDragTerminatesTouchAndLeavesNextDragUsable() async {
        let control = makeTouchLifecycleControl()
        await assertCancellationThenSuccess(on: control) {
            await self.safecracker.drag(
                from: self.screenPoint(in: control, x: 0.2, y: 0.5),
                to: self.screenPoint(in: control, x: 0.8, y: 0.5),
                duration: 1
            )
        }
    }

    // MARK: - Text Input

    func testTypeTextIntoTextField() async throws {
        let textField = UITextField()
        textField.frame = CGRect(x: 50, y: 400, width: 200, height: 44)
        textField.borderStyle = .roundedRect
        textField.autocapitalizationType = .none
        textField.isAccessibilityElement = true
        textField.accessibilityLabel = "TypeTest"
        hostView.addSubview(textField)

        await activateTextInput(textField)

        let result = await safecracker.typeText("hello")
        XCTAssertEqual(result, .dispatched, "typeText should succeed when keyboard is active")
        XCTAssertEqual(textField.text, "hello")

        await teardownKeyboard(textField: textField)
    }

    func testActiveTextInputBecomesAvailableWhenTextFieldIsFocused() async throws {
        let textField = UITextField()
        textField.frame = CGRect(x: 50, y: 400, width: 200, height: 44)
        hostView.addSubview(textField)

        XCTAssertFalse(safecracker.hasActiveTextInput)

        await activateTextInput(textField)

        await teardownKeyboard(textField: textField)
    }

    // MARK: - Edit Actions

    func testResignFirstResponder() async {
        let textField = UITextField()
        textField.frame = CGRect(x: 50, y: 500, width: 200, height: 44)
        hostView.addSubview(textField)

        await activateTextInput(textField)
        XCTAssertTrue(textField.isFirstResponder)

        let result = await retireKeyboard {
            safecracker.dismissKeyboard()
        }
        XCTAssertTrue(result)
        XCTAssertFalse(textField.isFirstResponder)

        await teardownKeyboard(textField: textField)
    }

    // MARK: - Private Helpers

    private func activateTextInput(_ textField: UITextField) async {
        XCTAssertTrue(textField.becomeFirstResponder())
        XCTAssertTrue(textField.isFirstResponder)
        let didActivate = await safecracker.waitForActiveTextInput()
        XCTAssertTrue(didActivate)
    }

    private func retireKeyboard<Result>(
        perform action: () -> Result
    ) async -> Result {
        let hasActiveResponder = safecracker.hasActiveTextInput
            || KeyboardWindowTestHelpers.hasFirstResponder(in: hostView)

        let result = action()
        if hasActiveResponder, KeyboardWindowTestHelpers.hasPassthroughWindow() {
            await KeyboardWindowTestHelpers.waitForKeyboardWindowsToRetire()
        }

        XCTAssertFalse(safecracker.hasActiveTextInput)
        XCTAssertFalse(KeyboardWindowTestHelpers.hasFirstResponder(in: hostView))
        return result
    }

    private func teardownKeyboard(textField: UITextField) async {
        _ = await retireKeyboard {
            textField.resignFirstResponder()
        }
        textField.removeFromSuperview()
    }

    private func makeTouchLifecycleControl() -> TouchLifecycleControl {
        let control = TouchLifecycleControl(frame: CGRect(x: 40, y: 180, width: 300, height: 300))
        hostView.addSubview(control)
        return control
    }

    private func screenPoint(
        in control: UIControl,
        x: CGFloat,
        y: CGFloat
    ) -> CGPoint {
        control.convert(
            CGPoint(x: control.bounds.width * x, y: control.bounds.height * y),
            to: nil
        )
    }

    private func assertCancellationThenSuccess(
        on control: TouchLifecycleControl,
        operation: @escaping @MainActor () async -> Bool
    ) async {
        defer { control.removeFromSuperview() }
        let task = Task { @MainActor in await operation() }
        await control.waitForBegan()
        task.cancel()

        let cancellationResult = await task.value
        XCTAssertFalse(cancellationResult)
        XCTAssertEqual(control.phases, [.began, .cancelled])
        XCTAssertEqual(control.actionCount, 0)

        let successResult = await operation()
        XCTAssertTrue(successResult)
        XCTAssertEqual(control.phases, [.began, .cancelled, .began, .ended])
        XCTAssertEqual(control.actionCount, 1)
    }

}

@MainActor
private final class TouchLifecycleControl: UIControl {

    private(set) var phases: [UITouch.Phase] = []
    private(set) var actionCount = 0
    private var beganContinuation: CheckedContinuation<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBlue
        addTarget(self, action: #selector(recordAction), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        phases.append(.began)
        beganContinuation?.resume()
        beganContinuation = nil
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        phases.append(.ended)
        sendActions(for: .touchUpInside)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        phases.append(.cancelled)
    }

    func waitForBegan() async {
        guard !phases.isEmpty else {
            await withCheckedContinuation { continuation in
                beganContinuation = continuation
            }
            return
        }
    }

    @objc private func recordAction() {
        actionCount += 1
    }
}

#endif // canImport(UIKit)
