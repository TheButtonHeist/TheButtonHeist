#if canImport(UIKit)
#if DEBUG
import UIKit

import ThePlans
import TheScore

import AccessibilitySnapshotParser

internal enum ScreenContinuity: Sendable, Equatable {
    internal enum ReplacementEvidence: Sendable, Equatable {
        internal enum InferenceReason: String, Sendable, Equatable {
            case modalBoundaryChanged
            case selectedTabChanged
            case navigationMarkerChanged
            case primaryHeaderChanged
            case semanticIdentityDisjoint
            case rootShapeChanged
        }

        case screenChangedNotification
        case inferred(InferenceReason)
    }

    case sameGeneration
    case replacement(ReplacementEvidence)

    internal var isReplacement: Bool {
        if case .replacement = self { return true }
        return false
    }

}

/// Why a reading differs from the one before it.
///
/// Screen identity is compared over the viewport alone, so a screen read at a
/// different scroll offset can share nothing with the last reading of itself.
/// This is what separates that from an actual navigation, and every reading
/// states one: "nothing moved" and "the viewport moved" are different facts,
/// and a reading that says neither leaves the classifier to guess.
internal enum ScreenLineage: Sendable, Equatable {
    /// Nothing moved the tree between the two readings.
    case resting
    /// The viewport moved and settled, so the content on screen is expected to
    /// differ while the screen stays the same.
    case viewportMovement
}

/// Classifies parsed accessibility snapshots.
///
/// Tripwire triggers parsing; this type is the single place that decides
/// whether the parsed result should be treated as a new screen. Same-screen
/// element and tree changes are derived from accessibility trace captures.
enum ScreenClassifier {

    struct Snapshot: Equatable {
        let signature: ScreenSignature
        let firstResponderHeistId: HeistId?
        let semanticElementIDs: Set<HeistId>
        let semanticScrollContainerIdentities: Set<SemanticScrollContainerIdentityBasis>
    }

    enum SemanticScrollContainerIdentityBasis: Equatable, Hashable {
        case identifier(String)
        case semanticGroup(label: String?, value: String?)
    }

    struct ScreenSignature: Equatable {
        let modalMarkers: [Marker]
        let primaryHeader: PrimaryHeader?
        let backButton: Marker?
        let selectedTabs: Set<Marker>
        let rootShape: [RootShapeComponent]
    }

    struct PrimaryHeader: Equatable {
        let label: String?
        let belongsToScrollableContent: Bool
    }

    struct Marker: Equatable, Hashable {
        let label: String?
        let value: String?
        let identifier: String?
    }

    struct RootShapeComponent: Equatable, Hashable {
        let kind: RootShapeKind
        let depth: Int
        let stableIdentifier: String?
        let attributes: RootShapeAttributes
    }

    enum RootShapeKind: Equatable, Hashable {
        case container(AccessibilityContainerKind)
        case element(ElementRootShapeRole)
    }

    enum ElementRootShapeRole: Equatable, Hashable {
        case backButton
        case header
        case tabBarItem
        case searchField
        case textEntry
        case button
        case link
        case adjustable
    }

    struct RootShapeAttributes: Equatable, Hashable {
        let isSelected: Bool
        let isModal: Bool
        let isScrollable: Bool
    }

    static func snapshot(of tree: InterfaceTree) -> Snapshot {
        let hierarchy = classificationHierarchy(tree.viewportCapture.hierarchy)
        return Snapshot(
            signature: signature(
                hierarchy: hierarchy,
                elements: hierarchy.sortedElements
            ),
            firstResponderHeistId: tree.firstResponderHeistId,
            semanticElementIDs: tree.viewportElementIDs,
            semanticScrollContainerIdentities: Set(
                hierarchy.pathIndexedContainers.compactMap {
                    semanticScrollContainerIdentity(for: $0.container)
                }
            )
        )
    }

