#if canImport(UIKit)
#if DEBUG
import UIKit

import TheScore

import AccessibilitySnapshotParser

enum InventoryEnumeration {
    struct Result {
        let reportedCountsByContainerPath: [TreePath: Int?]
        let attemptedCount: Int
        let offscreenElements: [TheVault.OffscreenScrollElement]
        let knownUnattemptedCount: Int

        init(
            reportedCountsByContainerPath: [TreePath: Int?] = [:],
            attemptedCount: Int = 0,
            offscreenElements: [TheVault.OffscreenScrollElement] = [],
            knownUnattemptedCount: Int = 0
        ) {
            self.reportedCountsByContainerPath = reportedCountsByContainerPath
            self.attemptedCount = attemptedCount
            self.offscreenElements = offscreenElements
            self.knownUnattemptedCount = knownUnattemptedCount
        }
    }
}

extension TheVault {
    struct OffscreenScrollElement {
        let path: TreePath
        let scrollContainerPath: TreePath
        let scrollIndex: Int
        let element: AccessibilityElement
        let viewSpace: HeistElement.Geometry.ViewSpace
    }

    /// One capture-local tree with semantic values, path annotations, and live evidence.
    struct CaptureTree {
        struct RootScreenSpace {
            let offset: CGPoint
            let bounds: CGRect
        }

        let hierarchy: [AccessibilityHierarchy]
        let objectsByPath: [TreePath: NSObject]
        let containerObjectsByPath: [TreePath: NSObject]
        let scrollViewsByPath: [TreePath: UIScrollView]
        let inventoryEnumeration: InventoryEnumeration.Result
        let containers: [CapturedContainer]
        let elements: [CapturedElement]
        let scroll: ScrollFacts
        let focus: FocusFacts

        @MainActor
        init(
            hierarchy: [AccessibilityHierarchy],
            objectsByPath: [TreePath: NSObject] = [:],
            containerObjectsByPath: [TreePath: NSObject] = [:],
            scrollViewsByPath: [TreePath: UIScrollView] = [:],
            rootScreenSpacesByPath: [TreePath: RootScreenSpace] = [:],
            inventoryEnumeration: InventoryEnumeration.Result = .init(),
            scroll: ScrollFacts? = nil,
            focus: FocusFacts? = nil
        ) {
            func translated(
                _ hierarchy: AccessibilityHierarchy,
                at path: TreePath,
                inheritedScreenSpace: RootScreenSpace?
            ) -> AccessibilityHierarchy {
                let screenSpace = rootScreenSpacesByPath[path] ?? inheritedScreenSpace
                let offset = screenSpace?.offset ?? .zero
                switch hierarchy {
                case .element(let element, let traversalIndex):
                    return .element(
                        element.translatedBy(
                            x: offset.x,
                            y: offset.y,
                            screenBounds: screenSpace?.bounds
                        ),
                        traversalIndex: traversalIndex
                    )
                case .container(let container, let children):
                    return .container(
                        container.translatedBy(x: offset.x, y: offset.y),
                        children: children.enumerated().map { index, child in
                            translated(
                                child,
                                at: path.appending(index),
                                inheritedScreenSpace: screenSpace
                            )
                        }
                    )
                }
            }

            let screenHierarchy = hierarchy.enumerated().map { rootIndex, root in
                translated(
                    root,
                    at: TreePath([rootIndex]),
                    inheritedScreenSpace: nil
                )
            }
            let scrollableContainerPaths = scroll?.contextContainerPaths
                ?? TheVault.scrollContextContainerPaths(scrollViewsByPath: scrollViewsByPath)
            let annotations = TheVault.captureAnnotations(
                hierarchy: screenHierarchy,
                viewHierarchy: hierarchy,
                scrollableContainerPaths: scrollableContainerPaths
            )

            self.hierarchy = screenHierarchy
            self.objectsByPath = objectsByPath
            self.containerObjectsByPath = containerObjectsByPath
            self.scrollViewsByPath = scrollViewsByPath
            self.inventoryEnumeration = inventoryEnumeration
            self.containers = annotations.containers
            self.elements = annotations.elements
            self.scroll = scroll ?? TheVault.captureScrollFacts(
                elements: annotations.elements,
                containers: annotations.containers,
                scrollableContainerPaths: scrollableContainerPaths,
                objectsByPath: objectsByPath,
                scrollViewsByPath: scrollViewsByPath,
                reportedCountsByContainerPath: inventoryEnumeration.reportedCountsByContainerPath
            )
            self.focus = focus ?? TheVault.captureFocusFacts(objectsByPath: objectsByPath)
        }
    }

