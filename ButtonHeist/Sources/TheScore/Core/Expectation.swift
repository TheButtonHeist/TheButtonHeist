import ThePlans

private func multiset<Value: Hashable>(
    _ values: some Sequence<Value>
) -> [Value: Int] {
    values.reduce(into: [:]) { counts, value in
        counts[value, default: 0] += 1
    }
}

/// An execution-ready predicate program that consumes one event at a time.
///
/// Live execution constructs one expectation, then feeds it each observed event
/// exactly once. Retained evidence can reconstruct the same result by creating a
/// fresh expectation and feeding the recorded events in order.
package struct Expectation: Sendable, Equatable {
    private enum Settlement: Sendable, Equatable {
        case notRequired
        case pending
        case settled
    }

    private let pending: [Step]
    private let settlement: Settlement

    package init(
        _ predicates: [ObservationPredicate] = [],
        baseline: Observation.Snapshot? = nil,
        events: [Observation.Event] = [],
        requiringNoChange: Bool = false
    ) {
        let initial = Expectation(
            pending: predicates.flatMap(\.expectationSteps)
        )
        let required = requiringNoChange ? initial.requiringNoChange() : initial
        let withBaseline = baseline.map {
            required.evaluating(.baseline($0))
        } ?? required
        self = events.reduce(withBaseline) { expectation, event in
            expectation.evaluating(.event(event))
        }
    }

    private init(
        pending: [Step],
        settlement: Settlement = .notRequired
    ) {
        self.pending = pending
        self.settlement = settlement
    }

    /// Returns this expectation advanced by one newly published event.
    ///
    /// The event is never retained here. Observation history owns evidence;
    /// Expectation owns only the ordered predicate state still waiting.
    package func evaluating(_ event: Observation.Event) -> Expectation {
        evaluating(.event(event))
    }

    package func requiringNoChange() -> Expectation {
        guard settlement != .pending else { return self }
        return Expectation(pending: pending, settlement: .pending)
    }

    package enum Result: Sendable, Equatable {
        case satisfied
        case waiting(String)

        package var outstandingDescription: String? {
            guard case .waiting(let description) = self else { return nil }
            return description
        }
    }

    package var result: Result {
        if let description = pending.first(where: { !$0.isMatchedAbsence })?.description {
            return .waiting(description)
        }
        return settlement == .pending ? .waiting(ObservationPredicate.noChange.description) : .satisfied
    }

    package var isWaitingOnlyForNoChange: Bool {
        let unmatched = pending.filter { !$0.isMatchedAbsence }
        return settlement == .pending && unmatched.isEmpty
            || unmatched.count == 1 && unmatched[0].isNoChange
    }

    package var requiresCompleteExploration: Bool {
        pending.contains(where: \.isMatchedAbsence)
    }

    package var hasMatchedTemporalBaseline: Bool {
        pending.contains {
            if case .after = $0 { return true }
            return false
        }
    }

    private func evaluating(_ input: Input) -> Expectation {
        let settlement: Settlement = self.settlement == .settled
            && !input.isNoChange && pending.contains(where: \.isMatchedAbsence)
            ? .pending : self.settlement
        let maySettle = settlement == .pending && pending.allSatisfy(\.isMatchedAbsence)
        var next: [Step] = []
        next.reserveCapacity(pending.count)

        for (index, step) in pending.enumerated() {
            switch step.evaluating(input, keepingAbsenceProvisional: index == pending.count - 1) {
            case .indifferent:
                next.append(step)
            case .matched(let remainder):
                if let remainder {
                    next.append(remainder)
                }
            case .unmatched(let replacement):
                next.append(replacement ?? step)
                if index + 1 < pending.count {
                    next.append(contentsOf: pending[(index + 1)...])
                }
                return Expectation(pending: next, settlement: settlement)
            }
        }
        return Expectation(
            pending: next,
            settlement: maySettle && input.isNoChange ? .settled : settlement
        )
    }
}

