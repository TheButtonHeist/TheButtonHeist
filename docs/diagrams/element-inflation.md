# Element Inflation

How an `AccessibilityTarget` resolves in the delivered tree and, for actions,
becomes a live actionable element. The same resolver also serves predicates and
`get_interface` subtree queries.

**Illustrates:** [ARCHITECTURE.md](../ARCHITECTURE.md), [API.md](../API.md), [HEIST-LANGUAGE-SPEC.md](../HEIST-LANGUAGE-SPEC.md), [SCOPE-AND-LIMITS.md](../SCOPE-AND-LIMITS.md)
**Source of truth:** `ButtonHeist/Sources/ThePlans/Model/AccessibilityTarget.swift`, `ButtonHeist/Sources/ThePlans/Model/ElementPredicate.swift`, `ButtonHeist/Sources/TheInsideJob/TheVault/TheVault+TargetResolution.swift`, `ButtonHeist/Sources/TheInsideJob/TheBrains/ElementInflation.swift`, `ButtonHeist/Sources/TheInsideJob/TheBrains/ElementInflation+SemanticReveal.swift`, `ButtonHeist/Sources/TheInsideJob/TheBrains/ElementInflation+Geometry.swift`

```mermaid
flowchart TD
    TARGET["AccessibilityTarget<br/>predicate · container · within · ref"] --> SCOPE["resolve against current<br/>delivered Interface tree"]
    SCOPE --> KIND{"target kind"}
    KIND --> MATCH["element checks<br/>label · identifier · value · hint<br/>traits · actions · content · rotors"]
    KIND --> CMATCH["container checks<br/>identifier on any container type<br/>semantic · role · scroll · modal"]
    KIND --> WITHIN["resolve container scope,<br/>then descendant target"]
    CMATCH --> RESOLVEDNODE["resolved container node"]
    WITHIN --> MATCH

    MATCH -- "0 matches" --> NOTFOUND[".notFound(TargetNotFoundFacts)<br/>reason .noMatches<br/>+ interface elements in scope as suggestions"]
    MATCH -- "1 match, no ordinal" --> RESOLVED[".resolved(InterfaceTree.Element)<br/>selected in this capture"]
    MATCH -- "2+ matches, no ordinal" --> AMBIG[".ambiguous(TargetAmbiguityFacts)<br/>first candidates listed —<br/>ordinal required to proceed"]
    MATCH -- "ordinal given, in range" --> RESOLVED
    MATCH -- "ordinal given, out of range" --> NOTFOUND2[".notFound<br/>reason .ordinalOutOfRange / .ordinalNegative"]

    RESOLVED --> BOUNDARY{"will inflation cross<br/>a capture boundary?"}
    BOUNDARY -- "no" --> CURRENT["join selected element's current HeistId<br/>to current live UIKit evidence"]
    BOUNDARY -- "yes" --> ADMIT["remove terminal ordinal and resolve<br/>against the complete committed tree"]
    ADMIT -- "unique match is selected element" --> IDENTITY["AdmittedSemanticTarget<br/>ordinal-free target + semantic scroll path"]
    ADMIT -- "missing, ambiguous,<br/>or different element" --> MISS["inflation failure with diagnostics<br/>no live handoff"]

    IDENTITY --> BUDGET["receive the reducer-projected<br/>boundary deadline through the host"]
    BUDGET --> GRAPH["walk semantic ancestor graph<br/>outermost-first"]
    GRAPH --> SEED["captured content point +<br/>semantic owner"]
    SEED --> OWNER{"exactly one matching owner<br/>in current capture?"}
    OWNER -- "yes, current path" --> POINT["dispatch point reveal<br/>through viewport transition"]
    OWNER -- "no: missing or ambiguous" --> PAGE["skip coordinate and page<br/>an available ancestor"]
    POINT --> COMMIT["capture and commit<br/>the resulting viewport"]
    PAGE --> COMMIT
    COMMIT --> RERESOLVE{"resolve admitted semantic target<br/>in this committed InterfaceTree"}
    RERESOLVE -- "one match" --> CURRENT["adopt this capture's current HeistId<br/>and live reference"]
    RERESOLVE -- "missing or ambiguous" --> MISS
    CURRENT --> MORE{"more viewport movement<br/>required?"}
    MORE -- "yes" --> GRAPH
    MORE -- "no" --> STABLE["stabilize frame + activationPoint<br/>under the same deadline"]
    STABLE -- "fresh committed capture" --> RERESOLVE
    STABLE -- "stable and onscreen" --> COMPLETION{"inflation completion"}
    COMPLETION -- "action" --> ACT["retain viewport and hand off LiveActionTarget<br/>for current-capture HeistId"]
    COMPLETION -- "observation" --> RESTORE["restore origin through viewport transition<br/>under the same deadline"]
    STABLE -- "deadline / offscreen" --> MISS
    MISS --> RESTORE
```

Notes:

- Resolution reads the **interface tree only** (`TheVault.interfaceTree`). Live capture proves current actionability and geometry for an interface element; it is not a second search space.
- Container-only targets are valid for predicates and subtree queries. Element-
  only actions reject a resolved container with a typed target-kind error.
- `ElementInflation` owns its reveal transaction through completion. Actions
  retain the revealed viewport on success and attempt restoration on failure.
  Element inflation for observation attempts restoration after either outcome and
  returns the typed restoration outcome. Wait orchestration adds no outer
  viewport transaction. Container inflation and exhaustive wait search
  orchestration remain follow-up work.
- Matching is **exact or miss**: string checks are case-insensitive with typography folding (smart quotes, dashes, ellipsis fold to ASCII), traits compare as sets. On a miss the resolver returns structured facts — the interface elements in scope — through the diagnostic path; substring matching is not part of resolution.
- A capture-local action can join the selected element's current `HeistId`
  directly to live UIKit evidence. Before any cross-capture reveal, inflation
  admits an `AdmittedSemanticTarget` only when the selected target without its
  terminal ordinal uniquely resolves to that same element in the complete
  committed interface.
- `AdmittedSemanticTarget` is the sole identity retained across committed
  captures. After every viewport transition or other fresh committed capture,
  inflation re-resolves it and adopts only the matching element's current
  `HeistId` and live reference for geometry and dispatch. Missing or ambiguous
  resolution fails; a stale id or newly visible sibling cannot take over.
- `HeistExecution` owns the leaf and whole-heist deadlines. The host passes the
  earlier boundary target through dispatch, inflation, nested reveal, refresh,
  navigation, and geometry stabilization. Nested reveal follows the semantic ancestor graph
  outermost-first and never derives a second budget from that graph.
- A known semantic target that later gains scroll membership earns at most one
  direct reveal attempt. Its captured content point and producing scroll
  container are one evidence value. The runtime must find exactly one matching
  live owner immediately before point dispatch. The owner's path may change. A
  missing or ambiguous owner cannot donate its coordinate to an ancestor or
  sibling and instead selects the established ancestor paging route. Point
  reveal and paging both use the canonical viewport transition, observation,
  Vault commit, and target re-resolution pipelines. Content absent from admitted
  semantic truth cannot be revealed, and exploration never scans for an old
  `HeistId` as identity.
- The ordinal is a capture-local disambiguator over a semantic base selector,
  never durable identity. A target that becomes unique only through its terminal
  ordinal cannot be admitted across a capture boundary.
