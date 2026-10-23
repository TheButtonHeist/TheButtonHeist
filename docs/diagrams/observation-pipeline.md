# Observation Pipeline

The Vault owns current accessibility truth and one ordered
`Observation.History`. One `HeistExecution` reducer consumes admitted facts in
authored order and retains all progress for the complete heist.

**Illustrates:** [ARCHITECTURE.md](../ARCHITECTURE.md)

```mermaid
flowchart LR
    Demand["visible or discovery demand"] --> Stream["Observation.Stream<br/>one serialized cycle"]
    Link["TheTripwire CADisplayLink<br/>active capture at most 30 Hz"] --> Admission["TheTripwire.PulseAdmission<br/>bounded render grace and recovery"]
    Touch["successful synthetic touch-up"] -->|"request render grace"| Admission
    Admission -->|"admitted live pulse"| Stream
    Script["Deterministic input<br/>UIKit signal + frame budget"] -->|"injected pulse in logic tests"| Stream
    Callback["one process callback<br/>one MainActor hop"] --> Notice
    Notice["AccessibilityNotificationBus<br/>ordered ingress"] -->|"freeze exact claim"| Stream
    UIKit["UIKit hierarchy"] -->|"capture + parse once"| Stream
    Stream -->|"commit Snapshot + Event"| Vault["TheVault<br/>current phase + Observation.History"]
    Vault -->|"record, then publish"| Host["MainActor host"]
    Host -->|"return ordered Event"| Execution["one HeistExecution reducer<br/>advance private progress"]
    Execution --> Perform["perform(Effect)"]
    Execution --> Wait["wait(WaitRequest)"]
    Execution --> Complete["complete(Completion)"]
    Perform --> Host
    Wait --> Host
    Complete --> Result["HeistResult<br/>step-local Observation.Evidence"]
    Result --> Report["report projection"]
    Report --> Render["JSON / compact / human / JUnit"]
    Stream -->|"record live cycle duration"| Budget["Display-frame budget"]
    Budget -->|"over budget: skip one or two"| Admission
    Stream -->|"acknowledge after commit"| Notice
```

Inside the reducer, action dispatch and wait admission converge on one observed
leaf before any shared observation work begins:

```mermaid
stateDiagram-v2
    [*] --> BeginningAction
    [*] --> BeginningWait
    BeginningAction --> Dispatching
    Dispatching --> Observing: dispatch completed
    BeginningWait --> Observing: predicate admitted
    Observing --> Exploring: viewport work required
    Exploring --> Observing: viewport event admitted
    Observing --> Finishing: outcome reached
    Finishing --> Observing: more proof required
    Finishing --> Committing: terminal evidence complete
    Committing --> [*]
```

`ObservedLeaf` carries either an action with its completed dispatch evidence or
a wait with its predicate. The `observing`, `exploring`, `finishing`, and
`committing` phases therefore have one owner and cannot drift by leaf kind.

One typed pulse starts at most one claim, capture, parse, commit, publication,
and evaluation cycle. Production obtains it from the display-link adapter,
without forcing a Core Animation transaction flush. Active demand caps the
display link at 30 Hz or the screen maximum, whichever is lower. Immediately
before capture, pulse admission skips one pulse after a successful touch-up or
hierarchy change. The next pulse is admitted even during continued hierarchy
changes. A live visible observation cycle longer than one display frame skips
one subsequent capture opportunity. A cycle longer than two frames skips two.
Recovery coalesces with render grace and cannot be extended by further touch
or hierarchy changes. Skipped pulses leave notification claims and capture waiters pending
and publish no event. Periodic captures of the visible accessibility tree continue without notifications.
Deterministic execution authors each pulse directly and never starts a display link.
Pulses arriving during an active synchronous cycle are dropped; a later pulse
starts the next demanded cycle. Zero live demand pauses the display link, so the
runtime is otherwise inert. The Vault constructs
each event and records it before delivery. A snapshot is current truth, an event
is one ordered fact, history is the Vault-owned retained event array, and
evidence is immutable result data. UIKit objects remain at the boundary.

For `.perform`, the host performs the one typed effect and returns its raw
event. For `.wait`, it waits for the next ordered `Observation.Event` or the
reducer-provided absolute deadline. The reducer is deterministic and replayable
from its initial heist, start time, and ordered events.

The reducer owns the active leaf and whole-heist absolute deadlines and projects
the earlier boundary target. Deadlines do not enter observation history. The
host reads the clock, waits, and returns stable-ID facts. The reducer classifies
expiry, requests terminal evidence, and decides whether the result is a leaf or
whole-heist timeout.
