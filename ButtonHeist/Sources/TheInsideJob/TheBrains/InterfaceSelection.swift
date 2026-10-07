#if canImport(UIKit)
import Foundation

import ThePlans
import TheScore

import AccessibilitySnapshotModel

enum InterfaceSelectionError: Error, Equatable {
    case invalidSubtree(String)
    case subtreeNotFound
    case subtreeOrdinalOutOfRange(ordinal: Int, candidateCount: Int, candidates: [String])
    case ambiguousSubtree(candidateCount: Int, candidates: [String])

    var message: String {
        switch self {
        case .invalidSubtree(let reason):
            return "get_interface subtree could not be resolved: \(reason)"
        case .subtreeNotFound:
            return "get_interface subtree matched no nodes; refine subtree using a container or element target from get_interface."
        case .subtreeOrdinalOutOfRange(let ordinal, let count, let candidates):
            let range = count == 1 ? "0" : "0...\(count - 1)"
            return "get_interface subtree ordinal \(ordinal) is out of range for \(count) matches; "
                + "use \(range) or refine subtree. Candidates: \(Self.diagnosticList(candidates))"
        case .ambiguousSubtree(let count, let candidates):
            return "get_interface subtree matched \(count) nodes; add subtree.ordinal 0...\(count - 1) "
                + "or refine subtree. Candidates: \(Self.diagnosticList(candidates))"
        }
    }

    private static func diagnosticList(_ candidates: [String]) -> String {
        candidates.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "; ")
    }
}

extension TheVault {
    func selectInterface(_ query: InterfaceQuery) throws(InterfaceSelectionError) -> Interface {
        let tree = interfaceTree
        let projection = WireConversion.discoveryProjection(from: tree)
        guard let subtree = query.subtree else { return projection.interface }
        let target: ResolvedAccessibilityTarget
        do {
            target = try subtree.resolve(in: .empty)
        } catch {
            throw .invalidSubtree(String(describing: error))
        }

        let path = try selectedPath(for: resolveTarget(target, in: tree), projection: projection)
        return projection.interface.selectingSubtree(at: path)
    }

    private func selectedPath(
        for resolution: TargetResolution,
        projection: WireConversion.DiscoveryProjection
    ) throws(InterfaceSelectionError) -> TreePath {
        switch resolution {
        case .resolved(.element(let element)):
            let identity = element.heistId.observationElementIdentity
            guard let path = projection.interface.graph.path(for: identity) else {
                throw .subtreeNotFound
            }
            return path
        case .resolved(.container(let container)):
            guard let path = projection.containerPathBySourcePath[container.path] else {
                throw .subtreeNotFound
            }
            return path
        case .notFound(let facts):
            guard case .ordinalOutOfRange(let ordinal, let count) = facts.reason else {
                throw .subtreeNotFound
            }
            throw .subtreeOrdinalOutOfRange(
                ordinal: ordinal,
                candidateCount: count,
                candidates: facts.matchSet.subtreeCandidateSummaries
            )
        case .ambiguous(let facts):
            throw .ambiguousSubtree(
                candidateCount: facts.matchedCount,
                candidates: facts.matchSet.subtreeCandidateSummaries
            )
        }
    }
}

private extension TheVault.TargetMatchSet {
    @MainActor
    var subtreeCandidateSummaries: [String] {
        switch self {
        case .elements(let matches): matches.exactMatches.map(\.subtreeCandidateSummary)
        case .containers(let matches): matches.exactMatches.map(\.subtreeCandidateSummary)
        }
    }
}

private extension InterfaceTree.Element {
    @MainActor
    var subtreeCandidateSummary: String {
        let projected = TheVault.WireConversion.convert(element, geometry: geometry)
        let semantics = projected.semantics
        let properties = semantics.assertable
        return subtreeSummary("element", fields: [
            ("element", semantics.spokenDescription), ("identifier", properties.identifier),
            ("label", properties.label), ("value", properties.value),
            (
                "traits",
                properties.traits.isEmpty
                    ? nil
                    : properties.orderedTraits.map(\.rawValue).joined(separator: ",")
            ),
        ])
    }
}

private extension InterfaceTree.Container {
    var subtreeCandidateSummary: String {
        let facts = container.containerPredicateFacts
        let semantic: (String?, String?) = if case .semanticGroup(let label, let value) = facts.role {
            (label, value)
        } else {
            (nil, nil)
        }
        return subtreeSummary("container", fields: [
            ("type", facts.role.kind.rawValue), ("containerName", containerName?.rawValue),
            ("identifier", facts.identifier), ("label", semantic.0), ("value", semantic.1),
        ], flags: [
            facts.isModalBoundary ? "isModalBoundary=true" : nil,
            facts.isScrollable ? "isScrollable=true" : nil,
        ].compactMap { $0 })
    }
}

private func subtreeSummary(_ kind: String, fields: [(String, String?)], flags: [String] = []) -> String {
    ([kind] + fields.compactMap { name, value in value.flatMap { $0.isEmpty ? nil : "\(name)=\"\($0)\"" } } + flags)
        .joined(separator: " ")
}

#endif
