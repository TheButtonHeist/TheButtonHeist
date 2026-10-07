import Foundation

import AccessibilitySnapshotModel
import ThePlans
import TheScore

enum ProjectionCompleteness: String, Sendable {
    case full
    case truncated
}

struct InterfaceRenderingProjection: Sendable {
    let completeness: ProjectionCompleteness
    let reason: ProjectionOmissionReason?
    let observedElementCount: Int
    let renderedElementCount: Int
    let omittedElementCount: Int
    let visibleElementBudget: Int?
    let totalNodeBudget: Int?
}

struct InterfaceSubtreeTruncationProjection: Sendable {
    let reason: ProjectionOmissionReason
    let observedElementCount: Int
    let renderedElementCount: Int
    let omittedElementCount: Int
    let visibleElementBudget: Int
}

struct InterfaceNavigationProjection: Sendable {
    let screenTitle: String?
    let backButton: NavigationItemProjection?
    let tabBarItems: [TabBarItemProjection]

    init(screenTitle: String?, elements: [HeistElement]) {
        self.screenTitle = screenTitle
        backButton = elements
            .first(where: { $0.semantics.assertable.traits.contains(.backButton) })
            .map(NavigationItemProjection.init(element:))
        tabBarItems = elements
            .filter { $0.semantics.assertable.traits.contains(.tabBarItem) }
            .map(TabBarItemProjection.init(element:))
    }
}

struct NavigationItemProjection: Sendable {
    let label: String?
    let value: String?

    init(element: HeistElement) {
        label = element.semantics.assertable.label
        value = element.semantics.assertable.value
    }
}

struct TabBarItemProjection: Sendable {
    let label: String?
    let value: String?
    let selected: Bool

    init(element: HeistElement) {
        label = element.semantics.assertable.label
        value = element.semantics.assertable.value
        selected = element.semantics.assertable.traits.contains(.selected)
    }
}

struct InterfaceElementProjection: Sendable {
    let element: HeistElement
    let detail: InterfaceDetail
    let order: Int?
    let target: AccessibilityTarget?
}

struct InterfaceContainerProjection: Sendable {
    let container: AccessibilityContainer
    let detail: InterfaceDetail
    let containerName: String?
    let scrollInventory: ScrollInventory?
    let observedElementCount: Int
    let truncation: InterfaceSubtreeTruncationProjection?
    let children: [InterfaceNodeProjection]
}

indirect enum InterfaceNodeProjection: Sendable {
    case element(InterfaceElementProjection)
    case container(InterfaceContainerProjection)
}

struct InterfaceProjection: Sendable {
    let timestamp: Date
    let detail: InterfaceDetail
    let screenDescription: String
    let screenId: String?
    let screenActions: [ScreenAction]
    let diagnostics: InterfaceDiagnostics?
    let navigation: InterfaceNavigationProjection
    let rendering: InterfaceRenderingProjection
    let tree: [InterfaceNodeProjection]
    let elementCount: Int

    init(
        interface: Interface,
        detail: InterfaceDetail,
        visibleElementBudget: Int = ButtonHeistRuntimeKnobs.current.visibleElementBudget,
        totalNodeBudget: Int = ButtonHeistRuntimeKnobs.current.totalNodeBudget
    ) {
        self.init(
            interface: interface,
            profile: ProjectionProfile(
                kind: detail == .full ? .full : .summary,
                limits: .current(
                    visibleElementBudget: visibleElementBudget,
                    totalNodeBudget: totalNodeBudget
                )
            )
        )
    }

    init(interface: Interface, profile: ProjectionProfile) {
        let graph = interface.graph
        let elementRecords = graph.elementsInTraversalOrder
        let projectedElements = elementRecords.map(\.projectedElement)
        let screenTitle = InterfaceSummary.screenTitle(forProjectedElements: projectedElements)
        let projectedScreenId = InterfaceSummary.screenId(forProjectedElements: projectedElements)
        let targetContext = PredicateSelectionContext(
            elements: projectedElements.enumerated().map { offset, element in
                PredicateSelectionContext.Element(
                    id: PredicateSelectionElementId(rawValue: String(offset)),
                    element: element
                )
            },
            screenId: projectedScreenId,
            scope: .visible
        )

        timestamp = interface.timestamp
        detail = profile.interfaceDetail
        screenDescription = InterfaceSummary.screenDescription(forProjectedElements: projectedElements)
        screenId = projectedScreenId
        screenActions = interface.screenActions
        diagnostics = interface.diagnostics
        navigation = InterfaceNavigationProjection(screenTitle: screenTitle, elements: projectedElements)
        elementCount = elementRecords.count

        var reducer = InterfaceProjectionReducer(
            graph: graph,
            detail: detail,
            targetContext: targetContext,
            visibleElementBudget: profile.limits.visibleElementBudget,
            totalNodeBudget: profile.limits.totalNodeBudget
        )
        tree = reducer.projectTree()
        rendering = reducer.rendering(
            observedElementCount: elementCount,
            visibleElementBudget: profile.limits.visibleElementBudget,
            totalNodeBudget: profile.limits.totalNodeBudget
        )
    }
}

