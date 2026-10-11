#if canImport(UIKit)
#if DEBUG
import UIKit

import TheScore
import ThePlans

import AccessibilitySnapshotParser

extension TheVault {

    // MARK: - Build Interface Observation From Parse

    /// Build an `InterfaceObservation` from one annotated capture tree.
    static func buildObservation(from result: CaptureTree) -> InterfaceObservation {
        do {
            return try admitObservation(from: result)
        } catch {
            preconditionFailure("InterfaceObservation build failed validation: \(error)")
        }
    }

    static func admitObservation(from result: CaptureTree) throws -> InterfaceObservation {
        let containerNamesByPath = buildContainerNamesByPath(
            containers: result.containers
        )

        let entries = buildObservationEntries(
            indexedElements: result.elements,
            offscreenScrollElements: result.inventoryEnumeration.offscreenElements,
            scroll: result.scroll,
            focus: result.focus
        )
        let heistIdsByPath = Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry in
                entry.isInParserHierarchy ? (entry.path, entry.heistId) : nil
            }
        )
        let containersByPath = viewportContainers(
            containers: result.containers,
            containerNamesByPath: containerNamesByPath,
            scroll: result.scroll
        )

        let firstResponders = entries.filter(\.isFirstResponder)
        let firstResponderHeistId = firstResponders.count == 1
            ? firstResponders.first?.heistId
            : nil

        let snapshot = LiveCapture.Snapshot(
            hierarchy: result.hierarchy,
            heistIdsByPath: heistIdsByPath,
            firstResponderHeistId: firstResponderHeistId
        )
        let tree = InterfaceTree(
            elements: Dictionary(
                uniqueKeysWithValues: entries.map { ($0.heistId, $0.treeElement) }
            ),
            containers: containersByPath,
            viewportCapture: snapshot
        )
        let liveReferences = ObservationLiveReferences(
            result: result,
            hierarchy: tree.viewportCapture.hierarchy,
            entries: entries
        )
        let dispatchReferences = LiveCapture.DispatchReferences(
            elementRefs: Dictionary(
                uniqueKeysWithValues: entries.compactMap { entry in
                    liveReferences.elementRef(for: entry).map { (entry.heistId, $0) }
                }
            ),
            containerRefsByPath: liveReferences.containerRefsByPath,
            scrollableContainerViewsByPath: liveReferences.scrollableContainerViewsByPath
        )
        return try InterfaceObservation.build(
            tree: tree,
            dispatchReferences: dispatchReferences
        )
    }

    private static func buildObservationEntries(
        indexedElements: [CapturedElement],
        offscreenScrollElements: [OffscreenScrollElement],
        scroll: ScrollFacts,
        focus: FocusFacts
    ) -> [ObservationBuildEntry] {
        let candidates = indexedElements.map(ObservationElementCandidate.viewport)
            + offscreenScrollElements.map(ObservationElementCandidate.offscreenScrollInventory)
        let heistIds = HeistIdAssignment.assign(candidates.map { candidate in
            HeistIdAssignment.Input(
                element: candidate.element,
                duplicateOrder: candidate.duplicateOrder(scroll: scroll)
            )
        })
        precondition(
            heistIds.count == candidates.count,
            "HeistIdAssignment must return one HeistId for each screen-build element"
        )
        return candidates.indices.map { index in
            let candidate = candidates[index]
            let heistId = heistIds[index]
            return ObservationBuildEntry(
                path: candidate.path,
                treeElement: InterfaceTree.Element(
                    heistId: heistId,
                    path: candidate.path,
                    scrollMembership: candidate.scrollMembership(scroll: scroll),
                    geometry: candidate.geometry(scroll: scroll),
                    element: candidate.element
                ),
                isFirstResponder: candidate.isFirstResponder(focus: focus),
                isInParserHierarchy: candidate.isInParserHierarchy
            )
        }
    }

    private static func viewportContainers(
        containers: [CapturedContainer],
        containerNamesByPath: [TreePath: ContainerName],
        scroll: ScrollFacts
    ) -> [TreePath: InterfaceTree.Container] {
        Dictionary(
            uniqueKeysWithValues: containers.map { identity in
                (
                    identity.path,
                    InterfaceTree.Container(
                        container: identity.container,
                        path: identity.path,
                        containerName: containerNamesByPath[identity.path],
                        viewSpace: scroll.containerViewSpacesByPath[identity.path]
                            ?? identity.viewSpace,
                        scrollMembership: identity.scrollMembership,
                        scrollInventory: scroll.inventoriesByPath[identity.path]
                    )
                )
            }
        )
    }

    nonisolated static func onscreenSpace(
        for element: AccessibilityElement
    ) -> HeistElement.Geometry.ScreenSpace {
        let frame = ScreenFrameEvidence(element.shape)
        let activationPoint: ActivationPointEvidence
        if element.usesDefaultActivationPoint {
            if let rect = frame.rect,
               let x = try? FiniteCoordinate(validating: rect.midX),
               let y = try? FiniteCoordinate(validating: rect.midY) {
                activationPoint = .defaultCenter(ScreenPoint(x: x, y: y))
            } else {
                activationPoint = .unavailable
            }
        } else if let x = try? FiniteCoordinate(validating: element.activationPoint.x),
                  let y = try? FiniteCoordinate(validating: element.activationPoint.y) {
            activationPoint = .explicit(ScreenPoint(x: x, y: y))
        } else {
            activationPoint = .unavailable
        }
        return .onscreen(frame: frame, activationPoint: activationPoint)
    }

    // MARK: - Container Name Index

    private static func buildContainerNamesByPath(
        containers: [CapturedContainer]
    ) -> [TreePath: ContainerName] {
        let candidates = containers.map { identity in
            ContainerNameCandidate(
                path: identity.path,
                readableName: containerName(for: identity.container)
            )
        }

        let duplicateReadableNames = Set(
            Dictionary(grouping: candidates, by: \.readableName)
                .filter { $0.value.count > 1 }
                .keys
        )

        var byPath: [TreePath: ContainerName] = [:]
        for candidate in candidates {
            byPath[candidate.path] = duplicateReadableNames.contains(candidate.readableName)
                ? captureLocalContainerId(readableName: candidate.readableName, path: candidate.path)
                : candidate.readableName
        }
        return byPath
    }

    /// Disambiguate containers that expose the same values by their position in
    /// the parsed tree. The tree path is what already makes container identity
    /// path-distinct, it is an exact integer sequence rather than a measurement,
    /// and it is the same for two parses of an unchanged screen — so unlike the
    /// frame hash it replaces, this suffix cannot be moved by layout noise.
    static func captureLocalContainerId(
        readableName: ContainerName,
        path: TreePath
    ) -> ContainerName {
        ContainerName(
            stringLiteral: "\(readableName.rawValue)-\(path.indices.map(String.init).joined(separator: "_"))"
        )
    }

    private struct ContainerNameCandidate {
        let path: TreePath
        let readableName: ContainerName
    }

    private enum ObservationElementCandidate {
        case viewport(CapturedElement)
        case offscreenScrollInventory(OffscreenScrollElement)

        var path: TreePath {
            switch self {
            case .viewport(let identity):
                identity.path
            case .offscreenScrollInventory(let element):
                element.path
            }
        }

        var element: AccessibilityElement {
            switch self {
            case .viewport(let identity):
                identity.element
            case .offscreenScrollInventory(let element):
                element.element
            }
        }

        var isInParserHierarchy: Bool {
            switch self {
            case .viewport:
                true
            case .offscreenScrollInventory:
                false
            }
        }

        func scrollMembership(scroll: ScrollFacts) -> InterfaceTree.ScrollMembership? {
            switch self {
            case .viewport(let identity):
                scroll.element(at: identity.path)?.membership
            case .offscreenScrollInventory(let element):
                InterfaceTree.ScrollMembership(
                    containerPath: element.scrollContainerPath,
                    index: element.scrollIndex
                )
            }
        }

        func geometry(
            scroll: ScrollFacts
        ) -> HeistElement.Geometry {
            let view = switch self {
            case .viewport(let identity):
                scroll.element(at: identity.path)?.viewSpace ?? identity.viewSpace
            case .offscreenScrollInventory(let element):
                element.viewSpace
            }
            let screen: HeistElement.Geometry.ScreenSpace = switch self {
            case .viewport where element.visibility == .onscreen:
                TheVault.onscreenSpace(for: element)
            case .viewport:
                .offscreen
            case .offscreenScrollInventory:
                .offscreen
            }
            return HeistElement.Geometry(screen: screen, view: view)
        }

        func isFirstResponder(focus: FocusFacts) -> Bool {
            switch self {
            case .viewport(let identity):
                focus.isFirstResponder(at: identity.path)
            case .offscreenScrollInventory:
                false
            }
        }

        func duplicateOrder(scroll: ScrollFacts) -> HeistIdAssignment.DuplicateOrder? {
            switch self {
            case .viewport(let identity):
                if let membership = scroll.element(at: identity.path)?.membership,
                   let index = membership.index {
                    return .scrollMembership(containerPath: membership.containerPath, index: index)
                }
                return nil
            case .offscreenScrollInventory(let element):
                return .scrollMembership(
                    containerPath: element.scrollContainerPath,
                    index: element.scrollIndex
                )
            }
        }
    }

    private struct ObservationBuildEntry: Equatable {
        let path: TreePath
        let treeElement: InterfaceTree.Element
        let isFirstResponder: Bool
        let isInParserHierarchy: Bool

        var heistId: HeistId {
            treeElement.heistId
        }
    }

    private struct ObservationLiveReferences {
        private let objectsByPath: [TreePath: NSObject]
        private let scrollViewsByPath: [TreePath: UIScrollView]
        let containerRefsByPath: [TreePath: LiveCapture.ContainerRef]
        let scrollableContainerViewsByPath: [TreePath: LiveCapture.ScrollableViewRef]

        init(
            result: CaptureTree,
            hierarchy: [AccessibilityHierarchy],
            entries: [ObservationBuildEntry]
        ) {
            let elementPaths = Set(entries.map(\.path))
            for path in result.objectsByPath.keys.sorted() where !elementPaths.contains(path) {
                preconditionFailure(
                    "InterfaceObservation build received live element object for non-element entry path \(path.indices)"
                )
            }
            for path in result.containerObjectsByPath.keys.sorted() {
                guard case .container = hierarchy.node(at: path) else {
                    preconditionFailure(
                        "InterfaceObservation build received live container object for non-container path \(path.indices)"
                    )
                }
            }
            for path in result.scrollViewsByPath.keys.sorted() {
                guard case .container(let container, _) = hierarchy.node(at: path),
                      container.isScrollable else {
                    preconditionFailure(
                        "InterfaceObservation build received live scroll view for non-scrollable container path \(path.indices)"
                    )
                }
            }

            objectsByPath = result.objectsByPath
            scrollViewsByPath = result.scrollViewsByPath
            containerRefsByPath = result.containerObjectsByPath.mapValues {
                LiveCapture.ContainerRef(object: $0)
            }
            scrollableContainerViewsByPath = result.scrollViewsByPath.mapValues {
                LiveCapture.ScrollableViewRef(view: $0)
            }
        }

        func elementRef(for entry: ObservationBuildEntry) -> LiveCapture.ElementRef? {
            guard case .onscreen = entry.treeElement.geometry.screen else { return nil }
            let object = objectsByPath[entry.path]
            let scrollView = entry.treeElement.scrollMembership.flatMap { membership in
                scrollViewsByPath[membership.containerPath]
            }
            guard object != nil || scrollView != nil else { return nil }
            return LiveCapture.ElementRef(
                object: object,
                scrollView: scrollView
            )
        }
    }

}

