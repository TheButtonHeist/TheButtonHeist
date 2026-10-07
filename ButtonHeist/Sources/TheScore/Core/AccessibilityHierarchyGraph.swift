import AccessibilitySnapshotModel
import ThePlans

package struct AccessibilityNodeRecord: Equatable, Sendable {
    package let path: TreePath
    package let node: AccessibilityHierarchy
    package let traversalIndex: Int?
}

package struct AccessibilityHierarchyGraph: Equatable, Sendable {
    package let nodesInPathOrder: [AccessibilityNodeRecord]

    private let nodesByPath: [TreePath: AccessibilityHierarchy]

    package init(tree: [AccessibilityHierarchy]) {
        let nodesInPathOrder: [AccessibilityNodeRecord] = tree.compactMapSubtrees { node, path in
            switch node {
            case .element(_, let traversalIndex):
                AccessibilityNodeRecord(
                    path: path,
                    node: node,
                    traversalIndex: traversalIndex
                )
            case .container:
                AccessibilityNodeRecord(
                    path: path,
                    node: node,
                    traversalIndex: nil
                )
            }
        }
        let nodesByPath = Dictionary(uniqueKeysWithValues: nodesInPathOrder.map { ($0.path, $0.node) })

        self.nodesInPathOrder = nodesInPathOrder
        self.nodesByPath = nodesByPath
    }

    package func node(at path: TreePath) -> AccessibilityHierarchy? {
        nodesByPath[path]
    }
}

package enum InterfaceGraphValidationError: Error, Equatable, CustomStringConvertible {
    case duplicateElementAnnotationPath(TreePath)
    case duplicateContainerAnnotationPath(TreePath)
    case missingElementAnnotation(TreePath)
    case elementAnnotationForMissingPath(TreePath)
    case elementAnnotationForContainerPath(TreePath)
    case containerAnnotationForMissingPath(TreePath)
    case containerAnnotationForElementPath(TreePath)
    case observationIdentityForMissingPath(TreePath)
    case observationIdentityForContainerPath(TreePath)

    package var description: String {
        switch self {
        case .duplicateElementAnnotationPath(let path):
            return "duplicate element annotation path \(path.diagnosticDescription)"
        case .duplicateContainerAnnotationPath(let path):
            return "duplicate container annotation path \(path.diagnosticDescription)"
        case .missingElementAnnotation(let path):
            return "element at path \(path.diagnosticDescription) is missing its annotation"
        case .elementAnnotationForMissingPath(let path):
            return "element annotation references missing path \(path.diagnosticDescription)"
        case .elementAnnotationForContainerPath(let path):
            return "element annotation references container path \(path.diagnosticDescription)"
        case .containerAnnotationForMissingPath(let path):
            return "container annotation references missing path \(path.diagnosticDescription)"
        case .containerAnnotationForElementPath(let path):
            return "container annotation references element path \(path.diagnosticDescription)"
        case .observationIdentityForMissingPath(let path):
            return "observation identity references missing path \(path.diagnosticDescription)"
        case .observationIdentityForContainerPath(let path):
            return "observation identity references container path \(path.diagnosticDescription)"
        }
    }
}

package struct InterfaceGraphElementRecord: Equatable, Sendable {
    package let path: TreePath
    package let traversalIndex: Int
    package let accessibilityElement: AccessibilityElement
    package let annotation: InterfaceElementAnnotation
    package let observationIdentity: Observation.ElementIdentity?

    package init(
        path: TreePath,
        traversalIndex: Int,
        accessibilityElement: AccessibilityElement,
        annotation: InterfaceElementAnnotation,
        observationIdentity: Observation.ElementIdentity?
    ) {
        self.path = path
        self.traversalIndex = traversalIndex
        self.accessibilityElement = accessibilityElement
        self.annotation = annotation
        self.observationIdentity = observationIdentity
    }

    package var projectedElement: HeistElement {
        HeistElement(
            accessibilityElement: accessibilityElement,
            actions: annotation.actions,
            geometry: annotation.geometry
        )
    }

    package var interfaceRecord: InterfaceElementRecord {
        InterfaceElementRecord(
            path: path,
            traversalIndex: traversalIndex,
            element: projectedElement,
            observationIdentity: observationIdentity
        )
    }
}

package struct InterfaceGraphContainerRecord: Equatable, Sendable {
    package let path: TreePath
    package let container: AccessibilityContainer
    package let annotation: InterfaceContainerAnnotation?

    package init(
        path: TreePath,
        container: AccessibilityContainer,
        annotation: InterfaceContainerAnnotation?
    ) {
        self.path = path
        self.container = container
        self.annotation = annotation
    }
}

package enum InterfaceGraphNodeKind: Equatable, Sendable {
    case element(InterfaceGraphElementRecord)
    case container(InterfaceGraphContainerRecord)
}

