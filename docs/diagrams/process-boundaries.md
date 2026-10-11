# Process Boundaries

Button Heist in-process versus the out-of-process drivers. Out-of-process automation must serialize a snapshot of the accessibility tree across an IPC boundary and synthesize input at computed coordinates; Button Heist holds the live element in the same process and asks it to activate the way assistive technology does. This diagram answers "why does running inside the app matter?"

**Illustrates:** [WHY-IN-PROCESS.md](../WHY-IN-PROCESS.md), [ARCHITECTURE.md](../ARCHITECTURE.md)
**Source of truth:** `ButtonHeist/Sources/TheInsideJob/TheVault/LiveCapture.swift`, `ButtonHeist/Sources/TheInsideJob/TheBrains/AccessibilityActionDispatcher.swift`, `ButtonHeist/Sources/TheInsideJob/TheBrains/ActivationPolicy.swift`, `AccessibilityHierarchyParser` from the pinned `AccessibilitySnapshotBH` package

```mermaid
flowchart TD
    subgraph oop["Out-of-process drivers"]
        direction TB
        TESTPROC["test runner process"]
        IPC["IPC round-trip<br/>per query, per action"]
        SNAP["XCUIElementSnapshot —<br/>serialized copy of the tree,<br/>stale the moment it is made"]
        SYNTH["synthesized tap at a<br/>computed hittable point"]
        APPA["app process"]
        TESTPROC --> IPC
        IPC --> SNAP
        SNAP --> SYNTH
        SYNTH --> APPA
    end

    subgraph inproc["Button Heist (in-process)"]
        direction TB
        SERVER2["TheInsideJob server<br/>inside the app process"]
        PARSE2["recursiveAccessibilityHierarchy()<br/>fresh parse of the real tree"]
        REF["LiveCapture.ElementRef —<br/>weak reference to the live<br/>UIKit accessibility element"]
        ACTIVATE["accessibilityActivate()<br/>then tap at the element's own<br/>declared activationPoint"]
        SERVER2 --> PARSE2
        PARSE2 --> REF
        REF --> ACTIVATE
    end
```

Notes:

- The copy is made at the IPC boundary: out-of-process tools can only ever see a serialized snapshot, because iOS has no public cross-process live-tree API. Button Heist never crosses that boundary — the wire carries commands and results, not the tree walk.
- The live element is held in `LiveCapture.ElementRef` as a weak reference, captured per parse and invalidated on the next parse — live access without keeping UIKit objects alive past their lifetime.
- Activation goes through the element's own contract: `accessibilityActivate()` first (what VoiceOver invokes), and on decline a tap at the element's **declared** activation point — not a hittable point computed from the frame (see [activation-policy.md](activation-policy.md)).
- The parser is the pinned `AccessibilitySnapshotBH` package — the same tree walk assistive technology semantics are derived from, run in-process on demand.