extension AccessibilityElement {
    func translatedBy(
        x: CGFloat,
        y: CGFloat,
        screenBounds: CGRect?
    ) -> AccessibilityElement {
        let translatedShape = shape.translatedBy(x: x, y: y)
        let translatedVisibility: AccessibilityVisibility = if visibility == .onscreen,
                                                               let screenBounds,
                                                               !screenBounds.intersects(translatedShape.frame) {
            .offscreen
        } else {
            visibility
        }
        return AccessibilityElement(
            description: description,
            label: label,
            value: value,
            traits: traits,
            identifier: identifier,
            hint: hint,
            userInputLabels: userInputLabels,
            shape: translatedShape,
            activationPoint: activationPoint.translatedBy(x: x, y: y),
            usesDefaultActivationPoint: usesDefaultActivationPoint,
            customActions: customActions,
            customContent: customContent,
            customRotors: customRotors.map { $0.translatedBy(x: x, y: y) },
            accessibilityLanguage: accessibilityLanguage,
            respondsToUserInteraction: respondsToUserInteraction,
            visibility: translatedVisibility
        )
    }
}

private extension AccessibilityElement.CustomRotor {
    func translatedBy(x: CGFloat, y: CGFloat) -> AccessibilityElement.CustomRotor {
        AccessibilityElement.CustomRotor(
            name: name,
            resultMarkers: resultMarkers.map { $0.translatedBy(x: x, y: y) },
            limit: limit
        )
    }
}

