#if canImport(UIKit)
import XCTest
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
import ThePlans
@testable import TheScore

final class TheVaultObservedStateEqualityTests: XCTestCase {
    private let geometryTolerance: CGFloat = 8

    func testSemanticChangeIsNotTheSameObservedState() {
        let previous = snapshot(label: "Subtotal")
        let current = snapshot(label: "Total")

        XCTAssertFalse(previous.hasSameObservedState(as: current, geometryTolerance: geometryTolerance))
    }

    func testScreenGeometryUsesTheSingleCoarseTolerance() {
        let baseline = snapshot(screenFrame: CGRect(x: 0, y: 100, width: 200, height: 44))
        let insideTolerance = snapshot(
            screenFrame: CGRect(x: 7, y: 107, width: 207, height: 51)
        )
        let outsideTolerance = snapshot(
            screenFrame: CGRect(x: 8, y: 100, width: 200, height: 44)
        )

        XCTAssertTrue(
            baseline.hasSameObservedState(as: insideTolerance, geometryTolerance: geometryTolerance)
        )
        XCTAssertFalse(
            baseline.hasSameObservedState(as: outsideTolerance, geometryTolerance: geometryTolerance)
        )
    }

    func testViewGeometryMovementIsNotTheSameObservedState() {
        let previous = snapshot(viewFrame: CGRect(x: 0, y: 0, width: 200, height: 44))
        let current = snapshot(viewFrame: CGRect(x: 0, y: 9, width: 200, height: 44))

        XCTAssertFalse(previous.hasSameObservedState(as: current, geometryTolerance: geometryTolerance))
    }

    func testInvalidatedParentSpaceGeometryRemainsStable() {
        let previous = snapshot(parentGeometryAvailable: false)
        let current = snapshot(parentGeometryAvailable: false)

        XCTAssertTrue(previous.hasSameObservedState(as: current, geometryTolerance: geometryTolerance))
    }

    func testParentSpaceGeometryInvalidationIsAnObservedStateChange() {
        let previous = snapshot(parentGeometryAvailable: true)
        let current = snapshot(parentGeometryAvailable: false)

        XCTAssertFalse(previous.hasSameObservedState(as: current, geometryTolerance: geometryTolerance))
    }

    func testActivationPointMovementIsNotTheSameObservedState() {
        let previous = snapshot(activationPoint: CGPoint(x: 100, y: 122))
        let current = snapshot(activationPoint: CGPoint(x: 109, y: 122))

        XCTAssertFalse(previous.hasSameObservedState(as: current, geometryTolerance: geometryTolerance))
    }

    func testVisibilityTransitionIsNotTheSameObservedState() {
        let previous = snapshot(visibility: .onscreen)
        let current = snapshot(visibility: .offscreen)

        XCTAssertFalse(previous.hasSameObservedState(as: current, geometryTolerance: geometryTolerance))
    }

    func testCaptureMembershipIsObservedStateWithoutScreenGeometry() throws {
        let captured = snapshot(visibility: .offscreen)
        let interface = captured.interface
        let remembered = Observation.Snapshot(
            interface: try Interface(
                timestamp: interface.timestamp,
                tree: interface.tree,
                annotations: InterfaceAnnotations(elements: interface.annotations.elements.map {
                    InterfaceElementAnnotation(path: $0.path, actions: $0.actions, geometry: $0.geometry, source: .memory)
                }, containers: interface.annotations.containers)
            ),
            context: captured.context
        )

        XCTAssertFalse(captured.hasSameObservedState(as: remembered, geometryTolerance: geometryTolerance))
    }

    func testFocusAndKeyboardContextAreObservedState() {
        let baseline = snapshot(context: Self.context())
        let focused = snapshot(context: Self.context(firstResponder: .label("Search")))
        let keyboardVisible = snapshot(context: Self.context(keyboardVisible: true))

        XCTAssertFalse(baseline.hasSameObservedState(as: focused, geometryTolerance: geometryTolerance))
        XCTAssertFalse(
            baseline.hasSameObservedState(as: keyboardVisible, geometryTolerance: geometryTolerance)
        )
    }

    func testContainerChangeIsNotTheSameObservedState() {
        let previous = snapshot(containerIdentifier: "library")
        let current = snapshot(containerIdentifier: "checkout")

        XCTAssertFalse(previous.hasSameObservedState(as: current, geometryTolerance: geometryTolerance))
    }

    func testElementAndContainerExistenceAreObservedState() {
        let baseline = snapshot()
        let elementRemoved = snapshot(includeElement: false)
        let containerRemoved = snapshot(includeContainer: false)

        XCTAssertFalse(
            baseline.hasSameObservedState(as: elementRemoved, geometryTolerance: geometryTolerance)
        )
        XCTAssertFalse(
            baseline.hasSameObservedState(as: containerRemoved, geometryTolerance: geometryTolerance)
        )
    }

