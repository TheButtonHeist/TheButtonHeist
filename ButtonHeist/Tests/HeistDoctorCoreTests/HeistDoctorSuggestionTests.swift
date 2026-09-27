import ButtonHeistTestSupport
import Testing
import ThePlans
import TheScore
@testable import HeistDoctorCore

@Suite struct HeistDoctorSuggestionTests {
    @Test("Missing target suggests renamed equivalent using row context")
    func missingTargetSuggestsRenamedEquivalentUsingRowContext() throws {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Delete"))
        let last = passedEvidence(
            target: target,
            before: listInterface(rows: [
                ("Milk", "Delete"),
                ("Bread", "Archive"),
            ]),
            observedChanges: [.semanticElementsRemoved],
            semanticEvidence: ["Milk"]
        )
        let current = failedEvidence(
            target: target,
            before: listInterface(rows: [
                ("Milk", "Remove"),
                ("Bread", "Archive"),
            ])
        )

        let suggestion = try #require(HeistDoctor.diagnosis(for: request(last, current)).suggestions.first)

        #expect(suggestion.failureKind == .missingTarget)
        #expect(suggestion.newTarget == .predicate(ElementPredicate(label: "Remove")))
        #expect(suggestion.newResolvedElement.element.semantics.assertable.label == "Remove")
        #expect(suggestion.newResolvedElement.siblingText == ["Milk"])
        #expect(suggestion.confidence == .medium)
        #expect(suggestion.reasons.contains(.scoring(.siblingRowContextPreserved)))
    }

    @Test func `diagnosis exposes validated suggestion pipeline`() throws {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Delete"))
        let last = passedEvidence(
            target: target,
            before: listInterface(rows: [
                ("Milk", "Delete"),
                ("Bread", "Archive"),
            ])
        )
        let current = failedEvidence(
            target: target,
            before: listInterface(rows: [
                ("Milk", "Remove"),
                ("Bread", "Archive"),
            ])
        )

        let result = HeistDoctor.diagnosis(for: request(last, current))
        guard case .suggested(let diagnosis) = result else {
            Issue.record("Expected suggested diagnosis")
            return
        }
        let suggestion = try #require(diagnosis.suggestions.first)
        let candidate = try #require(diagnosis.candidates.first)

        #expect(diagnosis.failureKind == .missingTarget)
        #expect(diagnosis.currentMatchCount == 0)
        #expect(suggestion.newTarget == .predicate(ElementPredicate(label: "Remove")))
        #expect(candidate.source == .semanticContinuityScan)
        #expect(candidate.validation == .suggested(target: suggestion.newTarget, confidence: suggestion.confidence))
        #expect(result.suggestions == diagnosis.suggestions)
        #expect(result.noSuggestionReason == nil)
    }

    @Test func `diagnosis exposes typed candidate ranking refusal`() throws {
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

        let result = HeistDoctor.diagnosis(for: request(last, current))
        guard case .refused(let diagnosis) = result else {
            Issue.record("Expected refused diagnosis")
            return
        }
        guard case .eligible(let evidence) = diagnosis.evidence else {
            Issue.record("Expected eligible refusal evidence")
            return
        }
        let refusal = diagnosis.refusal

        #expect(evidence.candidates.isEmpty)
        #expect(evidence.failureKind == .missingTarget)
        #expect(refusal.stage == .candidateRanking)
        #expect(refusal.reason == .noCandidateMetScoreThreshold)
        #expect(result.noSuggestionReason == refusal.message)
    }

