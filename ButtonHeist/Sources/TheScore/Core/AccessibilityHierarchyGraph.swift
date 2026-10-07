import AccessibilitySnapshotModel
import ThePlans

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
    package let kind: InterfaceGraphNodeKind

    package init(
        path: TreePath,
        kind: InterfaceGraphNodeKind
    ) {
        self.path = path
        self.kind = kind
    }

    package var traversalIndex: Int? {
        guard case .element(let element) = kind else { return nil }
        return element.traversalIndex
    }
}

package struct InterfaceGraph: Equatable, Sendable {
    package let elementsInTraversalOrder: [InterfaceGraphElementRecord]
    package let nodesInPathOrder: [InterfaceGraphNodeRecord]

    private let nodeOffsetByPath: [TreePath: Int]

    package init(
        tree: [AccessibilityHierarchy],
        annotations: InterfaceAnnotations,
        observationIdentities: InterfaceElementIdentities = .empty
    ) throws(InterfaceGraphValidationError) {
        let sourceNodes = SourceNode.records(in: tree)
        let sourceNodeByPath = Dictionary(uniqueKeysWithValues: sourceNodes.map { ($0.path, $0.kind) })
        let elementAnnotationByPath = try Self.uniqueElementAnnotations(annotations.elements)
        let containerAnnotationByPath = try Self.uniqueContainerAnnotations(annotations.containers)
        let observationIdentityByPath = observationIdentities.byPath

        try Self.validateElementAnnotations(elementAnnotationByPath, in: sourceNodeByPath)
        try Self.validateContainerAnnotations(containerAnnotationByPath, in: sourceNodeByPath)
        try Self.validateObservationIdentities(observationIdentityByPath, in: sourceNodeByPath)

        let nodeRecords = try Self.nodeRecords(
            sourceNodes: sourceNodes,
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
        let nodeOffsetByPath = Dictionary(
            uniqueKeysWithValues: nodeRecords.enumerated().map { ($0.element.path, $0.offset) }
        )

        self.elementsInTraversalOrder = elementRecords
        self.nodesInPathOrder = nodeRecords
        self.nodeOffsetByPath = nodeOffsetByPath
    }

    package func element(at path: TreePath) -> InterfaceGraphElementRecord? {
        guard case .element(let element)? = nodeKind(at: path) else { return nil }
        return element
    }

    package func path(for observationIdentity: Observation.ElementIdentity) -> TreePath? {
        elementsInTraversalOrder.first { $0.observationIdentity == observationIdentity }?.path
    }

    package func annotationsForSubtree(
        _ node: AccessibilityHierarchy,
        originalPath: TreePath,
        rootPath: TreePath
    ) -> InterfaceAnnotations {
        let elements = node.compactMapSubtrees(path: rootPath) { node, newPath -> InterfaceElementAnnotation? in
            guard case .element = node,
                  let oldPath = originalPath.oldPath(forSubtreePath: newPath, rootedAt: rootPath),
                  case .element(let record)? = nodeKind(at: oldPath)
            else { return nil }
            let annotation = record.annotation
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
                  case .container(let record)? = nodeKind(at: oldPath),
                  let annotation = record.annotation
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
        _ node: AccessibilityHierarchy,
        originalPath: TreePath,
        rootPath: TreePath
    ) -> InterfaceElementIdentities {
        let identities = node.compactMapSubtrees(path: rootPath) { node, newPath -> (TreePath, Observation.ElementIdentity)? in
            guard case .element = node,
                  let oldPath = originalPath.oldPath(forSubtreePath: newPath, rootedAt: rootPath),
                  case .element(let record)? = nodeKind(at: oldPath),
                  let identity = record.observationIdentity
            else { return nil }
            return (newPath, identity)
        }
        return InterfaceElementIdentities(Dictionary(uniqueKeysWithValues: identities))
    }

    private func nodeKind(at path: TreePath) -> InterfaceGraphNodeKind? {
        guard let offset = nodeOffsetByPath[path], nodesInPathOrder.indices.contains(offset) else { return nil }
        return nodesInPathOrder[offset].kind
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
        sourceNodes: [SourceNode.Record],
        elementAnnotationByPath: [TreePath: InterfaceElementAnnotation],
        containerAnnotationByPath: [TreePath: InterfaceContainerAnnotation],
        observationIdentityByPath: [TreePath: Observation.ElementIdentity]
    ) throws(InterfaceGraphValidationError) -> [InterfaceGraphNodeRecord] {
        var nodeRecords: [InterfaceGraphNodeRecord] = []
        nodeRecords.reserveCapacity(sourceNodes.count)
        for record in sourceNodes {
            let kind: InterfaceGraphNodeKind
            switch record.kind {
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
            case .container(let container):
                kind = .container(InterfaceGraphContainerRecord(
                    path: record.path,
                    container: container,
                    annotation: containerAnnotationByPath[record.path]
                ))
            }
            nodeRecords.append(InterfaceGraphNodeRecord(
                path: record.path,
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
        in sourceNodeByPath: [TreePath: SourceNode]
    ) throws(InterfaceGraphValidationError) {
        for path in annotations.keys.sorted() {
            switch sourceNodeByPath[path] {
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
        in sourceNodeByPath: [TreePath: SourceNode]
    ) throws(InterfaceGraphValidationError) {
        for path in annotations.keys.sorted() {
            switch sourceNodeByPath[path] {
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
        in sourceNodeByPath: [TreePath: SourceNode]
    ) throws(InterfaceGraphValidationError) {
        for path in identities.keys.sorted() {
            switch sourceNodeByPath[path] {
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

private enum SourceNode: Equatable, Sendable {
    struct Record: Equatable, Sendable {
        let path: TreePath
        let kind: SourceNode
    }

    case element(AccessibilityElement, traversalIndex: Int)
    case container(AccessibilityContainer)

    static func records(in tree: [AccessibilityHierarchy]) -> [Record] {
        tree.compactMapSubtrees { node, path in
            switch node {
            case .element(let element, let traversalIndex):
                Record(path: path, kind: .element(element, traversalIndex: traversalIndex))
            case .container(let container, _):
                Record(path: path, kind: .container(container))
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