    private static func classificationHierarchy(
        _ hierarchy: [AccessibilityHierarchy]
    ) -> [AccessibilityHierarchy] {
        var accumulator: Void = ()
        return hierarchy.compactMap { node in
            node.compactingElements(
                context: (),
                into: &accumulator,
                onElement: { element, traversalIndex, _, _ in
                    guard element.visibility == .onscreen else { return nil }
                    return .element(element, traversalIndex: traversalIndex)
                },
                onContainer: { _, _, _ in () },
                childContext: { _, _, _ in () }
            )
        }
    }

    @MainActor static func snapshot(of vault: TheVault) -> Snapshot {
        snapshot(of: vault.interfaceTree)
    }

    static func classify(
        from previousTree: InterfaceTree?,
        to tree: InterfaceTree,
        notifications: [AccessibilityNotificationKind],
        lineage: ScreenLineage
    ) -> ScreenContinuity {
        classify(
            before: previousTree.map(snapshot(of:)),
            after: snapshot(of: tree),
            notifications: notifications,
            lineage: lineage
        )
    }

    static func classify(
        before: Snapshot?,
        after: Snapshot,
        notifications: [AccessibilityNotificationKind],
        lineage: ScreenLineage
    ) -> ScreenContinuity {
        if notifications.contains(where: {
            if case .screenChanged = $0 { return true }
            return false
        }) {
            return .replacement(.screenChangedNotification)
        }
        if lineage == .viewportMovement {
            return .sameGeneration
        }
        guard let before else { return .sameGeneration }

        let beforeSignature = before.signature
        let afterSignature = after.signature
        let sharedFirstResponder = sharesFirstResponder(
            before: before,
            after: after
        )
        let sharedScrollContainer = sharesSemanticScrollContainer(before: before, after: after)
        let sameGenerationIsProven = sharedFirstResponder || sharedScrollContainer

        if beforeSignature.modalMarkers != afterSignature.modalMarkers {
            return .replacement(.inferred(.modalBoundaryChanged))
        }
        if beforeSignature.selectedTabs != afterSignature.selectedTabs {
            return .replacement(.inferred(.selectedTabChanged))
        }
        if beforeSignature.backButton != afterSignature.backButton {
            return .replacement(.inferred(.navigationMarkerChanged))
        }
        if beforeSignature.primaryHeader != afterSignature.primaryHeader,
           !sharedFirstResponder,
           !isScrollableContentHeaderChange(
               before: beforeSignature.primaryHeader,
               after: afterSignature.primaryHeader,
               sharingScrollContainer: sharedScrollContainer
           ) {
            return .replacement(.inferred(.primaryHeaderChanged))
        }
        if !before.semanticElementIDs.isEmpty,
           !after.semanticElementIDs.isEmpty,
           before.semanticElementIDs.isDisjoint(with: after.semanticElementIDs),
           !sameGenerationIsProven {
            return .replacement(.inferred(.semanticIdentityDisjoint))
        }
        if beforeSignature.rootShape != afterSignature.rootShape,
           !sameGenerationIsProven,
           isRootShapeReplacement(before: beforeSignature.rootShape, after: afterSignature.rootShape) {
            return .replacement(.inferred(.rootShapeChanged))
        }
        return .sameGeneration
    }

    static func signature(
        hierarchy: [AccessibilityHierarchy],
        elements: [AccessibilityElement]
    ) -> ScreenSignature {
        ScreenSignature(
            modalMarkers: modalMarkers(in: hierarchy),
            primaryHeader: primaryHeader(in: hierarchy, elements: elements),
            backButton: elements.first(where: isBackButton).map(marker(for:)),
            selectedTabs: selectedTabMarkers(in: hierarchy),
            rootShape: rootShapeComponents(in: hierarchy)
        )
    }