    @Test("Missing target chooses renamed duplicate by neighbor context")
    func missingTargetChoosesRenamedDuplicateByNeighborContext() throws {
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
                ("Milk", "Remove"),
                ("Bread", "Remove"),
            ])
        )

        let suggestion = try #require(HeistDoctor.diagnosis(for: request(last, current)).suggestions.first)

        #expect(suggestion.failureKind == .missingTarget)
        #expect(suggestion.newResolvedElement.element.semantics.assertable.label == "Remove")
        #expect(suggestion.newResolvedElement.siblingText == ["Milk"])
        #expect(suggestion.reasons.contains(.scoring(.siblingRowContextPreserved)))
        #expect(resolvedCount(suggestion.newTarget, in: current.beforeSnapshot) == 1)
    }

    @Test("Missing target does not use traversal ordinal without matching neighbors")
    func missingTargetDoesNotUseTraversalOrdinalWithoutMatchingNeighbors() {
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
                ("Bread", "Remove"),
                ("Eggs", "Remove"),
            ])
        )

        #expect(HeistDoctor.diagnosis(for: request(last, current)).suggestions.isEmpty)
    }

    @Test("Missing target prefers contained label rename over broad screen context")
    func missingTargetPrefersContainedLabelRenameOverBroadScreenContext() throws {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Checkout"))
        let last = passedEvidence(
            target: target,
            before: broadMenuInterface(primaryAction: "Checkout")
        )
        let current = failedEvidence(
            target: target,
            before: broadMenuInterface(primaryAction: "Go to Checkout")
        )

        let suggestion = try #require(HeistDoctor.diagnosis(for: request(last, current)).suggestions.first)

        #expect(suggestion.newTarget == .predicate(ElementPredicate(label: "Go to Checkout")))
        #expect(suggestion.newResolvedElement.element.semantics.assertable.label == "Go to Checkout")
        #expect(suggestion.reasons.contains(.scoring(.labelSemanticRename)))
    }

    @Test("Missing target rejects broad screen context without semantic successor")
    func missingTargetRejectsBroadScreenContextWithoutSemanticSuccessor() {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Checkout"))
        let last = passedEvidence(
            target: target,
            before: broadMenuInterface(primaryAction: "Checkout")
        )
        let current = failedEvidence(
            target: target,
            before: broadMenuInterface(primaryAction: nil)
        )

        #expect(HeistDoctor.diagnosis(for: request(last, current)).suggestions.isEmpty)
    }

    @Test("Ambiguous duplicate labels produce minimum disambiguating matcher")
    func ambiguousDuplicateLabelsProduceMinimumDisambiguatingMatcher() throws {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Delete"))
        let last = passedEvidence(
            target: target,
            before: listInterface(rows: [
                ("Milk", "Delete"),
                ("Bread", "Archive"),
            ])
        )
        let current = failedEvidence(
            target: target,
            before: listInterface(rows: [
                ("Milk", "Delete"),
                ("Bread", "Delete"),
                ("Eggs", "Delete"),
                ("Coffee", "Delete"),
            ])
        )

        let suggestion = try #require(HeistDoctor.diagnosis(for: request(last, current)).suggestions.first)

        #expect(suggestion.failureKind == .ambiguousTarget)
        #expect(suggestion.newTarget == .predicate(ElementPredicate(label: "Delete", traits: [.button]), ordinal: 0))
        #expect(suggestion.newResolvedElement.siblingText == ["Milk"])
        #expect(suggestion.confidence == .low)
        #expect(suggestion.caveats.contains(.ordinalDisambiguation))
        #expect(suggestion.reasons.contains(.scoring(.siblingRowContextPreserved)))
        #expect(resolvedCount(suggestion.newTarget, in: current.beforeSnapshot) == 1)
    }

    @Test("Wrong action capability blocks unsupported suggestions")
    func wrongActionCapabilityBlocksUnsupportedSuggestions() {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Quantity"))
        let last = passedEvidence(
            command: .increment(target),
            target: target,
            before: makeTestInterface(elements: [
                element(label: "Quantity", traits: [.adjustable], actions: [.increment, .decrement]),
            ])
        )
        let current = failedEvidence(
            command: .increment(target),
            target: target,
            before: makeTestInterface(elements: [
                element(label: "Quantity", traits: [.staticText], actions: []),
            ])
        )

        #expect(HeistDoctor.diagnosis(for: request(last, current)).suggestions.isEmpty)
    }

    @Test("Wrong action capability can suggest a compatible successor with lowered confidence")
    func wrongActionCapabilityCanSuggestACompatibleSuccessorWithLoweredConfidence() throws {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Quantity"))
        let last = passedEvidence(
            command: .increment(target),
            target: target,
            before: makeTestInterface(elements: [
                element(label: "Quantity", value: "1", traits: [.adjustable], actions: [.increment, .decrement]),
            ])
        )
        let current = failedEvidence(
            command: .increment(target),
            target: target,
            before: makeTestInterface(elements: [
                element(label: "Quantity", value: "1", traits: [.staticText], actions: []),
                element(label: "Quantity stepper", value: "1", traits: [.adjustable], actions: [.increment, .decrement]),
            ])
        )

        let suggestion = try #require(HeistDoctor.diagnosis(for: request(last, current)).suggestions.first)

        #expect(suggestion.failureKind == .wrongCapability)
        #expect(suggestion.newTarget == .predicate(ElementPredicate(label: "Quantity stepper")))
        #expect(suggestion.confidence == .low)
        #expect(suggestion.reasons.contains(.scoring(.elementSupportsSameActionFamily)))
        #expect(resolvedCount(suggestion.newTarget, in: current.beforeSnapshot) == 1)
    }

    @Test("Ordered observations explain value changes without requiring a full after snapshot")
    func observationsExplainValueChangesWithoutRequiringFullAfterSnapshot() throws {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Quantity"))
        let quantityBefore = element(
            label: "Quantity",
            value: "1",
            traits: [.button],
            actions: [.activate]
        )
        let last = passedEvidence(
            target: target,
            before: makeTestInterface(elements: [quantityBefore]),
            observedChanges: [.valueChange(old: "1", new: "2")],
            semanticEvidence: ["Quantity", "1", "2"],
            expectation: ExpectationResult(met: true, predicate: nil)
        )
        let current = failedEvidence(
            target: target,
            before: makeTestInterface(elements: [
                element(label: "Amount", value: "1", traits: [.button], actions: [.activate]),
            ]),
            observedChanges: [],
            expectation: ExpectationResult(met: false, predicate: nil, actual: "Quantity stayed 1")
        )

        let suggestion = try #require(HeistDoctor.diagnosis(for: request(last, current)).suggestions.first)

        #expect(suggestion.newTarget == .predicate(ElementPredicate(label: "Amount")))
        #expect(suggestion.reasons.contains(.changeFact(.lastSuccess, .valueChange(old: "1", new: "2"))))
        #expect(suggestion.reasons.contains(.changeFact(.currentFailure, .noSemanticChange)))
        #expect(suggestion.reasons.contains(.lastSuccessfulExpectationMet))
        #expect(suggestion.reasons.contains(.currentFailureExpectationUnmet))
        #expect(suggestion.caveats.isEmpty)
    }

    @Test("Screen-boundary repair reasons preserve canonical fact order")
    func screenBoundaryRepairReasonsPreserveCanonicalFactOrder() throws {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Delete"))
        let oldScreen = makeTestInterface(elements: [
            element(label: "Delete", traits: [.button], actions: [.activate]),
        ])
        let newScreen = makeTestInterface(elements: [
            element(label: "Remove", traits: [.button], actions: [.activate]),
        ])
        let last = passedEvidence(
            target: target,
            before: oldScreen,
            observedChanges: [
                .semanticElementsRemoved,
                .screenChange,
                .semanticElementsAdded,
            ],
            semanticEvidence: ["Delete", "Remove"]
        )
        let current = failedEvidence(target: target, before: newScreen)

        let suggestion = try #require(HeistDoctor.diagnosis(for: request(last, current)).suggestions.first)
        let factReasons = suggestion.reasons.compactMap { reason -> RepairChangeFactObservation? in
            guard case .changeFact(.lastSuccess, let observation) = reason else { return nil }
            return observation
        }

        #expect(factReasons == [
            .semanticElementsRemoved,
            .screenChange,
            .semanticElementsAdded,
        ])
    }

    @Test("Empty change facts mean no semantic change")
    func emptyChangeFactsMeanNoSemanticChange() throws {
        let target = AccessibilityTarget.predicate(ElementPredicate(label: "Delete"))
        let last = passedEvidence(
            target: target,
            before: listInterface(rows: [
                ("Milk", "Delete"),
            ]),
            observedChanges: []
        )
        let current = failedEvidence(
            target: target,
            before: listInterface(rows: [
                ("Milk", "Remove"),
            ]),
            observedChanges: []
        )

        let suggestion = try #require(HeistDoctor.diagnosis(for: request(last, current)).suggestions.first)

        #expect(suggestion.newTarget == .predicate(ElementPredicate(label: "Remove")))
        #expect(suggestion.reasons.contains(.changeFact(.lastSuccess, .noSemanticChange)))
        #expect(suggestion.caveats.isEmpty)
    }

    private func broadMenuInterface(primaryAction: String?) -> Interface {
        let itemLabels = [
            "Greek Salad",
            "Margherita Pizza",
            "Garlic Bread",
            "Hummus & Pita",
            "Rice Pilaf",
            "Roasted Vegetables",
            "Tiramisu",
            "Items, 2",
            "Subtotal, US$23.50",
            "Tax (8%), US$1.88",
            "Total, US$25.38",
        ]
        let elements = [
            element(label: "Menu", traits: [.header]),
        ] + itemLabels.map { label in
            element(label: label, traits: [.button], actions: [.activate])
        } + [
            primaryAction.map { element(label: $0, traits: [.button], actions: [.activate]) },
        ].compactMap { $0 }

        return makeTestInterface(elements: elements)
    }

    private func resolvedCount(_ target: AccessibilityTarget, in interface: Interface) -> Int {
        guard let target = try? target.resolve(in: .empty) else { return 0 }
        return AccessibilityTargetMatchGraph(interface: interface).resolve(target).orderedPaths.count
    }
}
