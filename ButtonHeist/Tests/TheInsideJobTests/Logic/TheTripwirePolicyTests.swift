#if canImport(UIKit)
import XCTest
@testable import TheInsideJob

@MainActor
final class TheTripwirePolicyTests: XCTestCase {

    func testUnchangedHierarchyContinuesPeriodicCaptureWithoutNotifications() {
        var admission = TheTripwire.PulseAdmission()

        XCTAssertTrue(admission.admit(TheTripwire.TripwireSignal.empty.hierarchy))
        XCTAssertTrue(admission.admit(TheTripwire.TripwireSignal.empty.hierarchy))
        XCTAssertTrue(admission.admit(
            TheTripwire.TripwireSignal.empty.recordingAccessibilityNotifications(through: 42).hierarchy
        ))
    }

    func testWindowChangeSkipsExactlyOneCapturePulse() {
        var admission = TheTripwire.PulseAdmission()
        let window = UIWindow()
        let changed = hierarchy(window: window)

        XCTAssertTrue(admission.admit(TheTripwire.TripwireSignal.empty.hierarchy))
        XCTAssertFalse(admission.admit(changed))
        XCTAssertTrue(admission.admit(changed))
        XCTAssertTrue(admission.admit(changed))
    }

    func testRepeatedHierarchyChangesCannotExtendRenderGrace() {
        var admission = TheTripwire.PulseAdmission()
        let first = UIWindow()
        let second = UIWindow()

        XCTAssertTrue(admission.admit(TheTripwire.TripwireSignal.empty.hierarchy))
        XCTAssertFalse(admission.admit(hierarchy(window: first)))
        XCTAssertTrue(admission.admit(hierarchy(window: second)))
    }

    func testTouchUpSkipsOnePulseAndCoalescesWithWindowChange() {
        var admission = TheTripwire.PulseAdmission()
        let window = UIWindow()
        XCTAssertTrue(admission.admit(TheTripwire.TripwireSignal.empty.hierarchy))

        admission.deferForRendering()
        XCTAssertFalse(admission.admit(hierarchy(window: window)))
        admission.deferForRendering()
        XCTAssertTrue(admission.admit(hierarchy(window: window)))
        XCTAssertTrue(admission.admit(hierarchy(window: window)))
    }

    func testTouchUpBeforeFirstPulseStillYieldsRendering() {
        var admission = TheTripwire.PulseAdmission()

        admission.deferForRendering()

        XCTAssertFalse(admission.admit(TheTripwire.TripwireSignal.empty.hierarchy))
        XCTAssertTrue(admission.admit(TheTripwire.TripwireSignal.empty.hierarchy))
    }

    func testControllerChangeAlsoYieldsRendering() {
        var admission = TheTripwire.PulseAdmission()
        let controller = UIViewController()
        let changed = TheTripwire.TripwireSignal(
            topmostVC: ObjectIdentifier(controller),
            navigation: .empty,
            windowStack: .empty
        )

        XCTAssertTrue(admission.admit(TheTripwire.TripwireSignal.empty.hierarchy))
        XCTAssertFalse(admission.admit(changed.hierarchy))
        XCTAssertTrue(admission.admit(changed.hierarchy))
    }

    func testActiveCaptureRateIsCappedOnStandardAndProMotionScreens() {
        for maximum in [60, 120] {
            let range = TheTripwire.activeDisplayFrameRateRange(maximumFramesPerSecond: maximum)
            XCTAssertEqual(range.minimum, 30)
            XCTAssertEqual(range.maximum, 30)
            XCTAssertEqual(range.preferred, 30)
        }
    }

    func testActiveCaptureRateRespectsLowerScreenMaximum() {
        let range = TheTripwire.activeDisplayFrameRateRange(maximumFramesPerSecond: 24)

        XCTAssertEqual(range.minimum, 24)
        XCTAssertEqual(range.maximum, 24)
        XCTAssertEqual(range.preferred, 24)
    }

    func testSemanticSignalProjectsOnlyDurableWindowFacts() {
        let viewController = UIViewController()
        let window = UIWindow()
        let signal = TheTripwire.TripwireSignal(
            topmostVC: ObjectIdentifier(viewController),
            navigation: .empty,
            windowStack: TheTripwire.WindowStackSignal(windows: [
                TheTripwire.WindowSignal(
                    id: ObjectIdentifier(window),
                    level: 7,
                    isKeyWindow: true
                ),
            ]),
            accessibilityNotificationSequence: 42
        )

        XCTAssertEqual(
            signal.semanticValue,
            TheTripwire.SemanticSignal(windows: [
                TheTripwire.SemanticWindowSignal(level: 7, isKeyWindow: true),
            ])
        )
    }

    private func hierarchy(window: UIWindow) -> TheTripwire.HierarchySignal {
        TheTripwire.TripwireSignal(
            topmostVC: nil,
            navigation: .empty,
            windowStack: .init(windows: [
                .init(id: ObjectIdentifier(window), level: 0, isKeyWindow: true),
            ])
        ).hierarchy
    }
}

#endif // canImport(UIKit)