    private static func primaryHeader(
        in hierarchy: [AccessibilityHierarchy],
        elements: [AccessibilityElement]
    ) -> PrimaryHeader? {
        if let explicit = elements.first(where: { $0.traits.contains(.summaryElement) }) {
            return PrimaryHeader(label: explicit.label, belongsToScrollableContent: false)
        }
        let navigationHeaders: [AccessibilityElement] = hierarchy.compactMap(
            context: false,
            container: { isInsideScrollableContainer, container in
                isInsideScrollableContainer || container.isScrollable
            },
            element: { element, _, isInsideScrollableContainer -> AccessibilityElement? in
                guard !isInsideScrollableContainer,
                      element.traits.contains(.header) else { return nil }
                return element
            }
        )
        if let navigationHeader = navigationHeaders.first {
            return PrimaryHeader(label: navigationHeader.label, belongsToScrollableContent: false)
        }
        return elements.first { $0.traits.contains(.header) && $0.label != nil }.map {
            PrimaryHeader(label: $0.label, belongsToScrollableContent: true)
        }
    }

    private static func sharesFirstResponder(
        before: Snapshot,
        after: Snapshot
    ) -> Bool {
        guard let beforeResponder = before.firstResponderHeistId,
              let afterResponder = after.firstResponderHeistId
        else { return false }
        return beforeResponder == afterResponder
    }

    private static func sharesSemanticScrollContainer(
        before: Snapshot,
        after: Snapshot
    ) -> Bool {
        return !before.semanticScrollContainerIdentities.isDisjoint(
            with: after.semanticScrollContainerIdentities
        )
    }

    private static func isScrollableContentHeaderChange(
        before: PrimaryHeader?,
        after: PrimaryHeader?,
        sharingScrollContainer: Bool
    ) -> Bool {
        sharingScrollContainer
            && before?.belongsToScrollableContent == true
            && after?.belongsToScrollableContent == true
    }