private struct InterfaceProjectionReducer {
    private let graph: InterfaceGraph
    private let detail: InterfaceDetail
    private let targetContext: PredicateSelectionContext
    private let visibleElementBudget: Int
    private let measurements: InterfaceProjectionMeasurements
    private let inventoryAdmissionDecisions: [TreePath: InventoryProjectionAdmission.Decision]

    private var accumulator: InterfaceProjectionAccumulator
    private var rootChildren: [InterfaceNodeProjection] = []
    private var containerFrames: [InterfaceContainerProjectionFrame] = []
    private var suppressedSubtreePath: TreePath?
    private var elementOrder = 0

    init(
        graph: InterfaceGraph,
        detail: InterfaceDetail,
        targetContext: PredicateSelectionContext,
        visibleElementBudget: Int,
        totalNodeBudget: Int
    ) {
        self.graph = graph
        self.detail = detail
        self.targetContext = targetContext
        self.visibleElementBudget = visibleElementBudget
        measurements = InterfaceProjectionMeasurements(nodes: graph.nodesInPathOrder)
        inventoryAdmissionDecisions = InventoryProjectionAdmission.decisions(
            nodes: graph.nodesInPathOrder,
            budget: visibleElementBudget
        )
        accumulator = InterfaceProjectionAccumulator(totalNodeBudget: totalNodeBudget)
    }

    mutating func projectTree() -> [InterfaceNodeProjection] {
        for record in graph.nodesInPathOrder {
            closeContainers(outside: record.path)

            if let suppressedSubtreePath,
               record.path.hasPrefix(suppressedSubtreePath) {
                if case .element = record.kind {
                    elementOrder += 1
                }
                continue
            }
            suppressedSubtreePath = nil

            switch record.kind {
            case .element(let element):
                project(element)
            case .container(let container):
                begin(container)
            }
        }
        closeContainers(outside: nil)
        return rootChildren
    }

    func rendering(
        observedElementCount: Int,
        visibleElementBudget: Int,
        totalNodeBudget: Int
    ) -> InterfaceRenderingProjection {
        accumulator.rendering(
            observedElementCount: observedElementCount,
            visibleElementBudget: visibleElementBudget,
            totalNodeBudget: totalNodeBudget
        )
    }

    private mutating func project(_ record: InterfaceGraphElementRecord) {
        let order = elementOrder
        elementOrder += 1
        if let remainingElementBudget, remainingElementBudget <= 0 {
            return
        }
        guard accumulator.consumeNode() else { return }
        if let remainingElementBudget {
            self.remainingElementBudget = remainingElementBudget - 1
        }
        accumulator.recordRenderedElement()
        append(.element(InterfaceElementProjection(
            element: record.projectedElement,
            detail: detail,
            order: order,
            target: minimumTarget(at: order)
        )))
    }

    private func minimumTarget(at order: Int) -> AccessibilityTarget? {
        MinimumPredicateSelector.minimumUniquePredicate(
            for: PredicateSelectionElementId(rawValue: String(order)),
            in: targetContext
        )?.target
    }

    private mutating func begin(_ record: InterfaceGraphContainerRecord) {
        if let remainingElementBudget, remainingElementBudget <= 0 {
            suppressedSubtreePath = record.path
            return
        }
        guard accumulator.consumeNode() else {
            suppressedSubtreePath = record.path
            return
        }

        let materializedElementCount = measurements.elementCount(at: record.path)
        let scrollInventory = record.annotation?.scrollInventory
        let observedElementCount = max(
            materializedElementCount,
            scrollInventory?.totalElementCount ?? materializedElementCount
        )
        let scrollPolicy = ScrollSubtreeProjectionPolicy(
            container: record.container,
            observedElementCount: observedElementCount,
            inventoryAdmissionDecision: inventoryAdmissionDecisions[record.path],
            visibleElementBudget: visibleElementBudget,
            parentRemainingElementBudget: remainingElementBudget
        )
        containerFrames.append(InterfaceContainerProjectionFrame(
            path: record.path,
            container: record.container,
            containerName: record.annotation?.containerName?.rawValue,
            scrollInventory: scrollInventory,
            observedElementCount: observedElementCount,
            scrollPolicy: scrollPolicy,
            remainingElementBudget: scrollPolicy.childRemainingElementBudget
        ))
    }