    private static let offscreenScrollInventoryPathIndexBase = 1_000_000

    // MARK: - Parse (read-only)

    /// Read the live accessibility tree without mutating any state.
    /// Returns capture-local evidence or nil if no accessible windows exist.
    func capture() -> CaptureTree? {
        let windows = tripwire.captureAccessibleWindows()
        guard !windows.isEmpty else { return nil }

        // Parse runs on the main thread (UIKit accessibility SPI). Retain only
        // opt-in diagnostics for captures that exceed the latency threshold.
        let parseStart = CFAbsoluteTimeGetCurrent()
        defer {
            let parseMs = Int((CFAbsoluteTimeGetCurrent() - parseStart) * 1000)
            if parseMs >= 100 {
                insideJobLogger.debug("TheVault.capture(): \(parseMs)ms (\(windows.count) window(s))")
            }
        }

        var allHierarchy: [AccessibilityHierarchy] = []
        var objectsByPath: [TreePath: NSObject] = [:]
        var containerObjectsByPath: [TreePath: NSObject] = [:]
        var scrollViewsByPath: [TreePath: UIScrollView] = [:]
        var rootScreenSpacesByPath: [TreePath: CaptureTree.RootScreenSpace] = [:]

        let isMultiWindow = windows.count > 1

        for entry in windows {
            let window = entry.window
            let rootView = entry.rootView
            let containsModalBoundary = autoreleasepool { () -> Bool in
                let captured = hierarchyParser.parseAccessibilityHierarchy(
                    in: rootView,
                    rotorResultLimit: 0,
                    makeElement: { element, traversalIndex, source in
                        CaptureNode.element(element, traversalIndex: traversalIndex, source: source)
                    },
                    makeContainer: { container, children, source in
                        CaptureNode.container(container, children: children, source: source)
                    }
                )

                let windowHierarchy = captured.map(\.hierarchy)

                // Collect live pointers at paths relative to their final position in
                // `allHierarchy`. In multi-window mode each window is wrapped in a synthetic
                // semantic-group container, so the window's roots sit one level deeper; that
                // wrapper carries no live source and is intentionally not collected.
                let rootPathPrefix: (Int) -> TreePath
                if isMultiWindow {
                    let wrapperIndex = allHierarchy.count
                    let windowName = NSStringFromClass(type(of: window))
                    let wrapper = AccessibilityContainer(
                        type: .semanticGroup(
                            label: windowName,
                            value: "windowLevel: \(window.windowLevel.rawValue)"
                        ),
                        frame: AccessibilityRect(window.frame)
                    )
                    allHierarchy.append(.container(wrapper, children: windowHierarchy))
                    rootPathPrefix = { localIndex in TreePath([wrapperIndex, localIndex]) }
                } else {
                    let offset = allHierarchy.count
                    allHierarchy.append(contentsOf: windowHierarchy)
                    rootPathPrefix = { localIndex in TreePath([offset + localIndex]) }
                }

                for (localIndex, root) in captured.enumerated() {
                    let rootPath = rootPathPrefix(localIndex)
                    rootScreenSpacesByPath[rootPath] = CaptureTree.RootScreenSpace(
                        offset: rootView.convert(.zero, to: nil),
                        bounds: window.windowScene?.screen.bounds ?? ScreenMetrics.current.bounds
                    )
                    Self.collect(
                        root,
                        at: rootPath,
                        objectsByPath: &objectsByPath,
                        containerObjectsByPath: &containerObjectsByPath,
                        scrollViewsByPath: &scrollViewsByPath
                    )
                }

                return captured.contains { $0.containsModalBoundary }
            }

            if containsModalBoundary {
                break
            }
        }

        let canonicalScrollViewsByPath = Self.canonicalScrollViewsByPath(
            from: scrollViewsByPath,
            containerObjectsByPath: containerObjectsByPath
        )
        let inventoryEnumeration = enumerateOffscreenScrollInventory(
            objectsByPath: objectsByPath,
            scrollViewsByPath: canonicalScrollViewsByPath
        )

        return CaptureTree(
            hierarchy: allHierarchy,
            objectsByPath: objectsByPath,
            containerObjectsByPath: containerObjectsByPath,
            scrollViewsByPath: canonicalScrollViewsByPath,
            rootScreenSpacesByPath: rootScreenSpacesByPath,
            inventoryEnumeration: inventoryEnumeration
        )
    }

