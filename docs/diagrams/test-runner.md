# Test Runner

The canonical runner owns suite names, schemes, destinations, selection,
derived data, result bundles, evidence collection, and simulator cleanup.
Callers choose a suite and mode; they do not assemble an `xcodebuild` command
or manage simulator lifecycle themselves.

**Illustrates:** [ARCHITECTURE.md](../ARCHITECTURE.md)

**Source of truth:** `scripts/test-runner.py`,
`scripts/select-ios-ci-simulator.py`, `.github/workflows/ci.yml`

## One execution path

```mermaid
flowchart TD
    Request["Runner request<br/>mode + suite + selection + task slug"]
    Catalog["Canonical suite catalog<br/>scheme + platform + host settings"]
    Paths["Deterministic task + suite paths<br/>derived data + xcresult + heist evidence"]
    Destination{"Suite platform"}
    Mac["Explicit macOS destination"]
    Runtime["Admit iOS runtime"]
    Simulator["Dedicated named simulator<br/>explicit UDID destination"]
    Command["One generated test command"]
    Wrapper["Result-recording wrapper"]
    Phase["Supervised build or test phase<br/>bounded timeout + process-group termination"]
    Evidence["xcresult + heist results + diagnostics"]
    Record["Run record<br/>source SHA + cleanliness + outcome + test count"]
    Cleanup["Shutdown and delete every matching simulator"]

    Request --> Catalog --> Paths --> Destination
    Destination -->|macOS| Mac --> Command
    Destination -->|iOS| Runtime --> Simulator --> Command
    Command --> Wrapper --> Phase --> Evidence --> Record
    Simulator --> Cleanup
    Phase -->|failure or timeout| Cleanup
    Record --> Cleanup
```

Every mode runs the full suite through `xcodebuild`.
CI's build-once lanes use `build-for-testing` followed by
`test-without-building` against the same deterministic derived-data path.
`--simulator-name` or `BUTTONHEIST_TEST_SIMULATOR_NAME` scopes build and
artifact roots for both platforms. Each concurrent worker uses a distinct
slug; split phases reuse one slug. Unnamed runs retain suite-only paths and
run sequentially. CI failure uploads include the same task scope.
Every completed test phase must produce a nonzero test count from its result
bundle; a successful process with no executed tests is inconclusive, not green.

## Runtime admission

```mermaid
flowchart TD
    ActiveSDK["Active iOS Simulator SDK"]
    Request["Optional requested runtime"]
    Installed["Installed available iOS runtimes"]
    Filter["Keep runtimes at or below the active SDK"]
    Exact{"Runtime requested?"}
    Requested["Require the exact requested runtime"]
    Newest["Choose the newest compatible runtime"]
    Device["Prefer the requested iPhone device type<br/>otherwise use a compatible iPhone"]
    Existing{"Named simulator exists?"}
    Reuse["Reuse its admitted UDID"]
    Create["Create a dedicated named simulator"]
    Guard["Runner verifies the selected OS<br/>does not exceed the active SDK"]
    Execute["Boot and execute suite"]
    Reject["Fail before test execution"]
    Delete["Shutdown and delete by UDID and name"]

    ActiveSDK --> Filter
    Installed --> Filter
    Request --> Exact
    Filter --> Exact
    Exact -->|yes| Requested
    Exact -->|no| Newest
    Requested -->|missing or too new| Reject
    Requested --> Device
    Newest -->|none compatible| Reject
    Newest --> Device
    Device --> Existing
    Existing -->|yes| Reuse --> Guard
    Existing -->|no| Create --> Guard
    Guard -->|valid| Execute --> Delete
    Guard -->|too new| Delete --> Reject
```

The runtime ceiling comes from the active SDK, not the newest runtime installed
on the machine. An explicit runtime remains configurable but cannot exceed that
ceiling. Simulator names are task-readable ownership labels; cleanup checks the
selected UDID and removes every remaining simulator with the same name so a
failed run cannot leak an ambiguous future destination.

## CI ordering

```mermaid
flowchart LR
    PR["Pull request SHA"] --> Contracts["Release contracts"]
    PR --> Mac["macOS + CLI + MCP + plan compiler"]
    PR --> Core["Deterministic iOS core + demo smoke"]
    PR --> Hosted["Hosted behavior canaries<br/>Source and prebuilt app conformance"]
    Contracts --> Merge{"All required lanes green"}
    Mac --> Merge
    Core --> Merge
    Hosted --> Merge
    Merge --> Main["Squash merge SHA"]
    Main --> MainLanes["Repeat required lanes"]
    MainLanes --> Integration["Genuine iOS integration"]
    Integration --> Exact["Exact-SHA adversarial validation"]
```

Pull-request evidence is necessary but not sufficient. The `main` push reruns
the regular matrix, then gates genuine integration and exact-SHA adversarial
validation on that immutable merge commit.
