#if canImport(UIKit) && canImport(AccessibilitySnapshotParser)
import AccessibilitySnapshotParser
import CoreGraphics
import TheScore

extension Observation.Snapshot {
    /// Whether two admitted snapshots contain the same observable state.
    ///
    /// Capture time is evidence metadata, not accessibility state. Everything
    /// else participates, with geometry compared through the device geometry
    /// tolerance captured by the caller.
    internal func hasSameObservedState(
        as other: Observation.Snapshot,
        geometryTolerance: CGFloat
    ) -> Bool {
        context == other.context
            && interface.hasSameObservedState(as: other.interface, geometryTolerance: geometryTolerance)
    }
}

private extension Interface {
    func hasSameObservedState(as other: Interface, geometryTolerance: CGFloat) -> Bool {
        guard diagnostics == other.diagnostics,
              screenActions == other.screenActions
        else { return false }

        let previousNodes = graph.nodesInPathOrder
        let currentNodes = other.graph.nodesInPathOrder
        guard previousNodes.count == currentNodes.count else { return false }

        return zip(previousNodes, currentNodes).allSatisfy { previous, current in
            guard previous.path == current.path,
                  previous.traversalIndex == current.traversalIndex
            else { return false }

            return switch (previous.kind, current.kind) {
            case let (.element(previousElement), .element(currentElement)):
                previousElement.hasSameObservedState(
                    as: currentElement,
                    geometryTolerance: geometryTolerance
                )
            case let (.container(previousContainer), .container(currentContainer)):
                previousContainer.hasSameObservedState(
                    as: currentContainer,
                    geometryTolerance: geometryTolerance
                )
            case (.element, .container), (.container, .element):
                false
            }
        }
    }
}

private extension InterfaceGraphElementRecord {
    func hasSameObservedState(
        as other: InterfaceGraphElementRecord,
        geometryTolerance: CGFloat
    ) -> Bool {
        guard accessibilityElement.hasSameNonGeometricState(
            as: other.accessibilityElement
        ),
        annotation.actions == other.annotation.actions
        else { return false }

        return annotation.geometry.hasSameObservedState(
            as: other.annotation.geometry,
            geometryTolerance: geometryTolerance
        )
    }
}

private extension AccessibilityElement {
    func hasSameNonGeometricState(as other: AccessibilityElement) -> Bool {
        description == other.description
            && label == other.label
            && value == other.value
            && traits == other.traits
            && identifier == other.identifier
            && hint == other.hint
            && userInputLabels == other.userInputLabels
            && usesDefaultActivationPoint == other.usesDefaultActivationPoint
            && customActions == other.customActions
            && customContent == other.customContent
            && customRotors == other.customRotors
            && accessibilityLanguage == other.accessibilityLanguage
            && respondsToUserInteraction == other.respondsToUserInteraction
            && visibility == other.visibility
    }
}

private extension InterfaceGraphContainerRecord {
    func hasSameObservedState(
        as other: InterfaceGraphContainerRecord,
        geometryTolerance: CGFloat
    ) -> Bool {
        container.type == other.container.type
            && container.identifier == other.container.identifier
            && container.scrollableContentSize == other.container.scrollableContentSize
            && container.isModalBoundary == other.container.isModalBoundary
            && container.customActions == other.container.customActions
            && annotation == other.annotation
            && ScreenFrameEvidence(container.frame).hasSameObservedState(
                as: ScreenFrameEvidence(other.container.frame),
                geometryTolerance: geometryTolerance
            )
    }
}

private extension HeistElement.Geometry {
    func hasSameObservedState(
        as other: HeistElement.Geometry,
        geometryTolerance: CGFloat
    ) -> Bool {
        screen.hasSameObservedState(as: other.screen, geometryTolerance: geometryTolerance)
            && view.hasSameObservedState(as: other.view, geometryTolerance: geometryTolerance)
    }
}

private extension HeistElement.Geometry.ScreenSpace {
    func hasSameObservedState(
        as other: HeistElement.Geometry.ScreenSpace,
        geometryTolerance: CGFloat
    ) -> Bool {
        switch (self, other) {
        case (.offscreen, .offscreen):
            true
        case let (
            .onscreen(previousFrame, previousActivationPoint),
            .onscreen(currentFrame, currentActivationPoint)
        ):
            previousFrame.hasSameObservedState(
                as: currentFrame,
                geometryTolerance: geometryTolerance
            ) && previousActivationPoint.hasSameObservedState(
                as: currentActivationPoint,
                geometryTolerance: geometryTolerance
            )
        case (.onscreen, .offscreen), (.offscreen, .onscreen):
            false
        }
    }
}

private extension ScreenFrameEvidence {
    func hasSameObservedState(
        as other: ScreenFrameEvidence,
        geometryTolerance: CGFloat
    ) -> Bool {
        guard let rect, let otherRect = other.rect else { return false }
        return CoarseFrameComparison.isInSamePlace(
            rect,
            otherRect,
            geometryTolerance: geometryTolerance
        )
    }
}

private extension ActivationPointEvidence {
    func hasSameObservedState(
        as other: ActivationPointEvidence,
        geometryTolerance: CGFloat
    ) -> Bool {
        switch (self, other) {
        case let (.explicit(previous), .explicit(current)),
             let (.defaultCenter(previous), .defaultCenter(current)):
            CoarseFrameComparison.isInSamePlace(
                previous,
                current,
                geometryTolerance: geometryTolerance
            )
        case (.unavailable, _), (_, .unavailable),
             (.explicit, .defaultCenter), (.defaultCenter, .explicit):
            false
        }
    }
}

private extension HeistElement.Geometry.ViewSpace {
    func hasSameObservedState(
        as other: HeistElement.Geometry.ViewSpace,
        geometryTolerance: CGFloat
    ) -> Bool {
        switch (self, other) {
        case let (.available(previous), .available(current)):
            guard previous.ownerPath == current.ownerPath else { return false }
            return CoarseFrameComparison.isInSamePlace(
                previous.frame,
                current.frame,
                geometryTolerance: geometryTolerance
            ) && CoarseFrameComparison.isInSamePlace(
                previous.activationPoint,
                current.activationPoint,
                geometryTolerance: geometryTolerance
            )
        case let (.invalidated(previousOwner), .invalidated(currentOwner)):
            return previousOwner == currentOwner
        case (.available, .invalidated), (.invalidated, .available):
            return false
        }
    }
}
#endif