    func enumerateOffscreenScrollInventory(
        objectsByPath: [TreePath: NSObject],
        scrollViewsByPath: [TreePath: UIScrollView],
        budget: Int = ButtonHeistRuntimeKnobs.current.visibleElementBudget
    ) -> InventoryEnumeration.Result {
        let admittedInventories = scrollViewsByPath
            .sorted(by: { $0.key < $1.key })
            .compactMap { path, scrollView -> (TreePath, UIScrollView, Int?)? in
                guard Self.admitsOffscreenInventory(from: scrollView) else { return nil }
                let reportedCount = scrollView.accessibilityElementCount()
                return (path, scrollView, reportedCount == NSNotFound || reportedCount < 0 ? nil : reportedCount)
            }
        let reportedCountsByContainerPath = Dictionary(
            uniqueKeysWithValues: admittedInventories.map { ($0.0, $0.2) }
        )
        var representedObjectIDs = Set(objectsByPath.values.map(ObjectIdentifier.init))
        var elements: [OffscreenScrollElement] = []
        var attemptedCount = 0
        var remainingRequests = max(0, budget)
        var knownUnattemptedCount = 0

        for (containerPath, scrollView, reportedCount) in admittedInventories {
            guard let count = reportedCount, count > 0 else { continue }

            for index in 0..<count {
                guard remainingRequests > 0 else {
                    knownUnattemptedCount = Self.saturatingSum(
                        knownUnattemptedCount,
                        count - index
                    )
                    break
                }
                remainingRequests -= 1
                attemptedCount += 1

                guard let object = scrollView.accessibilityElement(at: index) as? NSObject,
                      representedObjectIDs.insert(ObjectIdentifier(object)).inserted
                else { continue }

                guard let element = captureObject(object)?.withVisibility(.offscreen) else { continue }
                elements.append(OffscreenScrollElement(
                    path: containerPath.appending(Self.offscreenScrollInventoryPathIndexBase + index),
                    scrollContainerPath: containerPath,
                    scrollIndex: index,
                    element: element,
                    viewSpace: viewSpace(
                        for: element,
                        in: scrollView,
                        ownerPath: containerPath
                    )
                ))
            }
        }

        let result = InventoryEnumeration.Result(
            reportedCountsByContainerPath: reportedCountsByContainerPath,
            attemptedCount: attemptedCount,
            offscreenElements: elements,
            knownUnattemptedCount: knownUnattemptedCount
        )
        logBoundedInventoryEnumeration(result, budget: max(0, budget))
        return result
    }

    private static func admitsOffscreenInventory(from scrollView: UIScrollView) -> Bool {
        !(scrollView is UITableView) && !(scrollView is UICollectionView)
    }

    private static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private func logBoundedInventoryEnumeration(
        _ result: InventoryEnumeration.Result,
        budget: Int
    ) {
        guard result.knownUnattemptedCount > 0 else { return }
        insideJobLogger.debug(
            """
            Bounded offscreen accessibility inventory at budget \(budget, privacy: .public): \
            attempted \(result.attemptedCount, privacy: .public) request(s), \
            omitted \(result.knownUnattemptedCount, privacy: .public) known request(s).
            """
        )
    }