private extension Expectation {
    enum Input {
        case baseline(Observation.Snapshot)
        case event(Observation.Event)

        var matchInput: AccessibilityTargetMatchInput<HeistElement>? {
            switch self {
            case .baseline(let snapshot), .event(.elementsChanged(let snapshot)):
                return AccessibilityTargetMatchInput(interface: snapshot.interface)
            case .event:
                return nil
            }
        }

        func containsCapturedElement(at path: TreePath) -> Bool {
            switch self {
            case .baseline(let snapshot), .event(.elementsChanged(let snapshot)):
                snapshot.interface.graph.element(at: path)?.annotation.source == .capture
            case .event:
                false
            }
        }

        var isScreenBoundary: Bool {
            guard case .event(.screenChanged) = self else { return false }
            return true
        }

        var isNoChange: Bool {
            guard case .event(.noChange) = self else { return false }
            return true
        }
    }

    /// The semantic slice compared by a temporal element assertion.
    enum Scope: Sendable, Equatable {
        case graph
        case target(ResolvedAccessibilityTarget)
        case property(
            AssertableProperty,
            of: ResolvedAccessibilityElementTarget
        )

        func semanticProjection(in input: Input) -> SemanticProjection {
            guard let matchInput = input.matchInput else {
                preconditionFailure("Expectation scope requires an interface reading")
            }
            let graph = AccessibilityTargetMatchGraph(matchInput)
            switch self {
            case .graph:
                return .semantics(
                    elements: multiset(
                        matchInput.elements.lazy.map(\.element.semantics)
                    ),
                    containers: multiset(
                        matchInput.containers.lazy.map(\.facts)
                    )
                )
            case .target(let target):
                let matches = graph.resolve(target)
                return .semantics(
                    elements: multiset(
                        matches.elements.elements.lazy.map(\.semantics)
                    ),
                    containers: multiset(matches.containers.lazy.map(\.facts))
                )
            case .property(let property, let target):
                let semantics = graph.resolve(target.accessibilityTarget)
                    .elements.elements.lazy.map(\.semantics)
                return .property(property.semanticProjection(of: semantics))
            }
        }
    }

    enum SemanticProjection: Sendable, Equatable {
        case semantics(
            elements: [HeistElement.Semantics: Int],
            containers: [ContainerPredicateFacts: Int]
        )
        case property(PropertyProjection)
    }

    enum PropertyProjection: Sendable, Equatable {
        case value([String?: Int])
        case traits([Set<HeistTrait>: Int])
        case hint([String?: Int])
        case actions([Set<ElementAction>: Int])
        case customContent([[HeistCustomContent]: Int])
        case rotors([Set<HeistRotor>: Int])
    }

    /// One authored assertion and the part of it that remains.
    ///
    /// An event evaluates only the current case. Matching `before` captures its
    /// scoped semantic projection and produces `after`; that same event is never fed
    /// through the new case.
    enum Step: Sendable, Equatable {
        case current(ObservationPredicate)
        case absent(ResolvedAccessibilityTarget)
        case before(
            ObservationPredicate,
            then: ObservationPredicate,
            scope: Scope
        )
        case after(
            ObservationPredicate,
            scope: Scope,
            beforeMatch: SemanticProjection,
            restart: Before
        )

        struct Before: Sendable, Equatable {
            let predicate: ObservationPredicate
            let after: ObservationPredicate
            let scope: Scope
        }

        enum Evaluation: Sendable, Equatable {
            case indifferent
            case matched(Step?)
            case unmatched(Step?)
        }

