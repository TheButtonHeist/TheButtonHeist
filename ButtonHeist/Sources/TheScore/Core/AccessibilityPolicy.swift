import ThePlans
// MARK: - Accessibility Matcher Facts

public enum AccessibilityFactStability: Sendable, Equatable {
    case identity
    case state
}

public enum AccessibilityMatcherFact: Sendable, Equatable {
    case identifier(String)
    case label(String)
    case value(String)
    case trait(HeistTrait)
    case excludedTrait(HeistTrait)
}

// MARK: - AccessibilityPolicy

/// Single source of truth for trait-related rules-of-the-world.
///
/// Every site that encodes a rule *about traits* — which are state,
/// which are interactive, which drive heistId synthesis, which are
/// purely descriptive — reads from this namespace. Adding or moving a
/// trait policy is a one-file edit; downstream sites are pure consumers.
///
/// The policy lives in TheScore so both client-side targeting
/// (`MinimumPredicateSelector`, which builds durable replay matchers) and server-side
/// parsing (TheInsideJob, which assigns heistIds and writes the wire
/// format) read the same `Set<HeistTrait>`. UIKit-bitmask derivations
/// live in TheInsideJob as `AccessibilityPolicy+UIKit`.
///
/// Traits are classified on two independent axes, so a trait is placed by
/// answering two separate questions:
///
/// - **Identity or state.** Identity traits define the element — what it *is*.
///   State traits change during the element's lifecycle. Every trait is
///   exactly one of the two, so only `stateTraits` is written down and
///   identity is everything else.
/// - **Interactive or not.** Whether Button Heist can act on the element.
///
/// The axes cut across each other: `.button` is identity *and* interactive —
/// being a button is what it is. `.notEnabled` is state *and* about
/// interactivity, but negatively: it says the element cannot be acted on right
/// now. `interactiveTraits` holds only the positive capability, because
/// `Interactivity` reads membership as "advertises an action"; a trait that
/// withdraws interactivity is expressed by excluding it at the call site
/// (`.exclude(.traits([.notEnabled]))`), not by joining the set.
///
/// Rules:
/// - Add a new state trait → edit `stateTraits` only.
/// - Add a new interactive trait → edit `interactiveTraits` only.
/// - Reorder heistId synthesis → edit `synthesisPriority` only and run
///   `SynthesisDeterminismTests` (changes here are wire-format breaks).
public enum AccessibilityPolicy {

    // MARK: - State Traits

    /// Traits whose presence is *state*, not *identity*.
    ///
    /// An element gaining or losing one of these between parses keeps the
    /// same heistId — these traits do not contribute to element identity.
    /// Consumed by:
    /// - `HeistIdAssignment` duplicate-id disambiguation
    /// - `ElementEdits.between` (functional-move pairing)
    /// - `MinimumPredicateSelector` (matcher suggestion — adds state only
    ///   when semantic predicates remain ambiguous)
    public static let stateTraits: Set<HeistTrait> = [
        .selected,
        .notEnabled,
        .isEditing,
        .inactive,
        .visited,
        .updatesFrequently,
    ]

    // MARK: - Interactive Traits

    /// Traits that signal "user can interact with this element".
    ///
    /// Consumed by accessibility projections and diagnostics to classify
    /// advertised interactivity. This classification never gates `activate`.
    public static let interactiveTraits: Set<HeistTrait> = [
        .button,
        .link,
        .adjustable,
        .searchField,
        .keyboardKey,
        .backButton,
        .switchButton,
    ]

    /// Traits that identify an element as a text input surface.
    ///
    /// These traits project to Button Heist's executable `typeText` action.
    /// State traits such as `isEditing` and `textOperationsAvailable` are
    /// intentionally excluded because they do not establish text-entry
    /// capability.
    public static let textInputTraits: Set<HeistTrait> = [
        .textEntry,
        .searchField,
        .secureTextField,
        .textArea,
    ]

    public static func supportsTextEntry(_ traits: some Sequence<HeistTrait>) -> Bool {
        !Set(traits).isDisjoint(with: textInputTraits)
    }

    // MARK: - Static-Only Traits

    /// Traits that are purely descriptive when no independent interaction
    /// evidence is present.
    public static let staticOnlyTraits: Set<HeistTrait> = [
        .staticText,
        .image,
        .header,
    ]

    // MARK: - Synthesis Priority