    func testTimestampIsNotObservedState() {
        let previous = snapshot(timestamp: Date(timeIntervalSince1970: 10))
        let current = snapshot(timestamp: Date(timeIntervalSince1970: 20))

        XCTAssertTrue(previous.hasSameObservedState(as: current, geometryTolerance: geometryTolerance))
    }

    func testUnreadableGeometryNeverProvesNoChange() {
        let previous = snapshot(screenFrameAvailable: false)
        let current = snapshot(screenFrameAvailable: false)

        XCTAssertFalse(previous.hasSameObservedState(as: current, geometryTolerance: geometryTolerance))
    }

    private func snapshot(
        timestamp: Date = Date(timeIntervalSince1970: 10),
        label: String = "Subtotal",
        screenFrame: CGRect = CGRect(x: 0, y: 100, width: 200, height: 44),
        viewFrame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 44),
        activationPoint: CGPoint = CGPoint(x: 100, y: 122),
        visibility: AccessibilityVisibility = .onscreen,
        context: Observation.Context? = nil,
        containerIdentifier: String = "library",
        screenFrameAvailable: Bool = true,
        parentGeometryAvailable: Bool = true,
        includeElement: Bool = true,
        includeContainer: Bool = true
    ) -> Observation.Snapshot {
        let screenSpace: HeistElement.Geometry.ScreenSpace
        if visibility == .onscreen {
            screenSpace = .onscreen(
                frame: screenFrameAvailable
                    ? .available(requireScreenRect(screenFrame))
                    : .unavailable,
                activationPoint: .explicit(requireScreenPoint(activationPoint))
            )
        } else {
            screenSpace = .offscreen
        }

        let geometry = HeistElement.Geometry(
            screen: screenSpace,
            view: parentGeometryAvailable
                ? .available(.init(
                    ownerPath: TreePath([0]),
                    frame: requireViewRect(viewFrame),
                    activationPoint: requireViewPoint(activationPoint)
                ))
                : .invalidated(ownerPath: TreePath([0]))
        )
        let element = AccessibilityElement.make(
            label: label,
            shape: .frame(AccessibilityRect(screenFrame)),
            activationPoint: activationPoint,
            visibility: visibility
        )
        let container = AccessibilityContainer(
            type: .list,
            identifier: containerIdentifier,
            frame: AccessibilityRect(x: 0, y: 0, width: 320, height: 640)
        )
        let elementPath = TreePath([0, 0])
        let tree: [AccessibilityHierarchy] = includeContainer
            ? [
                .container(
                    container,
                    children: includeElement
                        ? [.element(element, traversalIndex: 0)]
                        : []
                ),
            ]
            : []
        let interface = requireInterface(
            timestamp: timestamp,
            tree: tree,
            annotations: InterfaceAnnotations(
                elements: includeContainer && includeElement ? [
                    InterfaceElementAnnotation(
                        path: elementPath,
                        actions: [],
                        geometry: geometry
                    ),
                ] : [],
                containers: includeContainer ? [
                    InterfaceContainerAnnotation(
                        path: TreePath([0]),
                        containerName: ContainerName(stringLiteral: "library"),
                        scrollInventory: nil
                    ),
                ] : []
            )
        )
        return Observation.Snapshot(
            interface: interface,
            context: context ?? Self.context()
        )
    }

    private static func context(
        firstResponder: AccessibilityTarget? = nil,
        keyboardVisible: Bool? = false
    ) -> Observation.Context {
        Observation.Context(
            firstResponder: firstResponder,
            keyboardVisible: keyboardVisible,
            screenId: "library",
            windowStack: [
                Observation.WindowContext(index: 0, level: 0, isKeyWindow: true),
            ]
        )
    }

    private func requireInterface(
        timestamp: Date,
        tree: [AccessibilityHierarchy],
        annotations: InterfaceAnnotations
    ) -> Interface {
        do {
            return try Interface(
                timestamp: timestamp,
                tree: tree,
                annotations: annotations
            )
        } catch {
            preconditionFailure("Invalid observed-state test interface: \(error)")
        }
    }

    private func requireScreenRect(_ rect: CGRect) -> ScreenRect {
        do {
            return try ScreenRect(validating: rect)
        } catch {
            preconditionFailure("Invalid observed-state test screen rect: \(error)")
        }
    }

    private func requireViewRect(_ rect: CGRect) -> ViewRect {
        do {
            return try ViewRect(validating: rect)
        } catch {
            preconditionFailure("Invalid observed-state test view rect: \(error)")
        }
    }

    private func requireScreenPoint(_ point: CGPoint) -> ScreenPoint {
        do {
            return ScreenPoint(
                x: try FiniteCoordinate(validating: Double(point.x)),
                y: try FiniteCoordinate(validating: Double(point.y))
            )
        } catch {
            preconditionFailure("Invalid observed-state test screen point: \(error)")
        }
    }

    private func requireViewPoint(_ point: CGPoint) -> ViewPoint {
        do {
            return try ViewPoint(validating: point)
        } catch {
            preconditionFailure("Invalid observed-state test view point: \(error)")
        }
    }
}
#endif