        func evaluating(_ input: Input, keepingAbsenceProvisional: Bool) -> Evaluation {
            switch self {
            case .current(let predicate):
                let evaluation = predicate.evaluateCurrent(input)
                if keepingAbsenceProvisional,
                   case .elementsChanged(let assertions) = predicate,
                   assertions.count == 1,
                   case .missing(let target) = assertions[0],
                   case .matched = evaluation {
                    return .matched(.absent(target))
                }
                return evaluation
            case .absent(let target):
                // A miss at an old position stays provisional while search can find the target elsewhere.
                let predicate = ObservationPredicate.elementsChanged([.missing(target)])
                switch predicate.evaluateCurrent(input) {
                case .matched: return .matched(self)
                case .unmatched: return .unmatched(.current(predicate))
                case .indifferent: return .indifferent
                }
            case .before(let predicate, let after, let scope):
                switch predicate.evaluateCurrent(input) {
                case .indifferent:
                    return .indifferent
                case .unmatched:
                    return .unmatched(nil)
                case .matched:
                    return .matched(.after(
                        after,
                        scope: scope,
                        beforeMatch: scope.semanticProjection(in: input),
                        restart: Before(
                            predicate: predicate,
                            after: after,
                            scope: scope
                        )
                    ))
                }
            case .after(let predicate, let scope, let beforeMatch, let restart):
                if input.isScreenBoundary, case .property = scope {
                    return .unmatched(.before(
                        restart.predicate,
                        then: restart.after,
                        scope: restart.scope
                    ))
                }
                switch predicate.evaluateCurrent(input) {
                case .indifferent:
                    return .indifferent
                case .unmatched:
                    return .unmatched(nil)
                case .matched:
                    return scope.semanticProjection(in: input) == beforeMatch
                        ? .unmatched(nil)
                        : .matched(nil)
                }
            }
        }

        var description: String {
            switch self {
            case .current(let predicate), .before(let predicate, _, _):
                return predicate.description
            case .absent(let target):
                return ObservationPredicate.elementsChanged([.missing(target)]).description
            case .after(let predicate, _, _, _):
                return predicate.description
            }
        }

        var isNoChange: Bool {
            guard case .current(.noChange) = self else { return false }
            return true
        }

        var isMatchedAbsence: Bool {
            if case .absent = self { return true }
            return false
        }
    }
}

private extension ObservationPredicate {
    var expectationSteps: [Expectation.Step] {
        switch self {
        case .elementsChanged(let assertions):
            guard !assertions.isEmpty else {
                let anyElementEvent = ObservationPredicate.elementsChanged([])
                return [.before(anyElementEvent, then: anyElementEvent, scope: .graph)]
            }
            return assertions.map(\.expectationStep)
        case .notification, .noChange, .screenChanged:
            return [.current(self)]
        }
    }

    func evaluateCurrent(
        _ input: Expectation.Input
    ) -> Expectation.Step.Evaluation {
        switch (self, input) {
        case (.elementsChanged(let assertions), _):
            guard let matchInput = input.matchInput else {
                return .indifferent
            }
            guard let assertion = assertions.first else {
                return .matched(nil)
            }
            guard assertions.count == 1 else {
                preconditionFailure("One expectation step evaluates one element predicate")
            }
            return assertion.matchesCurrent(
                AccessibilityTargetMatchGraph(matchInput), input: input
            )
                ? .matched(nil)
                : .unmatched(nil)
        case (.notification(let predicate), .event(.notification(let notification))):
            return predicate.matches(notification) ? .matched(nil) : .unmatched(nil)
        case (.noChange, .event(.noChange)):
            return .matched(nil)
        case (.screenChanged(let predicate), .event(.screenChanged(let screen))):
            return predicate.matches(screen) ? .matched(nil) : .unmatched(nil)
        case (.notification, _),
             (.noChange, _),
             (.screenChanged, _):
            return .indifferent
        }
    }
}