package struct InterfaceGraphNodeRecord: Equatable, Sendable {
    package let path: TreePath
    package let node: AccessibilityHierarchy
    package let traversalIndex: Int?
    package let kind: InterfaceGraphNodeKind

    package init(
        path: TreePath,
        node: AccessibilityHierarchy,
        traversalIndex: Int?,
        kind: InterfaceGraphNodeKind
    ) {
        self.path = path
        self.node = node
        self.traversalIndex = traversalIndex
        self.kind = kind
    }
}

package struct InterfaceGraph: Equatable, Sendable {
    package let hierarchy: AccessibilityHierarchyGraph
    package let elementAnnotationByPath: [TreePath: InterfaceElementAnnotation]
    package let containerAnnotationByPath: [TreePath: InterfaceContainerAnnotation]
    package let observationIdentityByPath: [TreePath: Observation.ElementIdentity]
    package let elementsInTraversalOrder: [InterfaceGraphElementRecord]
    package let nodesInPathOrder: [InterfaceGraphNodeRecord]

    private let elementRecordByPath: [TreePath: InterfaceGraphElementRecord]

    package init(
        tree: [AccessibilityHierarchy],
        annotations: InterfaceAnnotations,
        observationIdentities: InterfaceElementIdentities = .empty
    ) throws(InterfaceGraphValidationError) {
        let hierarchy = AccessibilityHierarchyGraph(tree: tree)
        let elementAnnotationByPath = try Self.uniqueElementAnnotations(annotations.elements)
        let containerAnnotationByPath = try Self.uniqueContainerAnnotations(annotations.containers)
        let observationIdentityByPath = observationIdentities.byPath

        try Self.validateElementAnnotations(elementAnnotationByPath, in: hierarchy)
        try Self.validateContainerAnnotations(containerAnnotationByPath, in: hierarchy)
        try Self.validateObservationIdentities(observationIdentityByPath, in: hierarchy)

        let nodeRecords = try Self.nodeRecords(
            hierarchy: hierarchy,
            elementAnnotationByPath: elementAnnotationByPath,
            containerAnnotationByPath: containerAnnotationByPath,
            observationIdentityByPath: observationIdentityByPath
        )
        let elementRecords = nodeRecords.compactMap { record -> InterfaceGraphElementRecord? in
            guard case .element(let element) = record.kind else { return nil }
            return element
        }.sorted {
            if $0.traversalIndex != $1.traversalIndex {
                return $0.traversalIndex < $1.traversalIndex
            }
            return $0.path < $1.path
        }
        let elementRecordByPath = Dictionary(uniqueKeysWithValues: elementRecords.map { ($0.path, $0) })

        self.hierarchy = hierarchy
        self.elementAnnotationByPath = elementAnnotationByPath
        self.containerAnnotationByPath = containerAnnotationByPath
        self.observationIdentityByPath = observationIdentityByPath
        self.elementsInTraversalOrder = elementRecords
        self.nodesInPathOrder = nodeRecords
        self.elementRecordByPath = elementRecordByPath
    }

    package func node(at path: TreePath) -> AccessibilityHierarchy? {
        hierarchy.node(at: path)
    }

    package func element(at path: TreePath) -> InterfaceGraphElementRecord? {
        elementRecordByPath[path]
    }

    package func annotationsForSubtree(
        originalPath: TreePath,
        rootPath: TreePath
    ) -> InterfaceAnnotations {
        guard let node = hierarchy.node(at: originalPath) else {
            preconditionFailure("InterfaceGraph cannot select annotations for missing path \(originalPath.diagnosticDescription)")
        }
        let elements = node.compactMapSubtrees(path: rootPath) { node, newPath -> InterfaceElementAnnotation? in
            guard case .element = node,
                  let oldPath = originalPath.oldPath(forSubtreePath: newPath, rootedAt: rootPath),
                  let annotation = elementAnnotationByPath[oldPath]
            else { return nil }
            return InterfaceElementAnnotation(
                path: newPath,
                actions: annotation.actions,
                geometry: HeistElement.Geometry(
                    screen: annotation.geometry.screen,
                    view: annotation.geometry.view.rebased(
                        fromSubtreeRoot: originalPath,
                        to: rootPath
                    )
                )
            )
        }
        let containers = node.compactMapSubtrees(path: rootPath) { node, newPath -> InterfaceContainerAnnotation? in
            guard case .container = node,
                  let oldPath = originalPath.oldPath(forSubtreePath: newPath, rootedAt: rootPath),
                  let annotation = containerAnnotationByPath[oldPath]
            else { return nil }
            return InterfaceContainerAnnotation(
                path: newPath,
                containerName: annotation.containerName,
                scrollInventory: annotation.scrollInventory
            )
        }
        return InterfaceAnnotations(elements: elements, containers: containers)
    }

    package func observationIdentitiesForSubtree(
        originalPath: TreePath,
        rootPath: TreePath
    ) -> InterfaceElementIdentities {
        guard let node = hierarchy.node(at: originalPath) else {
            preconditionFailure("InterfaceGraph cannot select observation identities for missing path \(originalPath.diagnosticDescription)")
        }
        let identities = node.compactMapSubtrees(path: rootPath) { node, newPath -> (TreePath, Observation.ElementIdentity)? in
            guard case .element = node,
                  let oldPath = originalPath.oldPath(forSubtreePath: newPath, rootedAt: rootPath),
                  let identity = observationIdentityByPath[oldPath]
            else { return nil }
            return (newPath, identity)
        }
        return InterfaceElementIdentities(Dictionary(uniqueKeysWithValues: identities))
    }

    private static func uniqueElementAnnotations(
        _ annotations: [InterfaceElementAnnotation]
    ) throws(InterfaceGraphValidationError) -> [TreePath: InterfaceElementAnnotation] {
        var byPath: [TreePath: InterfaceElementAnnotation] = [:]
        for annotation in annotations {
            guard byPath[annotation.path] == nil else {
                throw .duplicateElementAnnotationPath(annotation.path)
            }
            byPath[annotation.path] = annotation
        }
        return byPath
    }

    private static func nodeRecords(
        hierarchy: AccessibilityHierarchyGraph,
        elementAnnotationByPath: [TreePath: InterfaceElementAnnotation],
        containerAnnotationByPath: [TreePath: InterfaceContainerAnnotation],
        observationIdentityByPath: [TreePath: Observation.ElementIdentity]
    ) throws(InterfaceGraphValidationError) -> [InterfaceGraphNodeRecord] {
        var nodeRecords: [InterfaceGraphNodeRecord] = []
        nodeRecords.reserveCapacity(hierarchy.nodesInPathOrder.count)
        for record in hierarchy.nodesInPathOrder {
            let kind: InterfaceGraphNodeKind
            switch record.node {
            case .element(let element, let traversalIndex):
                guard let annotation = elementAnnotationByPath[record.path] else {
                    throw .missingElementAnnotation(record.path)
                }
                kind = .element(InterfaceGraphElementRecord(
                    path: record.path,
                    traversalIndex: traversalIndex,
                    accessibilityElement: element,
                    annotation: annotation,
                    observationIdentity: observationIdentityByPath[record.path]
                ))
            case .container(let container, _):
                kind = .container(InterfaceGraphContainerRecord(
                    path: record.path,
                    container: container,
                    annotation: containerAnnotationByPath[record.path]
                ))
            }
            nodeRecords.append(InterfaceGraphNodeRecord(
                path: record.path,
                node: record.node,
                traversalIndex: record.traversalIndex,
                kind: kind
            ))
        }
        return nodeRecords
    }

    private static func uniqueContainerAnnotations(
        _ annotations: [InterfaceContainerAnnotation]
    ) throws(InterfaceGraphValidationError) -> [TreePath: InterfaceContainerAnnotation] {
        var byPath: [TreePath: InterfaceContainerAnnotation] = [:]
        for annotation in annotations {
            guard byPath[annotation.path] == nil else {
                throw .duplicateContainerAnnotationPath(annotation.path)
            }
            byPath[annotation.path] = annotation
        }
        return byPath
    }

    private static func validateElementAnnotations(
        _ annotations: [TreePath: InterfaceElementAnnotation],
        in hierarchy: AccessibilityHierarchyGraph
    ) throws(InterfaceGraphValidationError) {
        for path in annotations.keys.sorted() {
            switch hierarchy.node(at: path) {
            case nil:
                throw .elementAnnotationForMissingPath(path)
            case .container:
                throw .elementAnnotationForContainerPath(path)
            case .element:
                break
            }
        }
    }

    private static func validateContainerAnnotations(
        _ annotations: [TreePath: InterfaceContainerAnnotation],
        in hierarchy: AccessibilityHierarchyGraph
    ) throws(InterfaceGraphValidationError) {
        for path in annotations.keys.sorted() {
            switch hierarchy.node(at: path) {
            case nil:
                throw .containerAnnotationForMissingPath(path)
            case .element:
                throw .containerAnnotationForElementPath(path)
            case .container:
                break
            }
        }
    }

    private static func validateObservationIdentities(
        _ identities: [TreePath: Observation.ElementIdentity],
        in hierarchy: AccessibilityHierarchyGraph
    ) throws(InterfaceGraphValidationError) {
        for path in identities.keys.sorted() {
            switch hierarchy.node(at: path) {
            case nil:
                throw .observationIdentityForMissingPath(path)
            case .container:
                throw .observationIdentityForContainerPath(path)
            case .element:
                break
            }
        }
    }
}

private extension TreePath {
    var diagnosticDescription: String {
        "[\(indices.map(String.init).joined(separator: ", "))]"
    }

    func oldPath(forSubtreePath subtreePath: TreePath, rootedAt rootPath: TreePath) -> TreePath? {
        guard let relativePath = subtreePath.removingPrefix(rootPath) else { return nil }
        return appending(contentsOf: relativePath)
    }
}
