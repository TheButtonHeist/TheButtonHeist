#if canImport(UIKit)
import UIKit
import XCTest

@testable import TheInsideJob

/// The app every test starts from.
///
/// A test that reads the accessibility tree reads the whole app, so what the
/// first reading finds is whatever the test before it left on screen. That
/// makes a test's starting state something it inherits rather than something it
/// states, and a test which happens to run after one that opened a window
/// passes for a reason it does not name.
///
/// Here the starting state is a fact: one traversable window, keyed and visible
/// before `beforeEach` runs. Everything a test presents closes again when the
/// test ends, so the next test inherits nothing.
///
/// A test never names a `UIWindow`. It hands over a view controller and gets
/// back the fact that it is on screen; which window that took, at what level,
/// keyed or not, is the app's business and stays here. The two moments a test
/// does get to speak for itself are `beforeEach` and `afterEach`, and both are
/// called at the one point in the sequence where they are safe.
@MainActor
class ButtonHeistTestCase: XCTestCase {

    private var scene: UIWindowScene!
    private var presentedWindows: [UIWindow] = []
    private var nextOverlayLevel = UIWindow.Level.alert.rawValue + 80

    final override func setUp() async throws {
        try await super.setUp()
        scene = try requireForegroundWindowScene()
        present(UIViewController())
        try await beforeEach()
        try await startObserving()
    }

    final override func tearDown() async throws {
        try await stopObserving()
        try await afterEach()
        for window in presentedWindows.reversed() {
            dismiss(window)
        }
        presentedWindows.removeAll()
        scene = nil
        try await super.tearDown()
    }

    /// Installs whatever this test needs on screen.
    ///
    /// The app exists and nothing is observing it yet, which is the only moment
    /// a fixture can appear without the appearance itself being a change some
    /// detector reports.
    func beforeEach() async throws {}

    /// Releases whatever this test built that the app does not own.
    ///
    /// Observation has already stopped, so anything torn down here is torn down
    /// unwatched, the same way it was built.
    func afterEach() async throws {}

    /// Starts the detectors this test reads through.
    ///
    /// Overridden by `ButtonHeistRuntimeTestCase`; the sequence lives here so
    /// there is one place that says fixtures come before observation.
    func startObserving() async throws {}

    /// Stops the detectors this test reads through.
    func stopObserving() async throws {}

    /// Puts a view controller on screen and asserts the tree can be read from it.
    ///
    /// `above` is for a fixture that has to sit over the app rather than be the
    /// app — a modal, an overlay, anything whose point is that it obscures. Each
    /// one sits above the one presented before it. The window it lands in closes
    /// when the test ends.
    ///
    /// Key belongs to the app. `isKeyWindow` feeds `WindowStackSignal` and so
    /// reaches the tripwire, which makes handing key to a fixture a change in
    /// the signal a test presenting that fixture is usually there to measure.
    func present(
        _ viewController: UIViewController,
        above: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.rootViewController = viewController
        if above {
            window.windowLevel = UIWindow.Level(nextOverlayLevel)
            nextOverlayLevel += 10
            window.isHidden = false
        } else {
            window.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        presentedWindows.append(window)
        assertAppIsTraversable("presenting \(type(of: viewController))", file: file, line: line)
    }

    /// Asserts the app has at least one window the tree can be read from.
    ///
    /// "No traversable app windows" is the failure every other assertion in a
    /// test turns into once the app has none, so it is worth stating where it
    /// happened rather than reading it off whichever assertion ran first.
    func assertAppIsTraversable(
        _ moment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            TheTripwire.orderedVisibleWindows().isEmpty,
            "Expected a traversable app window at \(moment)",
            file: file,
            line: line
        )
    }

    private func dismiss(_ window: UIWindow) {
        window.rootViewController?.view.accessibilityViewIsModal = false
        window.rootViewController = nil
        window.isHidden = true
    }
}

/// A test that reads the app through the runtime.
///
/// One app has one change detector, so a test gets one and everything it builds
/// shares it. Two pulsing at once is two display links reading the same windows,
/// which is a state the product cannot be in and a test has no reason to model —
/// so the tripwire is not something a test can name, only something it is given.
///
/// The runtime starts after `beforeEach` and stops before `afterEach`, which is
/// what makes the window stack the tripwire reads at its first pulse the same
/// stack it reads at its last.
@MainActor
class ButtonHeistRuntimeTestCase: ButtonHeistTestCase {

    /// The runtime this test reads through, already observing.
    private(set) var brains: TheBrains!

    private var tripwire: TheTripwire!

    /// Builds the runtime for this test.
    ///
    /// Override to name a different observation source or policy. The tripwire
    /// is handed in because there is exactly one, and it is already the one
    /// every other part of this test will read through.
    func makeBrains(tripwire: TheTripwire) throws -> TheBrains {
        TheBrains(tripwire: tripwire)
    }

    /// Builds the runtime again from `makeBrains`.
    ///
    /// A test whose runtime depends on something it can only build once the app
    /// is on screen — a keyboard bound to a live text field — sets that up and
    /// asks for the runtime again. It is the same tripwire either way: swapping
    /// the runtime changes what reads the app, not how many things read it.
    func restartRuntime() async throws {
        brains.stopTestObservation()
        brains = try makeBrains(tripwire: tripwire)
        await brains.startTestObservation()
    }

    final override func startObserving() async throws {
        tripwire = TheTripwire()
        brains = try makeBrains(tripwire: tripwire)
        await brains.startTestObservation()
    }

    final override func stopObserving() async throws {
        guard let brains else { return }
        brains.stopTestObservation()
        assertRuntimeStopped(brains)
        self.brains = nil
        tripwire = nil
        assertNotificationHookReleased()
    }

    /// Asserts the runtime left nothing running behind it.
    ///
    /// A stream still awaiting an observation outlives the test that opened it
    /// and reports as a failure somewhere later, so the test that owes it fails
    /// here instead.
    private func assertRuntimeStopped(
        _ brains: TheBrains,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let observationStream = brains.vault.semanticObservationStream
        XCTAssertFalse(brains.semanticObservationIsActive, file: file, line: line)
        XCTAssertFalse(brains.tripwire.isPulseRunning, file: file, line: line)
        XCTAssertFalse(observationStream.isActive, file: file, line: line)
        XCTAssertEqual(observationStream.observationWaiterCount, 0, file: file, line: line)
        XCTAssertEqual(observationStream.activeObservationDemandCount, 0, file: file, line: line)
    }

    /// Asserts the test released the process-wide notification destination.
    private func assertNotificationHookReleased(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            AccessibilityNotificationObserver.shared.hasDestination,
            "A notification destination outlived the test that built it",
            file: file,
            line: line
        )
    }
}

@MainActor
extension TheBrains {
    func startTestObservation() async {
        tripwire.startPulse()
        vault.semanticObservationStream.start()
    }

    func stopTestObservation() {
        vault.semanticObservationStream.stop()
        tripwire.stopPulse()
    }
}

#endif
