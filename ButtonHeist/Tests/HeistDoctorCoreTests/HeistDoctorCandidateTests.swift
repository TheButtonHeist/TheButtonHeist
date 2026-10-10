import ButtonHeistTestSupport
import Foundation
import Testing
import ThePlans
import TheScore
@testable import HeistDoctorCore

private func reportElement(label: String) -> HeistElement {
    makeTestHeistElement(
        description: label,
        label: label,
        traits: [.button],
        actions: [.activate]
    )
}

private let repairSuggestionFixture = HeistRepairSuggestion(
    stepPath: "$.body[0]",
    failureKind: .missingTarget,
    oldTarget: .predicate(ElementPredicate(label: "Delete")),
    oldResolvedElement: HeistRepairElementEvidence(
        element: reportElement(label: "Delete"),
        siblingText: ["Milk"],
        headerText: []
    ),
    newTarget: .predicate(ElementPredicate(label: "Remove")),
    newResolvedElement: HeistRepairElementEvidence(
        element: reportElement(label: "Remove"),
        siblingText: ["Milk"],
        headerText: []
    ),
    confidence: .medium,
    reasons: [
        .oldTargetResolvedInLastSuccessfulSnapshot,
        .suggestedMatcherResolvesExactlyOneElement,
    ],
    caveats: []
)

private let repairJSONDiagnosisFixture = HeistRepairDiagnosis.suggested(
    HeistRepairSuggestedDiagnosis(
        stepPath: "$.body[0]",
        failureKind: .missingTarget,
        oldTarget: repairSuggestionFixture.oldTarget,
        oldResolvedElement: repairSuggestionFixture.oldResolvedElement,
        currentMatchCount: 0,
        candidates: [],
        suggestions: [repairSuggestionFixture]
    )
)

@Suite struct HeistDoctorCandidateTests {
    @Test("JSON diagnosis stores canonical elements inside Doctor evidence")
    func jsonDiagnosisStoresCanonicalElementsInsideDoctorEvidence() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(repairJSONDiagnosisFixture)
        let probe = try JSONProbe(data: data).object()
        let decodedDiagnosis = try JSONDecoder().decode(HeistRepairDiagnosis.self, from: data)
        let suggested = try probe.object("suggested").object("_0")
        let suggestions = try suggested.array("suggestions")
        let suggestion = try #require(suggestions.first)
        let evidence = try suggestion.object("newResolvedElement")
        let element = try evidence.object("element")
        let semantics = try element.object("semantics")
        let assertable = try semantics.object("assertable")
        let screen = try element.object("geometry").object("screen")
        let frame = try screen.object("frame").object("rect")

