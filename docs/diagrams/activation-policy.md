# Activation Policy

The `activate` decision tree uses VoiceOver order. Button Heist first resolves a live semantic target and calls its primary accessibility action.

If that action returns `false`, Button Heist resolves a fresh on-screen target. It then sends one tap at the new activation point.

**Illustrates:** [ACCESSIBILITY-CONTRACT.md](../ACCESSIBILITY-CONTRACT.md), [API.md](../API.md)
**Source of truth:** `ButtonHeist/Sources/TheInsideJob/TheBrains/ActivationPolicy.swift`, `ButtonHeist/Sources/TheInsideJob/TheBrains/AccessibilityActionDispatcher.swift`, `ButtonHeist/Sources/TheInsideJob/TheVault/Interactivity.swift`, `ButtonHeist/Sources/TheScore/AccessibilityPolicy.swift`

```mermaid
flowchart TD
    START["activate action"] --> CHECK["Interactivity.checkInteractivity"]
    CHECK -- "traits contain notEnabled" --> BLOCKED["blocked — element is disabled"]
    CHECK -- "advertises no interactivity and<br/>implements no activation" --> WARN["record weak-target warning:<br/>proceed as VoiceOver would"]
    CHECK -- "otherwise" --> PROCEED["interactive"]
    WARN --> SEMANTIC
    PROCEED --> SEMANTIC["resolve live semantic target<br/>tap geometry is not required"]
    SEMANTIC -- "failure" --> FAIL1["ActionDispatchResult failure<br/>ActivationTrace: axActivateReturned nil,<br/>tapActivationDispatched false"]
    SEMANTIC -- "resolved" --> AXACT["accessibilityActivate()<br/>on the live element"]
    AXACT -- ".success" --> OK1["success, method .activate<br/>ActivationTrace: axActivateReturned true,<br/>tapActivationDispatched false"]
    AXACT -- "live target is stale" --> STALE["target-unavailable failure<br/>no tap"]
    AXACT -- ".refused" --> FALLBACK["resolve the committed target again<br/>require an on-screen activation point"]
    FALLBACK -- "failure" --> FAIL2["geometry or reveal failure<br/>ActivationTrace: axActivateReturned false,<br/>tapActivationDispatched false"]
    FALLBACK -- "resolved" --> DIAG["record implementation introspection<br/>as diagnostic evidence only"]
    DIAG --> TAP["activationPointDispatch at the new declared<br/>activationPoint — not a computed frame point"]
    TAP -- "true" --> OK2["success, method .activate<br/>ActivationTrace: tapActivationDispatched true,<br/>tapActivationPoint, tapActivationSucceeded true"]
    TAP -- "false" --> FAIL3["failure with diagnostic message<br/>ActivationTrace: tapActivationSucceeded false"]
```

Notes:

- `accessibilityActivate()` is the operation that VoiceOver uses. Button Heist calls it before it requires usable tap geometry.
- UIKit defines `false` as “not activated.” Button Heist trusts that result and starts the tap phase.
- The tap phase resolves the committed target again. This phase requires a fresh on-screen activation point.
- A failed tap-phase resolution returns its geometry or reveal failure. The runtime does not send a tap.
- A stale semantic target returns a target-unavailable failure. Staleness does not permit a tap.
- Interface changes do not override the Boolean result. They may come from unrelated work and do not prove that this target activated.
- The activation-point tap completes the same `activate` action through touch injection.
- Every enabled target enters this policy. `notEnabled` is the only difference from VoiceOver.
- Button Heist does not dispatch to a target with this accessibility state. VoiceOver permits the double-tap and lets the app ignore it.
- Override and block introspection supplies diagnostic evidence only. It is not an accessibility semantic or dispatch gate.
- After a decline, this evidence describes the target implementation. It does not permit the tap.
- A weak target warning uses `activation_weak_affordance_evidence`. A later expectation failure keeps this warning in the action result.
- `ActivationTrace` records the path. Its fields describe the AX return, implementation evidence, tap dispatch, tap point, and tap result.
