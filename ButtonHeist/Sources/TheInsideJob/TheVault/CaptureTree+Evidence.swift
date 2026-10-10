#if canImport(UIKit)
#if DEBUG
import UIKit

import TheScore
import ThePlans

import AccessibilitySnapshotParser

extension TheVault {

    struct ElementScrollFacts: Equatable {
        let membership: InterfaceTree.ScrollMembership
        let viewSpace: HeistElement.Geometry.ViewSpace

        init(
            containerPath: TreePath,
            index: Int? = nil,
            viewSpace: HeistElement.Geometry.ViewSpace
        ) {
            self.init(
                membership: InterfaceTree.ScrollMembership(containerPath: containerPath, index: index),
                viewSpace: viewSpace
            )
        }

        init(
            membership: InterfaceTree.ScrollMembership,
            viewSpace: HeistElement.Geometry.ViewSpace
        ) {
            self.membership = membership
            self.viewSpace = viewSpace
        }
    }

    struct ScrollFacts: Equatable {
        let contextContainerPaths: Set<TreePath>
        let elementsByPath: [TreePath: ElementScrollFacts]
        let containerViewSpacesByPath: [TreePath: HeistElement.Geometry.ViewSpace]
        let inventoriesByPath: [TreePath: ScrollInventory]

        init(
            contextContainerPaths: Set<TreePath> = [],
            elementsByPath: [TreePath: ElementScrollFacts] = [:],
            containerViewSpacesByPath: [TreePath: HeistElement.Geometry.ViewSpace] = [:],
            inventoriesByPath: [TreePath: ScrollInventory] = [:]
        ) {
            self.contextContainerPaths = contextContainerPaths
            self.elementsByPath = elementsByPath
            self.containerViewSpacesByPath = containerViewSpacesByPath
            self.inventoriesByPath = inventoriesByPath
        }

        func element(at path: TreePath) -> ElementScrollFacts? {
            elementsByPath[path]
        }
    }

    struct FocusFacts: Equatable {
        let firstResponderPaths: Set<TreePath>

        init(firstResponderPaths: Set<TreePath> = []) {
            self.firstResponderPaths = firstResponderPaths
        }

        func isFirstResponder(at path: TreePath) -> Bool {
            firstResponderPaths.contains(path)
        }
    }

}

@MainActor
extension TheVault {

    /// UIKit boundary for observation-building facts. Keep Objective-C accessibility
    /// inventory/index reads, responder checks, scroll safety checks, and
    /// coordinate conversion here rather than in projection.
    static func captureScrollFacts(
        elements: [CapturedElement],
        containers: [CapturedContainer],
        scrollableContainerPaths: Set<TreePath>,
        objectsByPath: [TreePath: NSObject],
        scrollViewsByPath: [TreePath: UIScrollView],
        reportedCountsByContainerPath: [TreePath: Int?]
    ) -> ScrollFacts {
        let elementScrollFacts = elementScrollFacts(
            elements: elements,
            objectsByPath: objectsByPath,
            scrollViewsByPath: scrollViewsByPath
        )

        return ScrollFacts(
            contextContainerPaths: scrollableContainerPaths,
            elementsByPath: elementScrollFacts,
            containerViewSpacesByPath: containerViewSpaces(
                containers: containers,
                scrollViewsByPath: scrollViewsByPath
            ),
            inventoriesByPath: scrollInventories(
                scrollViewsByPath: scrollViewsByPath,
                reportedCountsByContainerPath: reportedCountsByContainerPath
            )
        )
    }

    static func scrollContextContainerPaths(
        scrollViewsByPath: [TreePath: UIScrollView]
    ) -> Set<TreePath> {
        Set(
            scrollViewsByPath.compactMap { path, scrollView in
                scrollView.bhIsUnsafeForProgrammaticScrolling ? nil : path
            }
        )
    }

    static func captureFocusFacts(objectsByPath: [TreePath: NSObject]) -> FocusFacts {
        FocusFacts(firstResponderPaths: Set(
            objectsByPath.compactMap { path, object in
                (object as? UIView)?.isFirstResponder == true ? path : nil
            }
        ))
    }

    private static func elementScrollFacts(
        elements: [CapturedElement],
        objectsByPath: [TreePath: NSObject],
        scrollViewsByPath: [TreePath: UIScrollView]
    ) -> [TreePath: ElementScrollFacts] {
        var elementsByPath: [TreePath: ElementScrollFacts] = [:]

        for identity in elements {
            guard let membership = identity.scrollMembership,
                  let scrollView = scrollViewsByPath[membership.containerPath]
            else { continue }

            let index = scrollIndex(of: objectsByPath[identity.path], in: scrollView)
            elementsByPath[identity.path] = ElementScrollFacts(
                membership: InterfaceTree.ScrollMembership(
                    containerPath: membership.containerPath,
                    index: index
                ),
                viewSpace: viewSpace(
                    for: identity.element,
                    in: scrollView,
                    ownerPath: membership.containerPath
                )
            )
        }

        return elementsByPath
    }

    private static func scrollInventories(
        scrollViewsByPath: [TreePath: UIScrollView],
        reportedCountsByContainerPath: [TreePath: Int?]
    ) -> [TreePath: ScrollInventory] {
        Dictionary(
            uniqueKeysWithValues: scrollViewsByPath.keys.compactMap { path in
                guard let inventory = ScrollInventory(
                    totalElementCount: reportedCountsByContainerPath[path] ?? nil
                ) else { return nil }
                return (path, inventory)
            }
        )
    }

    private static func scrollIndex(of object: NSObject?, in scrollView: UIScrollView) -> Int? {
        guard let object else { return nil }
        let index = scrollView.index(ofAccessibilityElement: object)
        guard index != NSNotFound, index >= 0 else { return nil }
        return index
    }

    private static func viewSpace(
        for element: AccessibilityElement,
        in scrollView: UIScrollView,
        ownerPath: TreePath
    ) -> HeistElement.Geometry.ViewSpace {
        HeistElement.Geometry.ViewSpace.admit(
            ownerPath: ownerPath,
            frame: try? ViewRect(validating: scrollView.convert(element.bhFrame, from: nil)),
            activationPoint: try? ViewPoint(validating: scrollView.convert(
                element.bhResolvedActivationPoint,
                from: nil
            ))
        )
    }

    private static func containerViewSpaces(
        containers: [CapturedContainer],
        scrollViewsByPath: [TreePath: UIScrollView]
    ) -> [TreePath: HeistElement.Geometry.ViewSpace] {
        Dictionary(
            uniqueKeysWithValues: containers.compactMap { identity in
                guard let membership = identity.scrollMembership,
                      let scrollView = scrollViewsByPath[membership.containerPath]
                else { return nil }
                let frame = identity.container.frame.cgRect
                let activationPoint = CGPoint(x: frame.midX, y: frame.midY)
                return (
                    identity.path,
                    HeistElement.Geometry.ViewSpace.admit(
                        ownerPath: membership.containerPath,
                        frame: try? ViewRect(validating: scrollView.convert(frame, from: nil)),
                        activationPoint: try? ViewPoint(validating: scrollView.convert(
                            activationPoint,
                            from: nil
                        ))
                    )
                )
            }
        )
    }

}

#endif // DEBUG
#endif // canImport(UIKit)