private extension ResolvedElementAssertion {
    var expectationStep: Expectation.Step {
        switch self {
        case .exists(let target):
            return .current(.elementsChanged([.exists(target)]))
        case .missing(let target):
            return .current(.elementsChanged([.missing(target)]))
        case .appeared(let target):
            return .before(
                .elementsChanged([.missing(target)]),
                then: .elementsChanged([.exists(target)]),
                scope: .target(target)
            )
        case .disappeared(let target):
            return .before(
                .elementsChanged([.exists(target)]),
                then: .elementsChanged([.missing(target)]),
                scope: .target(target)
            )
        case .updated(let target, let change):
            return .before(
                .elementsChanged([.exists(
                    target.and(change.value.predicateChecks(.before)).accessibilityTarget
                )]),
                then: .elementsChanged([.exists(
                    target.and(change.value.predicateChecks(.after)).accessibilityTarget
                )]),
                scope: .property(change.property, of: target)
            )
        }
    }

    func matchesCurrent(
        _ graph: AccessibilityTargetMatchGraph<HeistElement>,
        input: Expectation.Input
    ) -> Bool {
        switch self {
        case .exists(let target):
            let matches = graph.resolve(target)
            return !matches.containers.isEmpty || matches.elements.matches.contains {
                input.containsCapturedElement(at: $0.path)
            }
        case .missing(let target):
            return graph.resolve(target).isEmpty
        case .appeared, .disappeared, .updated:
            preconditionFailure("Temporal assertions must decompose before evaluation")
        }
    }
}

private enum ElementPropertyChangeSide {
    case before
    case after

    func pick<Checker>(_ change: PropertyChangeCore<Checker>) -> Checker? {
        switch self {
        case .before: return change.before
        case .after: return change.after
        }
    }
}

private extension ResolvedElementPropertyChangeValue {
    func predicateChecks(
        _ side: ElementPropertyChangeSide
    ) -> [ResolvedElementPredicateCheck] {
        switch self {
        case .value(let change):
            return side.pick(change).map { [.value($0)] } ?? []
        case .hint(let change):
            return side.pick(change).map { [.hint($0)] } ?? []
        case .customContent(let change):
            return side.pick(change).map { [.customContent($0)] } ?? []
        case .traits(let change):
            return side.pick(change).map {
                setPredicateChecks(
                    $0.include,
                    $0.exclude,
                    as: ResolvedElementPredicateCheck.traits
                )
            } ?? []
        case .actions(let change):
            return side.pick(change).map {
                setPredicateChecks(
                    $0.include,
                    $0.exclude,
                    as: ResolvedElementPredicateCheck.actions
                )
            } ?? []
        case .rotors(let change):
            return side.pick(change).map {
                setPredicateChecks(
                    $0.include,
                    $0.exclude,
                    as: ResolvedElementPredicateCheck.rotors
                )
            } ?? []
        }
    }

    private func setPredicateChecks<Values: Collection>(
        _ include: Values,
        _ exclude: Values,
        as check: (Values) -> ResolvedElementPredicateCheck
    ) -> [ResolvedElementPredicateCheck] {
        (include.isEmpty ? [] : [check(include)])
            + (exclude.isEmpty ? [] : [.exclude(check(exclude))])
    }
}

extension NotificationPredicate.Execution {
    package func matches(_ notification: Observation.Notification) -> Bool {
        let textMatches = text.map { match in
            notification.text.map(match.matches) ?? false
        } ?? true
        let elementMatches = element.map { predicate in
            notification.element?.matches(predicate) ?? false
        } ?? true
        return textMatches && elementMatches
    }
}

private extension AssertableProperty {
    func semanticProjection(
        of semantics: some Sequence<HeistElement.Semantics>
    ) -> Expectation.PropertyProjection {
        switch self {
        case .value:
            return .value(multiset(semantics.lazy.map(\.assertable.value)))
        case .traits:
            return .traits(multiset(semantics.lazy.map(\.assertable.traits)))
        case .hint:
            return .hint(multiset(semantics.lazy.map(\.assertable.hint)))
        case .actions:
            return .actions(multiset(semantics.lazy.map(\.assertable.actions)))
        case .customContent:
            return .customContent(multiset(semantics.lazy.map(\.assertable.customContent)))
        case .rotors:
            return .rotors(multiset(semantics.lazy.map(\.assertable.rotors)))
        }
    }
}
