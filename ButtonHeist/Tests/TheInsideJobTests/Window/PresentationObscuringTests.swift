#if canImport(UIKit)
import XCTest
@testable import TheInsideJob

@MainActor
final class PresentationObscuringTests: XCTestCase {

    // MARK: - UIView.nearestViewController

    func testNearestViewControllerReturnsNilForOrphanView() {
        let orphan = UIView()
        XCTAssertNil(orphan.nearestViewController)
    }

    func testNearestViewControllerFindsNestedViewOwner() {
        let viewController = UIViewController()
        _ = viewController.view
        let wrapper = UIView()
        let nested = UIView()
        wrapper.addSubview(nested)
        viewController.view.addSubview(wrapper)

        XCTAssertIdentical(nested.nearestViewController, viewController)
    }

    // MARK: - UIViewController.isDescendant(of:)

    func testIsDescendantOfSelf() {
        let viewController = UIViewController()
        XCTAssertTrue(viewController.isDescendant(of: viewController))
    }

    func testIsNotDescendantOfUnrelatedVC() {
        let viewControllerA = UIViewController()
        let viewControllerB = UIViewController()

        XCTAssertFalse(viewControllerA.isDescendant(of: viewControllerB))
    }

    func testIsDescendantThroughNavigationController() {
        let root = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)

        XCTAssertTrue(root.isDescendant(of: navigationController))
    }

    func testIsDescendantThroughTabBarController() {
        let child = UIViewController()
        let tabBarController = UITabBarController()
        tabBarController.viewControllers = [child]

        XCTAssertTrue(child.isDescendant(of: tabBarController))
    }

    func testIsDescendantDeeplyNested() {
        let grandparent = UIViewController()
        let parent = UIViewController()
        let child = UIViewController()
        grandparent.addChild(parent)
        parent.addChild(child)

        XCTAssertTrue(child.isDescendant(of: grandparent))
        XCTAssertTrue(child.isDescendant(of: parent))
        XCTAssertFalse(grandparent.isDescendant(of: child))
    }

    // MARK: - isObscuredByPresentation

    func testViewWithNoWindowIsNotObscured() {
        let view = UIView()
        XCTAssertFalse(Navigation.isObscuredByPresentation(view: view))
    }

    func testViewInWindowWithNoPresentationIsNotObscured() {
        let window = UIWindow()
        let rootVC = UIViewController()
        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        _ = rootVC.view

        let testView = UIView()
        rootVC.view.addSubview(testView)

        XCTAssertFalse(Navigation.isObscuredByPresentation(view: testView))

        window.isHidden = true
    }

    func testViewBehindPresentedControllerIsObscured() {
        let window = UIWindow()
        let rootVC = StubViewController()
        let presented = UIViewController()
        rootVC.fakePresented = presented
        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        _ = rootVC.view

        let testView = UIView()
        rootVC.view.addSubview(testView)

        XCTAssertTrue(Navigation.isObscuredByPresentation(view: testView))

        window.isHidden = true
    }

    private final class StubViewController: UIViewController {
        var fakePresented: UIViewController?
        override var presentedViewController: UIViewController? { fakePresented }
    }
}

#endif
