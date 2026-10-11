#if canImport(UIKit)
#if DEBUG
import UIKit

import ThePlans
import TheScore

import AccessibilitySnapshotParser

extension TheVault {

    // MARK: - Capture Annotations

    struct CapturedContainer {
        let path: TreePath
        let container: AccessibilityContainer
        let viewSpace: HeistElement.Geometry.ViewSpace
        let scrollMembership: InterfaceTree.ScrollMembership?
    }

    struct CapturedElement {
        let path: TreePath
        let element: AccessibilityElement
        let traversalIndex: Int
        let viewSpace: HeistElement.Geometry.ViewSpace
        let scrollMembership: InterfaceTree.ScrollMembership?
    }

    fileprivate struct CaptureTraversal {
        let path: TreePath
        let parentScrollContainerPath: TreePath?
    }

    fileprivate struct CaptureAccumulator {
        var containers: [CapturedContainer] = []
        var elements: [CapturedElement] = []
    }

    static func captureAnnotations(
        hierarchy: [AccessibilityHierarchy],
        viewHierarchy: [AccessibilityHierarchy]? = nil,
        scrollableContainerPaths: Set<TreePath> = []
    ) -> (containers: [CapturedContainer], elements: [CapturedElement]) {
        let viewHierarchy = viewHierarchy ?? hierarchy
        let viewElementsByPath = Dictionary(
            uniqueKeysWithValues: viewHierarchy.pathIndexedElements.map { ($0.path, $0.element) }
        )
        let viewContainersByPath = Dictionary(
            uniqueKeysWithValues: viewHierarchy.pathIndexedContainers.map { ($0.path, $0.container) }
        )
        var accumulator = CaptureAccumulator()
        for (rootIndex, root) in hierarchy.enumerated() {
            root.foldedPreorder(
                context: CaptureTraversal(
                    path: TreePath([rootIndex]),
                    parentScrollContainerPath: nil
                ),
                into: &accumulator,
                onElement: { element, traversalIndex, context, accumulator in
                    let viewElement = viewElementsByPath[context.path] ?? element
                    accumulator.elements.append(
                        CapturedElement(
                            path: context.path,
                            element: element,
                            traversalIndex: traversalIndex,
                            viewSpace: rootViewSpace(for: viewElement),
                            scrollMembership: context.parentScrollContainerPath.map {
                                InterfaceTree.ScrollMembership(containerPath: $0, index: nil)
                            }
                        )
                    )
                    return true
                },
                onContainer: { container, _, context, accumulator in
                    let membership = context.parentScrollContainerPath.map {
                        InterfaceTree.ScrollMembership(containerPath: $0, index: nil)
                    }
                    let viewContainer = viewContainersByPath[context.path] ?? container
                    accumulator.containers.append(
                        CapturedContainer(
                            path: context.path,
                            container: container,
                            viewSpace: rootViewSpace(for: viewContainer),
                            scrollMembership: membership
                        )
                    )
                    let childScrollContainerPath = scrollableContainerPaths.contains(context.path)
                        ? context.path
                        : context.parentScrollContainerPath
                    return CaptureTraversal(
                        path: context.path,
                        parentScrollContainerPath: childScrollContainerPath
                    )
                },
                descend: { context, childIndex in
                    CaptureTraversal(
                        path: context.path.appending(childIndex),
                        parentScrollContainerPath: context.parentScrollContainerPath
                    )
                }
            )
        }
        return (
            containers: accumulator.containers,
            elements: accumulator.elements.sorted { lhs, rhs in
                if lhs.traversalIndex != rhs.traversalIndex {
                    return lhs.traversalIndex < rhs.traversalIndex
                }
                return lhs.path < rhs.path
            }
        )
    }

    private static func rootViewSpace(
        for element: AccessibilityElement
    ) -> HeistElement.Geometry.ViewSpace {
        HeistElement.Geometry.ViewSpace.admit(
            ownerPath: .root,
            frame: try? ViewRect(validating: element.bhFrame),
            activationPoint: try? ViewPoint(validating: element.bhResolvedActivationPoint)
        )
    }

    private static func rootViewSpace(
        for container: AccessibilityContainer
    ) -> HeistElement.Geometry.ViewSpace {
        let frame = container.frame.cgRect
        return HeistElement.Geometry.ViewSpace.admit(
            ownerPath: .root,
            frame: try? ViewRect(validating: frame),
            activationPoint: try? ViewPoint(validating: CGPoint(x: frame.midX, y: frame.midY))
        )
    }

    // MARK: - Container Naming

    /// Compute a readable generated name prefix for a parser container, derived
    /// from the values the container itself exposes — role, identifier, semantic
    /// label — and never from its frame. A name is a single value with nothing to
    /// compare against, so the tolerance that makes frame *comparison* safe
    /// cannot make a frame-derived *name* safe: a container parked on a bucket
    /// edge would be renamed by a third of a point of layout noise. Container
    /// names are capture-local tree projections; `buildContainerNamesByPath`
    /// appends the container's tree path when several share this prefix in one
    /// parse.
    static func containerName(for container: AccessibilityContainer) -> ContainerName {
        let facts = container.containerPredicateFacts
        let identifierSuffix = facts.identifier.map { "_\($0)" } ?? ""
        switch facts.role {
        case .none where facts.isScrollable:
            return ContainerName(stringLiteral: "scrollable\(identifierSuffix)")
        case .none:
            return ContainerName(stringLiteral: "container_\(facts.identifier ?? "anon")")
        case .semanticGroup(let label, let value):
            let labelSlug = TheScore.slugify(label) ?? "anon"
            let valueSlug = TheScore.slugify(value) ?? ""
            let identifierSlug = facts.identifier ?? ""
            return ContainerName(stringLiteral: "semantic_\(identifierSlug)_\(labelSlug)_\(valueSlug)")
        case .list:
            return ContainerName(stringLiteral: "list\(identifierSuffix)")
        case .landmark:
            return ContainerName(stringLiteral: "landmark\(identifierSuffix)")
        case .tabBar:
            return ContainerName(stringLiteral: "tabBar\(identifierSuffix)")
        case .series:
            return ContainerName(stringLiteral: "series\(identifierSuffix)")
        case .dataTable(let rows, let columns):
            return ContainerName(stringLiteral: "table_\(rows)x\(columns)\(identifierSuffix)")
        }
    }

}

#endif // DEBUG
#endif // canImport(UIKit)