        #expect(try evidence.array("siblingText").count == 1)
        #expect(try semantics.string("spokenDescription") == "Remove")
        #expect(try assertable.string("label") == "Remove")
        #expect(try frame.double("width") == 100)
        try probe.assertRecursivelyMissingKeys(["status", "featureStatus", "action" + "Kind"])
        #expect(decodedDiagnosis == repairJSONDiagnosisFixture)
    }

    @Test("Repair request admits one evidence body and rejects reversed outcomes")
    func repairRequestAdmitsOneEvidenceBodyAndRejectsReversedOutcomes() throws {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Pay"))
        let interface = makeTestInterface(elements: [
            element(label: "Pay", traits: [.button], actions: [.activate]),
        ])
        let last = passedEvidence(target: target, before: interface)
        let current = failedEvidence(target: target, before: interface)
        let repairRequest = try HeistRepairRequest(lastSuccess: last, currentFailure: current)

        #expect(repairRequest.lastSuccess == last)
        #expect(repairRequest.currentFailure == current)
        #expect(repairRequest.lastSuccess.command == .activate(target))
        #expect(repairRequest.currentFailure.command == .activate(target))
        #expect(throws: (any Error).self) {
            _ = try HeistRepairRequest(lastSuccess: current, currentFailure: last)
        }
    }

    @Test("Candidate scoring rejects compatible-only successors without continuity")
    func candidateScoringRejectsCompatibleOnlySuccessorsWithoutContinuity() {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Delete"))
        let last = passedEvidence(
            target: target,
            before: makeTestInterface(elements: [
                element(label: "Delete", traits: [.button], actions: [.activate]),
            ])
        )
        let current = failedEvidence(
            target: target,
            before: makeTestInterface(elements: [
                element(label: "Checkout", traits: [.button], actions: [.activate]),
            ])
        )

        let ranked = rankedCandidates(last: last, current: current, failureKind: .missingTarget)

        #expect(ranked.isEmpty)
    }

    @Test("Candidate generation preserves tied best score order")
    func candidateGenerationPreservesTiedBestScoreOrder() throws {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Delete"))
        let last = passedEvidence(
            target: target,
            before: listInterface(rows: [
                ("Milk", "Delete"),
            ])
        )
        let current = failedEvidence(
            target: target,
            before: listInterface(rows: [
                ("Milk", "Delete item"),
                ("Milk", "Delete item"),
                ("Bread", "Archive"),
            ])
        )

        let ranked = rankedCandidates(last: last, current: current, failureKind: .missingTarget)
        let bestScore = try #require(ranked.first?.score)
        let tiedBest = ranked.prefix { $0.score == bestScore }

        #expect(tiedBest.count == 2)
        #expect(tiedBest.map(\.element.traversalIndex) == [1, 3])
        #expect(tiedBest.allSatisfy { $0.reasons.contains(.labelSemanticRename) })
        #expect(tiedBest.allSatisfy { $0.reasons.contains(.siblingRowContextPreserved) })
    }

    @Test("Repair screen keeps duplicate semantic nodes path-distinct across matching and selection")
    func repairScreenKeepsDuplicateSemanticNodesPathDistinct() throws {
        let screen = RepairScreen(interface: listInterface(rows: [
            ("Milk", "Remove"),
            ("Bread", "Remove"),
        ]))
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Remove"))

        guard case .ambiguous(let matches, let matchCount) = screen.resolve(target) else {
            Issue.record("Expected duplicate labels to remain ambiguous")
            return
        }

        #expect(matchCount == 2)
        #expect(Set(matches.map(\.path)).count == 2)
        #expect(matches.map(\.siblingText) == [["Milk"], ["Bread"]])

        let second = try #require(matches.last)
        let selection = try #require(screen.minimumUniquePredicate(for: second.id))
        guard case .resolved(let resolved, let selectedMatchCount) = screen.resolve(selection.target) else {
            Issue.record("Expected generated target to resolve")
            return
        }

        #expect(selection.target == .predicate(
            ElementPredicate(label: "Remove", traits: [.button]),
            ordinal: 1
        ))
        #expect(selectedMatchCount == 2)
        #expect(resolved.id == second.id)
        #expect(resolved.path == second.path)
    }

    @Test("Repair screen uses canonical target matching for scoped, ordinal, and unsupported targets")
    func repairScreenUsesCanonicalTargetMatching() {
        let screen = RepairScreen(interface: makeTestInterface(nodes: [
            testContainer(makeTestSemanticContainer(label: "Checkout"), children: [
                testElement(element(label: "Pay", traits: [.button], actions: [.activate])),
            ]),
            testContainer(makeTestSemanticContainer(label: "Cart"), children: [
                testElement(element(label: "Pay", traits: [.button], actions: [.activate])),
            ]),
        ]))

        let scoped = AccessibilityTarget.within(container: .label("Checkout"), target: .label("Pay"))
        guard case .resolved(let scopedMatch, let scopedCount) = screen.resolve(scoped) else {
            Issue.record("Expected scoped element target to resolve")
            return
        }
        #expect(scopedCount == 1)
        #expect(scopedMatch.path == TreePath([0, 0]))

        guard case .resolved(let ordinalMatch, let ordinalCount) = screen.resolve(
            .predicate(ElementPredicate(label: "Pay"), ordinal: 1)
        ) else {
            Issue.record("Expected ordinal target to resolve")
            return
        }
        #expect(ordinalCount == 2)
        #expect(ordinalMatch.path == TreePath([1, 0]))

        guard case .notFound(let matchCount) = screen.resolve(
            .predicate(ElementPredicate(label: "Pay"), ordinal: 2)
        ) else {
            Issue.record("Expected out-of-range ordinal to preserve candidate cardinality")
            return
        }
        #expect(matchCount == 2)

        guard case .unsupportedTarget(.container) = screen.resolve(.container(.label("Checkout"))) else {
            Issue.record("Expected matched container to remain unsupported for repair")
            return
        }
        guard case .unsupportedTarget(.reference) = screen.resolve(.ref("pay")) else {
            Issue.record("Expected unresolved target reference to remain unsupported")
            return
        }
    }

    @Test("One screen context preserves scoring and output order across repair rules")
    func oneScreenContextPreservesScoringAndOutputOrderAcrossRepairRules() throws {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Delete item"))
        let last = passedEvidence(
            target: target,
            before: sectionInterface(primaryAction: "Delete item")
        )
        let current = failedEvidence(
            target: target,
            before: sectionInterface(primaryAction: "Delete item now")
        )

        guard case .suggested(let diagnosis) = HeistDoctor.diagnosis(for: request(last, current)) else {
            Issue.record("Expected a repair suggestion")
            return
        }
        let candidate = try #require(diagnosis.candidates.first)
        let suggestion = try #require(diagnosis.suggestions.first)

        #expect(candidate.reasons == [
            .labelSemanticRename,
            .controlRoleTraitsCompatible,
            .elementActionsCompatible,
            .siblingRowContextPreserved,
            .headerContextPreserved,
            .elementSupportsSameActionFamily,
        ])
        #expect(suggestion.newResolvedElement.siblingText == ["Milk"])
        #expect(suggestion.newResolvedElement.headerText == ["Cart"])
        #expect(suggestion.reasons == [
            .oldTargetResolvedInLastSuccessfulSnapshot,
            .oldTargetCurrentMatchCount(0),
            .suggestedMatcherResolvesExactlyOneElement,
            .missingTargetSuccessorSelected,
            .scoring(.labelSemanticRename),
            .scoring(.controlRoleTraitsCompatible),
            .scoring(.elementActionsCompatible),
            .scoring(.siblingRowContextPreserved),
            .scoring(.headerContextPreserved),
            .scoring(.elementSupportsSameActionFamily),
            .changeFact(.lastSuccess, .noSemanticChange),
            .changeFact(.currentFailure, .noSemanticChange),
        ])
    }

    private func rankedCandidates(
        last: HeistRepairEvidence,
        current: HeistRepairEvidence,
        failureKind: HeistRepairFailureKind
    ) -> [ScoredCandidate] {
        let lastScreen = RepairScreen(interface: last.beforeSnapshot)
        guard case .resolved(let oldResolved, _) = lastScreen.resolve(last.target) else {
            Issue.record("Expected last target to resolve once")
            return []
        }
        let currentScreen = RepairScreen(interface: current.beforeSnapshot)
        let actionRequirement = RepairActionRequirement(command: current.command)
        return RepairCandidateGenerator.rankedSuccessorCandidates(
            oldResolved: oldResolved,
            currentScreen: currentScreen,
            preferredCandidates: [],
            failureKind: failureKind,
            actionRequirement: actionRequirement,
            lastSuccess: last,
            currentFailure: current
        )
    }

    private func sectionInterface(primaryAction: String) -> Interface {
        makeTestInterface(nodes: [
            testElement(element(label: "Cart", traits: [.header])),
            testContainer(makeTestAccessibilityContainer(), children: [
                testElement(element(label: "Milk", traits: [.staticText])),
                testElement(element(label: primaryAction, traits: [.button], actions: [.activate])),
            ]),
            testContainer(makeTestAccessibilityContainer(), children: [
                testElement(element(label: "Bread", traits: [.staticText])),
                testElement(element(label: "Archive", traits: [.button], actions: [.activate])),
            ]),
        ])
    }
}