    private mutating func closeContainers(outside path: TreePath?) {
        while let frame = containerFrames.last,
              path.map({ !$0.hasPrefix(frame.path) }) ?? true {
            closeContainer()
        }
    }

    private mutating func closeContainer() {
        let frame = containerFrames.removeLast()
        let parentRemainingElementBudget = frame.scrollPolicy.parentRemainingElementBudget(
            after: frame.remainingElementBudget
        )
        if !containerFrames.isEmpty {
            containerFrames[containerFrames.count - 1].remainingElementBudget = parentRemainingElementBudget
        } else {
            precondition(parentRemainingElementBudget == nil, "top-level projection budget must be unbounded")
        }
        let truncation = frame.scrollPolicy.truncation(
            after: frame.remainingElementBudget,
            accumulator: &accumulator
        )
        append(.container(InterfaceContainerProjection(
            container: frame.container,
            detail: detail,
            containerName: frame.containerName,
            scrollInventory: frame.scrollInventory,
            observedElementCount: frame.observedElementCount,
            truncation: truncation,
            children: frame.children
        )))
    }

    private mutating func append(_ node: InterfaceNodeProjection) {
        guard !containerFrames.isEmpty else {
            rootChildren.append(node)
            return
        }
        containerFrames[containerFrames.count - 1].children.append(node)
    }

    private var remainingElementBudget: Int? {
        get { containerFrames.last?.remainingElementBudget }
        set {
            precondition(!containerFrames.isEmpty, "top-level projection budget must be unbounded")
            containerFrames[containerFrames.count - 1].remainingElementBudget = newValue
        }
    }
}

private struct InventoryProjectionAdmission {
    enum Decision {
        case complete
        case omittedKnownElements
    }

    private var remainingRequests: Int

    init(budget: Int) {
        remainingRequests = max(0, budget)
    }

    mutating func admit(elementCount: Int) -> Decision {
        let admittedCount = min(elementCount, remainingRequests)
        remainingRequests -= admittedCount
        return admittedCount == elementCount ? .complete : .omittedKnownElements
    }

    static func decisions(
        nodes: [InterfaceGraphNodeRecord],
        budget: Int
    ) -> [TreePath: Decision] {
        var admission = Self(budget: budget)
        var decisions: [TreePath: Decision] = [:]
        for record in nodes {
            guard case .container(let container) = record.kind,
                  let elementCount = container.annotation?.scrollInventory?.totalElementCount
            else { continue }
            decisions[record.path] = admission.admit(elementCount: elementCount)
        }
        return decisions
    }
}

private struct InterfaceProjectionMeasurements {
    private let elementCountByPath: [TreePath: Int]

    init(nodes: [InterfaceGraphNodeRecord]) {
        var elementCountByPath: [TreePath: Int] = [:]
        for record in nodes.reversed() {
            let elementCount: Int
            switch record.kind {
            case .element:
                elementCount = 1
            case .container:
                elementCount = elementCountByPath[record.path, default: 0]
            }
            elementCountByPath[record.path] = elementCount
            if let parent = record.path.parent {
                elementCountByPath[parent, default: 0] += elementCount
            }
        }
        self.elementCountByPath = elementCountByPath
    }

    func elementCount(at path: TreePath) -> Int {
        guard let elementCount = elementCountByPath[path] else {
            preconditionFailure("InterfaceProjection missing measured path \(path.indices)")
        }
        return elementCount
    }
}

private struct InterfaceContainerProjectionFrame {
    let path: TreePath
    let container: AccessibilityContainer
    let containerName: String?
    let scrollInventory: ScrollInventory?
    let observedElementCount: Int
    let scrollPolicy: ScrollSubtreeProjectionPolicy
    var remainingElementBudget: Int?
    var children: [InterfaceNodeProjection] = []
}

private struct ScrollSubtreeProjectionPolicy {
    let observedElementCount: Int
    let visibleElementBudget: Int
    let parentRemainingElementBudget: Int?
    let isActive: Bool
    private let inventoryAdmissionOmittedKnownElements: Bool

