#if canImport(UIKit)
import XCTest
@testable import TheInsideJob

@MainActor
final class TheSafecrackerKeyboardVisibilityTests: XCTestCase {

    private var safecracker: TheSafecracker!

    override func setUp() async throws {
        safecracker = TheSafecracker()
        safecracker.startKeyboardObservation()
    }

    override func tearDown() async throws {
        safecracker.stopKeyboardObservation()
        safecracker = nil
    }

    func testKeyboardVisibleAfterFrameNotification() {
        let screenBounds = UIScreen.main.bounds
        let keyboardFrame = CGRect(
            x: 0,
            y: screenBounds.height - 300,
            width: screenBounds.width,
            height: 300
        )

        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: keyboardFrame]
        )

        XCTAssertTrue(safecracker.isKeyboardVisible)
    }

    func testKeyboardNotVisibleWhenFrameOffScreen() {
        let screenBounds = UIScreen.main.bounds
        let offScreenFrame = CGRect(
            x: 0,
            y: screenBounds.height,
            width: screenBounds.width,
            height: 300
        )

        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: offScreenFrame]
        )

        XCTAssertFalse(safecracker.isKeyboardVisible)
    }

    func testKeyboardVisibilityDoesNotChangeAfterObservationStops() {
        let screenBounds = UIScreen.main.bounds
        let keyboardFrame = CGRect(
            x: 0,
            y: screenBounds.height - 300,
            width: screenBounds.width,
            height: 300
        )

        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: keyboardFrame]
        )
        XCTAssertTrue(safecracker.isKeyboardVisible)

        safecracker.stopKeyboardObservation()

        let hiddenFrame = CGRect(
            x: 0,
            y: screenBounds.height,
            width: screenBounds.width,
            height: 300
        )
        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: hiddenFrame]
        )
        XCTAssertTrue(safecracker.isKeyboardVisible)
    }

    func testKeyboardVisibilityTogglesWithNotifications() {
        let screenBounds = UIScreen.main.bounds
        let visibleFrame = CGRect(
            x: 0,
            y: screenBounds.height - 300,
            width: screenBounds.width,
            height: 300
        )
        let hiddenFrame = CGRect(
            x: 0,
            y: screenBounds.height,
            width: screenBounds.width,
            height: 300
        )

        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: visibleFrame]
        )
        XCTAssertTrue(safecracker.isKeyboardVisible)

        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: hiddenFrame]
        )
        XCTAssertFalse(safecracker.isKeyboardVisible)
    }
}
#endif
