#if canImport(UIKit)
import XCTest
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
import ThePlans
import TheScore

/// A non-finite activation point is normalised to the midpoint of the element's
/// shape before admission, so one bad element cannot make a screen unreadable.
@MainActor
final class ActivationPointNormalizationTests: XCTestCase {

    private let frame = AccessibilityRect(x: 20, y: 100, width: 200, height: 44)

    func testNaNActivationPointBecomesFrameMidpoint() {
        let element = nonFiniteElement(activationPoint: CGPoint(x: CGFloat.nan, y: CGFloat.nan))

        let normalized = element.normalizingNonFiniteActivationPoint()

        XCTAssertEqual(normalized.activationPoint, AccessibilityPoint(x: 120, y: 122))
        XCTAssertTrue(normalized.usesDefaultActivationPoint)
        XCTAssertEqual(normalized.shape, element.shape)
        XCTAssertEqual(normalized.label, element.label)
    }

    func testInfiniteActivationPointBecomesFrameMidpoint() {
        let element = nonFiniteElement(activationPoint: CGPoint(x: 40, y: CGFloat.infinity))

        let normalized = element.normalizingNonFiniteActivationPoint()

        XCTAssertEqual(normalized.activationPoint, AccessibilityPoint(x: 120, y: 122))
        XCTAssertTrue(normalized.usesDefaultActivationPoint)
    }

    func testNonFiniteActivationPointOnPathShapeBecomesPathBoundsMidpoint() {
        let element = AccessibilityElement.make(
            label: "Menu",
            traits: .button,
            shape: .path([
                .move(to: AccessibilityPoint(x: 10, y: 10)),
                .line(to: AccessibilityPoint(x: 110, y: 10)),
                .line(to: AccessibilityPoint(x: 110, y: 50)),
                .line(to: AccessibilityPoint(x: 10, y: 50)),
                .closeSubpath,
            ]),
            activationPoint: CGPoint(x: CGFloat.nan, y: CGFloat.nan),
            usesDefaultActivationPoint: false
        )

        let normalized = element.normalizingNonFiniteActivationPoint()

        XCTAssertEqual(normalized.activationPoint, AccessibilityPoint(x: 60, y: 30))
        XCTAssertTrue(normalized.usesDefaultActivationPoint)
    }

    func testFiniteExplicitActivationPointIsUnchanged() {
        let element = AccessibilityElement.make(
            label: "Slider",
            shape: .frame(frame),
            activationPoint: CGPoint(x: 30, y: 110),
            usesDefaultActivationPoint: false
        )

        XCTAssertEqual(element.normalizingNonFiniteActivationPoint(), element)
    }

    func testNonFiniteActivationPointWithoutAdmissibleShapeIsLeftForAdmissionToReject() throws {
        let element = AccessibilityElement.make(
            label: "Menu",
            shape: .frame(AccessibilityRect(x: .nan, y: 0, width: 10, height: 10)),
            activationPoint: CGPoint(x: CGFloat.nan, y: CGFloat.nan),
            usesDefaultActivationPoint: false
        )

        let normalized = element.normalizingNonFiniteActivationPoint()

        XCTAssertFalse(normalized.activationPoint.isFinite)
        XCTAssertFalse(normalized.usesDefaultActivationPoint)
        XCTAssertThrowsError(try admit(normalized)) { error in
            XCTAssertTrue(error is InterfaceGeometryAdmissionError)
        }
    }

    func testRawNonFiniteActivationPointIsRejectedByAdmission() {
        let element = nonFiniteElement(activationPoint: CGPoint(x: CGFloat.nan, y: CGFloat.nan))

        XCTAssertThrowsError(try admit(element)) { error in
            let admissionError = error as? InterfaceGeometryAdmissionError
            XCTAssertEqual(admissionError?.path, TreePath([0]))
            XCTAssertEqual(admissionError?.field, "element activation point")
        }
    }

    func testNormalizedCaptureIsAdmittedWithDefaultCenterActivationPoint() throws {
        let element = nonFiniteElement(activationPoint: CGPoint(x: CGFloat.nan, y: CGFloat.nan))

        let observation = try admit(element.normalizingNonFiniteActivationPoint())

        let admitted = try XCTUnwrap(observation.tree.orderedElements.first { $0.element.label == "Menu" })
        XCTAssertEqual(admitted.element.activationPoint, AccessibilityPoint(x: 120, y: 122))
        XCTAssertEqual(
            TheVault.onscreenSpace(for: admitted.element),
            .onscreen(
                frame: ScreenFrameEvidence(frame),
                activationPoint: .defaultCenter(ScreenPoint(x: 120, y: 122))
            )
        )
    }

    // MARK: - Private Helpers

    private func nonFiniteElement(activationPoint: CGPoint) -> AccessibilityElement {
        .make(
            label: "Menu",
            traits: .button,
            shape: .frame(frame),
            activationPoint: activationPoint,
            usesDefaultActivationPoint: false
        )
    }

    private func admit(_ element: AccessibilityElement) throws -> InterfaceObservation {
        try TheVault.admitObservation(from: TheVault.CaptureTree(
            hierarchy: [.element(element, traversalIndex: 0)]
        ))
    }
}

#endif