    init(
        container: AccessibilityContainer,
        observedElementCount: Int,
        inventoryAdmissionDecision: InventoryProjectionAdmission.Decision?,
        visibleElementBudget: Int,
        parentRemainingElementBudget: Int?
    ) {
        let admittedVisibleElementBudget = max(0, visibleElementBudget)
        self.observedElementCount = observedElementCount
        self.visibleElementBudget = admittedVisibleElementBudget
        self.parentRemainingElementBudget = parentRemainingElementBudget
        inventoryAdmissionOmittedKnownElements = inventoryAdmissionDecision == .omittedKnownElements
        isActive = Self.isScrollable(container) && (
            observedElementCount > admittedVisibleElementBudget || inventoryAdmissionOmittedKnownElements
        )
    }

    var childRemainingElementBudget: Int? {
        guard isActive else { return parentRemainingElementBudget }
        return effectiveElementBudget
    }

    func parentRemainingElementBudget(after remainingElementBudget: Int?) -> Int? {
        guard isActive else { return remainingElementBudget }
        guard let parentRemainingElementBudget else { return nil }
        return max(0, parentRemainingElementBudget - renderedElementCount(after: remainingElementBudget))
    }

    func truncation(
        after remainingElementBudget: Int?,
        accumulator: inout InterfaceProjectionAccumulator
    ) -> InterfaceSubtreeTruncationProjection? {
        guard isActive else { return nil }

        let renderedElementCount = renderedElementCount(after: remainingElementBudget)
        let omittedElementCount = max(0, observedElementCount - renderedElementCount)
        let scrollBudgetHit = (remainingElementBudget ?? 0) <= 0
        guard scrollBudgetHit || inventoryAdmissionOmittedKnownElements,
              omittedElementCount > 0
        else { return nil }

        accumulator.recordTruncatedScrollContainer()
        return InterfaceSubtreeTruncationProjection(
            reason: .scrollSubtreeElementBudget,
            observedElementCount: observedElementCount,
            renderedElementCount: renderedElementCount,
            omittedElementCount: omittedElementCount,
            visibleElementBudget: visibleElementBudget
        )
    }

    private var effectiveElementBudget: Int {
        min(parentRemainingElementBudget ?? visibleElementBudget, visibleElementBudget)
    }

    private func renderedElementCount(after remainingElementBudget: Int?) -> Int {
        max(0, effectiveElementBudget - (remainingElementBudget ?? 0))
    }

    private static func isScrollable(_ container: AccessibilityContainer) -> Bool {
        container.scrollableContentSize != nil
    }
}

private struct InterfaceProjectionAccumulator {
    private(set) var renderedElementCount = 0
    private(set) var truncatedScrollContainerCount = 0
    private(set) var remainingNodeBudget: Int
    private(set) var nodeLimitHit = false

    init(totalNodeBudget: Int) {
        remainingNodeBudget = max(0, totalNodeBudget)
    }

    mutating func recordRenderedElement() {
        renderedElementCount += 1
    }

    mutating func recordTruncatedScrollContainer() {
        truncatedScrollContainerCount += 1
    }

    mutating func consumeNode() -> Bool {
        guard remainingNodeBudget > 0 else {
            nodeLimitHit = true
            return false
        }
        remainingNodeBudget -= 1
        return true
    }

    func rendering(
        observedElementCount: Int,
        visibleElementBudget: Int,
        totalNodeBudget: Int
    ) -> InterfaceRenderingProjection {
        let omittedElementCount = max(0, observedElementCount - renderedElementCount)
        guard truncatedScrollContainerCount > 0 || omittedElementCount > 0 || nodeLimitHit else {
            return InterfaceRenderingProjection(
                completeness: .full,
                reason: nil,
                observedElementCount: observedElementCount,
                renderedElementCount: renderedElementCount,
                omittedElementCount: 0,
                visibleElementBudget: nil,
                totalNodeBudget: nil
            )
        }

        return InterfaceRenderingProjection(
            completeness: .truncated,
            reason: nodeLimitHit ? .totalNodeBudget : .scrollSubtreeElementBudget,
            observedElementCount: observedElementCount,
            renderedElementCount: renderedElementCount,
            omittedElementCount: omittedElementCount,
            visibleElementBudget: truncatedScrollContainerCount > 0 ? max(0, visibleElementBudget) : nil,
            totalNodeBudget: nodeLimitHit ? max(0, totalNodeBudget) : nil
        )
    }
}