private extension AccessibilityElement.CustomRotor.ResultMarker {
    func translatedBy(x: CGFloat, y: CGFloat) -> AccessibilityElement.CustomRotor.ResultMarker {
        AccessibilityElement.CustomRotor.ResultMarker(
            elementDescription: elementDescription,
            rangeDescription: rangeDescription,
            shape: shape?.translatedBy(x: x, y: y)
        )
    }
}

extension AccessibilityContainer {
    func translatedBy(x: CGFloat, y: CGFloat) -> AccessibilityContainer {
        AccessibilityContainer(
            type: type,
            identifier: identifier,
            scrollableContentSize: scrollableContentSize,
            frame: frame.translatedBy(x: x, y: y),
            isModalBoundary: isModalBoundary,
            customActions: customActions
        )
    }
}

private extension AccessibilityShape {
    func translatedBy(x: CGFloat, y: CGFloat) -> AccessibilityShape {
        switch self {
        case .frame(let rect):
            return .frame(rect.translatedBy(x: x, y: y))
        case .path(let elements):
            return .path(elements.map { $0.translatedBy(x: x, y: y) })
        }
    }
}

private extension AccessibilityPathElement {
    func translatedBy(x: CGFloat, y: CGFloat) -> AccessibilityPathElement {
        switch self {
        case .move(let point):
            return .move(to: point.translatedBy(x: x, y: y))
        case .line(let point):
            return .line(to: point.translatedBy(x: x, y: y))
        case .quadCurve(let point, let control):
            return .quadCurve(
                to: point.translatedBy(x: x, y: y),
                control: control.translatedBy(x: x, y: y)
            )
        case .curve(let point, let control1, let control2):
            return .curve(
                to: point.translatedBy(x: x, y: y),
                control1: control1.translatedBy(x: x, y: y),
                control2: control2.translatedBy(x: x, y: y)
            )
        case .closeSubpath:
            return .closeSubpath
        }
    }
}

private extension AccessibilityRect {
    func translatedBy(x: CGFloat, y: CGFloat) -> AccessibilityRect {
        AccessibilityRect(
            origin: origin.translatedBy(x: x, y: y),
            size: size
        )
    }
}

private extension AccessibilityPoint {
    func translatedBy(x: CGFloat, y: CGFloat) -> AccessibilityPoint {
        AccessibilityPoint(
            x: self.x + Double(x),
            y: self.y + Double(y)
        )
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
