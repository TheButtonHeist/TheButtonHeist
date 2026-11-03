#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

import ButtonHeistTestSupport
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
import TheScore

/// A live element reporting a non-finite activation point must not make the
/// whole screen unreadable. On iOS 27 a SwiftUI `Menu` is such an element.
@MainActor
final class NonFiniteActivationPointCaptureTests: XCTestCase {

    private var vault: TheVault!
    private var window: UIWindow?

    override func setUp() async throws {
        try await super.setUp()
        vault = TheVault(tripwire: TheTripwire())
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        vault = nil
        try await super.tearDown()
    }

    func testLiveElementWithNaNActivationPointIsCapturedAtItsFrameMidpoint() throws {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .white
        let element = NonFiniteActivationPointView(frame: CGRect(x: 40, y: 200, width: 160, height: 44))
        element.accessibilityLabel = "Non-finite Activation"
        viewController.view.addSubview(element)
        try present(viewController)

        let observation = try XCTUnwrap(
            vault.captureVisibleObservation(),
            "A non-finite activation point must not reject the whole capture"
        )

        let captured = try XCTUnwrap(
            observation.tree.orderedElements.first { $0.element.label == "Non-finite Activation" }
        )
        XCTAssertTrue(captured.element.activationPoint.isFinite)
        XCTAssertTrue(captured.element.usesDefaultActivationPoint)
        let frame = captured.element.bhFrame
        XCTAssertEqual(captured.element.bhResolvedActivationPoint, CGPoint(x: frame.midX, y: frame.midY))
    }

    func testSwiftUIMenuDoesNotBlockCapture() async throws {
        try present(UIHostingController(rootView: MenuFixture()))

        let menu = try await capturedElement(labelled: "Fixture Menu")

        XCTAssertTrue(menu.element.activationPoint.isFinite)
        XCTAssertNotNil(TheVault.onscreenSpace(for: menu.element).activationPointEvidence.point)
    }

    // MARK: - Private Helpers

    private func present(_ viewController: UIViewController) throws {
        let presented = UIWindow(windowScene: try requireForegroundWindowScene())
        presented.windowLevel = .alert + 30
        presented.rootViewController = viewController
        presented.frame = UIScreen.main.bounds
        presented.isHidden = false
        presented.layoutIfNeeded()
        window = presented
    }

    /// SwiftUI materialises its accessibility elements after layout, so the
    /// capture is retried while the run loop turns.
    private func capturedElement(labelled label: String) async throws -> InterfaceTree.Element {
        var found: InterfaceTree.Element?
        _ = await eventually(within: .seconds(5)) {
            found = vault.captureVisibleObservation()?.tree.orderedElements
                .first { $0.element.label == label }
            return found != nil
        }
        return try XCTUnwrap(found, "Expected a capture containing \(label)")
    }
}

private final class NonFiniteActivationPointView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override var accessibilityActivationPoint: CGPoint {
        get { CGPoint(x: CGFloat.nan, y: CGFloat.nan) }
        set { _ = newValue }
    }
}

private struct MenuFixture: View {
    var body: some View {
        VStack {
            Menu("Fixture Menu") {
                Button("Fixture Item") {}
            }
        }
    }
}

private extension HeistElement.Geometry.ScreenSpace {
    var activationPointEvidence: ActivationPointEvidence {
        guard case .onscreen(_, let activationPoint) = self else { return .unavailable }
        return activationPoint
    }
}

#endif