    private func viewSpace(
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

    private static func canonicalScrollViewsByPath(
        from scrollViewsByPath: [TreePath: UIScrollView],
        containerObjectsByPath: [TreePath: NSObject]
    ) -> [TreePath: UIScrollView] {
        let directlyOwnedScrollViews = Set(scrollViewsByPath.compactMap { path, scrollView in
            containerObjectsByPath[path] === scrollView ? ObjectIdentifier(scrollView) : nil
        })
        return scrollViewsByPath.filter { path, scrollView in
            !directlyOwnedScrollViews.contains(ObjectIdentifier(scrollView))
                || containerObjectsByPath[path] === scrollView
        }
    }

    /// Parse one live accessibility object by pumping it through the regular
    /// hierarchy parser with a temporary accessibility root. The object may be
    /// a custom rotor result that VoiceOver can focus even though it is not
    /// discoverable by walking the current app hierarchy.
    func captureObject(_ object: NSObject) -> AccessibilityElement? {
        let root = SingleElementParsingRoot(object: object)
        let captured = hierarchyParser.parseAccessibilityHierarchy(
            in: root,
            rotorResultLimit: 0,
            makeElement: { element, traversalIndex, source in
                CaptureNode.element(element, traversalIndex: traversalIndex, source: source)
            },
            makeContainer: { container, children, source in
                CaptureNode.container(container, children: children, source: source)
            }
        )
        if let match = captured.lazy.compactMap({ $0.firstElement(matchingSource: object) }).first {
            return match
        }
        return captured.map(\.hierarchy).sortedElements.first
    }

    /// Records the live source object for each element and container in a captured subtree, keyed
    /// by its `TreePath`. The path is assigned structurally during the descent, so duplicate
    /// element/container values at different positions never collide — there is no candidate
    /// reconciliation as there was with the visitor side channel.
    private static func collect(
        _ node: CaptureNode,
        at path: TreePath,
        objectsByPath: inout [TreePath: NSObject],
        containerObjectsByPath: inout [TreePath: NSObject],
        scrollViewsByPath: inout [TreePath: UIScrollView]
    ) {
        switch node {
        case let .element(_, _, source):
            objectsByPath[path] = source

        case let .container(container, children, source):
            containerObjectsByPath[path] = source
            if let scrollView = scrollDispatchView(for: container, source: source) {
                scrollViewsByPath[path] = scrollView
            }
            for (index, child) in children.enumerated() {
                collect(
                    child,
                    at: path.appending(index),
                    objectsByPath: &objectsByPath,
                    containerObjectsByPath: &containerObjectsByPath,
                    scrollViewsByPath: &scrollViewsByPath
                )
            }
        }
    }

    private static func scrollDispatchView(
        for container: AccessibilityContainer,
        source: NSObject
    ) -> UIScrollView? {
        guard let contentSize = container.scrollableContentSize,
              let sourceView = source as? UIView
        else { return nil }
        if let scrollView = sourceView as? UIScrollView {
            return scrollView
        }

        let expectedContentSize = contentSize.cgSize
        let candidates = ScrollViewHierarchySearch.descendantScrollViews(in: sourceView)
            .filter(\.isScrollEnabled)
        let contentSizeMatches = candidates.filter {
            ScrollViewHierarchySearch.contentSize($0.contentSize, matches: expectedContentSize)
        }
        if contentSizeMatches.count == 1 {
            return contentSizeMatches[0]
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

}

private final class SingleElementParsingRoot: UIView {
    private let elementObject: NSObject

    init(object: NSObject) {
        self.elementObject = object
        super.init(frame: ScreenMetrics.current.bounds)
        isAccessibilityElement = false
        accessibilityElements = [elementObject]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }
}

private extension AccessibilityElement {
    func withVisibility(_ visibility: AccessibilityVisibility) -> AccessibilityElement {
        AccessibilityElement(
            description: description,
            label: label,
            value: value,
            traits: traits,
            identifier: identifier,
            hint: hint,
            userInputLabels: userInputLabels,
            shape: shape,
            activationPoint: activationPoint,
            usesDefaultActivationPoint: usesDefaultActivationPoint,
            customActions: customActions,
            customContent: customContent,
            customRotors: customRotors,
            accessibilityLanguage: accessibilityLanguage,
            respondsToUserInteraction: respondsToUserInteraction,
            visibility: visibility
        )
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