    /// Trait priority for `heistId` synthesis — the first trait an element
    /// carries from this list becomes its heistId suffix.
    ///
    /// Consumed by `HeistIdAssignment.synthesizeBaseId`. The ordering
    /// is locked by `SynthesisDeterminismTests` — changes to this list are
    /// wire-format breaks and require a coordinated release.
    ///
    /// Ordering rationale: navigation/role-defining traits (`backButton`,
    /// `tabBarItem`) win first because they uniquely identify a screen-level
    /// affordance. Input-shape traits (`searchField`, `textEntry`,
    /// `switchButton`, `adjustable`) come next — they tell the agent what
    /// kind of interaction the element accepts. `header` ranks above the
    /// generic `button`/`link` so a tappable section header synthesizes as
    /// `*_header` (the more identifying role) rather than `*_button`.
    public static let synthesisPriority: [HeistTrait] = [
        .backButton,
        .tabBarItem,
        .searchField,
        .textEntry,
        .switchButton,
        .adjustable,
        .header,
        .button,
        .link,
        .image,
        .tabBar,
    ]

    // MARK: - Matcher Fact Stability

    public static func matcherFactStability(_ fact: AccessibilityMatcherFact) -> AccessibilityFactStability? {
        switch fact {
        case .identifier(let identifier):
            return isStableIdentifier(identifier) ? .identity : nil
        case .label:
            return .identity
        case .value:
            return .state
        case .trait(let trait):
            return stateTraits.contains(trait) ? .state : .identity
        case .excludedTrait(let trait):
            return stateTraits.contains(trait) ? .state : nil
        }
    }

    public static func matcherFactPriority(_ fact: AccessibilityMatcherFact) -> Int {
        switch fact {
        case .identifier:
            return 0
        case .label:
            return 10
        case .trait(let trait):
            return (stateTraits.contains(trait) ? 220 : 20) + matcherTraitPriority(trait)
        case .value:
            return 200
        case .excludedTrait(let trait):
            return 240 + matcherTraitPriority(trait)
        }
    }

    public static func orderedMatcherTraits(_ traits: [HeistTrait]) -> [HeistTrait] {
        traits.sorted { left, right in
            matcherTraitSortKey(left) < matcherTraitSortKey(right)
        }
    }

    package static func matcherFacts(
        label: String?,
        identifier: String?,
        value: String?,
        traits: some Sequence<HeistTrait>
    ) -> [AccessibilityMatcherFact] {
        let traitSet = Set(traits)
        var facts: [AccessibilityMatcherFact] = []
        if let identifier = nonEmpty(identifier) {
            facts.append(.identifier(identifier))
        }
        if let label = nonEmpty(label) {
            facts.append(.label(label))
        }
        for trait in orderedMatcherTraits(Array(traitSet)) {
            facts.append(.trait(trait))
        }
        if let value = nonEmpty(value) {
            facts.append(.value(value))
        }

        if !facts.isEmpty {
            for trait in orderedMatcherStateTraits where !traitSet.contains(trait) {
                facts.append(.excludedTrait(trait))
            }
        }
        return facts
    }

    public static func matcherFacts(for element: HeistElement) -> [AccessibilityMatcherFact] {
        let assertable = element.semantics.assertable
        return matcherFacts(
            label: assertable.label,
            identifier: assertable.identifier,
            value: assertable.value,
            traits: assertable.traits
        )
    }

    public static func matcherIdentityFacts(for element: HeistElement) -> [AccessibilityMatcherFact] {
        matcherFacts(for: element).filter { matcherFactStability($0) == .identity }
    }

    public static var orderedMatcherStateTraits: [HeistTrait] {
        orderedMatcherTraits(Array(stateTraits))
    }

    private static func matcherTraitPriority(_ trait: HeistTrait) -> Int {
        synthesisPriority.firstIndex(of: trait) ?? synthesisPriority.count
    }

    private static func matcherTraitSortKey(_ trait: HeistTrait) -> MatcherTraitSortKey {
        MatcherTraitSortKey(priority: matcherTraitPriority(trait), name: trait.rawValue)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Tab Switch Persistence Threshold

    /// Persistence ratio below which a tab bar content swap counts as a
    /// tab switch (screen change) rather than a scroll.
    ///
    /// When comparing two parses that both contain a tab bar, the parser
    /// computes the fraction of non-tab-bar content labels that persist
    /// across the snapshots. If fewer than this fraction persist, the
    /// transition is classified as a screen change by observation projection.
    ///
    /// Locked at `0.4` by `AccessibilityPolicyTests`. Changes to this
    /// threshold alter screen-change semantics and should be made with a
    /// clear empirical justification.
    public static let tabSwitchPersistThreshold: Double = 0.4
}

private struct MatcherTraitSortKey: Comparable {
    let priority: Int
    let name: String

    static func < (lhs: MatcherTraitSortKey, rhs: MatcherTraitSortKey) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        return lhs.name < rhs.name
    }
}