    private static func semanticScrollContainerIdentity(
        for container: AccessibilityContainer
    ) -> SemanticScrollContainerIdentityBasis? {
        guard container.isScrollable else { return nil }
        let facts = container.containerPredicateFacts
        if let identifier = stableIdentifier(facts.identifier).flatMap(nonEmpty) {
            return .identifier(identifier)
        }
        guard case .semanticGroup(let label, let value) = facts.role else { return nil }
        let semanticLabel = label.flatMap(nonEmpty)
        let semanticValue = value.flatMap(nonEmpty)
        guard semanticLabel != nil || semanticValue != nil else { return nil }
        return .semanticGroup(label: semanticLabel, value: semanticValue)
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func marker(for element: AccessibilityElement) -> Marker {
        Marker(
            label: element.label,
            value: element.value,
            identifier: stableIdentifier(element.identifier)
        )
    }

    private static func marker(for container: AccessibilityContainer) -> Marker {
        let facts = container.containerPredicateFacts
        let identifier = stableIdentifier(facts.identifier)
        switch facts.role {
        case .none:
            return Marker(
                label: facts.isScrollable ? "scrollable" : "container",
                value: nil,
                identifier: identifier
            )
        case .semanticGroup(let label, let value):
            return Marker(label: label, value: value, identifier: identifier)
        case .list:
            return Marker(label: "list", value: nil, identifier: identifier)
        case .landmark:
            return Marker(label: "landmark", value: nil, identifier: identifier)
        case .dataTable(let rowCount, let columnCount):
            return Marker(label: "dataTable", value: "\(rowCount)x\(columnCount)", identifier: identifier)
        case .tabBar:
            return Marker(label: "tabBar", value: nil, identifier: identifier)
        case .series:
            return Marker(label: "series", value: nil, identifier: identifier)
        }
    }

    private static func stableIdentifier(_ identifier: String?) -> String? {
        guard let identifier, isStableIdentifier(identifier) else { return nil }
        return identifier
    }

    private static func modalMarkers(in hierarchy: [AccessibilityHierarchy]) -> [Marker] {
        hierarchy.containers.compactMap { container in
            container.isModalBoundary ? marker(for: container) : nil
        }
    }

    private static func selectedTabMarkers(in hierarchy: [AccessibilityHierarchy]) -> Set<Marker> {
        Set(hierarchy.compactMap(
            context: false,
            container: { isInTabBar, container in
                if case .tabBar = container.type { return true }
                return isInTabBar
            },
            element: { element, _, isInTabBar in
                guard isInTabBar, element.traits.contains(.selected) else { return nil }
                return marker(for: element)
            }
        ))
    }

    private static func rootShapeComponents(in hierarchy: [AccessibilityHierarchy]) -> [RootShapeComponent] {
        var components: [RootShapeComponent] = []
        let hasMultipleRootNodes = hierarchy.count > 1
        for node in hierarchy {
            node.foldedPreorder(
                context: 0,
                into: &components,
                onElement: { element, _, depth, components in
                    guard let role = structuralRole(of: element) else { return true }
                    components.append(
                        RootShapeComponent(
                            kind: .element(role),
                            depth: depth,
                            stableIdentifier: stableIdentifier(element.identifier),
                            attributes: RootShapeAttributes(
                                isSelected: element.traits.contains(.selected),
                                isModal: false,
                                isScrollable: false
                            )
                        )
                    )
                    return true
                },
                onContainer: { container, _, depth, components in
                    if isTransparentTopLevelWrapper(
                        container,
                        depth: depth,
                        hasMultipleRootNodes: hasMultipleRootNodes
                    ) {
                        return depth
                    }
                    let facts = container.containerPredicateFacts
                    components.append(
                        RootShapeComponent(
                            kind: .container(facts.role.kind),
                            depth: depth,
                            stableIdentifier: stableIdentifier(facts.identifier),
                            attributes: RootShapeAttributes(
                                isSelected: false,
                                isModal: facts.isModalBoundary,
                                isScrollable: facts.isScrollable
                            )
                        )
                    )
                    return depth + 1
                },
                descend: { depth, _ in depth }
            )
        }
        return components
    }

    private static func structuralRole(of element: AccessibilityElement) -> ElementRootShapeRole? {
        if isBackButton(element) { return .backButton }
        if element.traits.contains(.header) { return .header }
        if element.traits.contains(.tabBarItem) { return .tabBarItem }
        if element.traits.contains(.searchField) { return .searchField }
        if element.traits.contains(.textEntry) { return .textEntry }
        if element.traits.contains(.button) { return .button }
        if element.traits.contains(.link) { return .link }
        if element.traits.contains(.adjustable) { return .adjustable }
        return nil
    }

    private static func isBackButton(_ element: AccessibilityElement) -> Bool {
        element.traits.contains(.backButton)
    }

    private static func isTransparentTopLevelWrapper(
        _ container: AccessibilityContainer,
        depth: Int,
        hasMultipleRootNodes: Bool
    ) -> Bool {
        guard depth == 0, hasMultipleRootNodes, !container.isModalBoundary else { return false }
        guard case .semanticGroup = container.type else { return false }
        return stableIdentifier(container.containerPredicateFacts.identifier) == nil
    }

    private static func isRootShapeReplacement(before: [RootShapeComponent], after: [RootShapeComponent]) -> Bool {
        guard !before.isEmpty || !after.isEmpty else { return false }
        var afterCounts = after.reduce(into: [RootShapeComponent: Int]()) { counts, component in
            counts[component, default: 0] += 1
        }
        var matchedCount = 0
        for component in before {
            guard let count = afterCounts[component], count > 0 else { continue }
            matchedCount += 1
            afterCounts[component] = count - 1
        }
        let maxCount = max(before.count, after.count)
        let persistRatio = Double(matchedCount) / Double(maxCount)
        return persistRatio < AccessibilityPolicy.tabSwitchPersistThreshold
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
