# AGENTS.md

## README.md is protected

The README is the face of this project. Its tone, prose, structure, and argumentative arc were carefully crafted and are not up for rewrite. **Do not restructure, rephrase, or rewrite README.md.** You may:

- Fix factual errors (stale counts, wrong tool names, broken links)
- Fix grammar or typos
- Add a new section if a feature ships that has no README coverage

You may **not**:

- Reorder sections or change the narrative flow
- Rewrite prose to "improve" clarity or tone
- Remove content unless the underlying feature was deleted
- Summarize, condense, or expand existing sections

If you believe the README needs substantive changes, say so and explain why — don't make the edit.

## Button Heist House Style

Button Heist is opinionated, not permissive. New code should make the correct
path obvious, make invalid runtime state hard or impossible to construct, and
keep each concept on one canonical pipeline.

Use these rules as the default review lens:

- Make invalid runtime state unconstructible. Validate external data at
  boundaries; do not build invalid internal values and repair them later.
- Keep strings at the edges. Parse command names, JSON keys, selectors, and
  user input into typed values before core logic sees them.
- Maintain one pipeline per concept: action, result, logging, error, evidence,
  observation, and settlement should each have one owner and one shape.
- Model lifecycle and coordination as explicit state machines or pure reducers.
  Reducers produce state and effects; boundary code performs the effects.
- Treat pipelines as math over snapshots, graphs, and streams. Prefer pure
  transformations over hidden side effects and implicit mutable coordination.
- Treat UIKit objects as live boundary evidence, never durable identity. Durable
  identity is semantic accessibility state, paths, captures, results, and typed
  target descriptions.
- Use one canonical spelling for each concept. Do not add aliases, fallback
  spellings, or compatibility paths unless they represent genuinely different
  semantics.
- Use tuples only as local scratch values. Public, package, stored, or
  cross-file result shapes need named Swift types.
- Use `Any` only at unavoidable Foundation, Objective-C, or private-SPI
  boundaries. Normalize immediately into typed Button Heist values.
- Treat public JSON, results, compact output, CLI output, MCP schemas, and
  `.heist` artifacts as contracts. Do not change them accidentally or hide
  drift behind adapters.
- Update architecture docs and diagrams when responsibility, state-machine,
  wire, result, or language shape changes.

## Canonical Architecture Vocabulary

Use the same nouns and verbs for recurring architectural shapes across every
subsystem. Qualify shared shapes with a domain namespace instead of inventing
domain-specific synonyms: `Observation.Event`, `ClientAdmission.Decision`, and
`InterfaceExploration.Result` should share the meanings below.

Empty enums are the preferred namespace when a family has no instance state.
They may contain nested enums, structs, classes, protocols, and static
operations. Use a protocol with associated types only when generic code must
preserve a relationship between family members; do not use protocols merely as
namespaces.

| Noun | Canonical meaning |
|------|-------------------|
| `State` | The complete durable state of a reducer or lifecycle at one phase. |
| `Snapshot` | An immutable sample of state at one instant. |
| `Event` | An ordered fact that has already occurred. |
| `Command` | A typed request to perform a domain operation. |
| `Request` / `Response` | A transport or public-boundary exchange, not internal control flow. |
| `Decision` | A pure control-flow choice derived from current values. |
| `Effect` | A side effect requested by a reducer and performed at a boundary. |
| `Outcome` | The terminal classification of a completed operation. |
| `Result` | The returned aggregate of outcome, values, and evidence. |
| `Evidence` | Observed facts supporting a result or assertion. |
| `Report` | A human- or tooling-oriented summary derived from results. |
| `Receipt` | A durable contract record of execution. |
| `Baseline` | The selected earlier snapshot used for comparison. |
| `Transition` | The typed relationship between ordered snapshots or events. |
| `Delta` | A derived change projection; never an owner of source truth. |
| `Cursor` | A position in an ordered log or stream. |
| `Window` | A bounded portion of history between cursors or snapshots. |
| `Generation` | An epoch boundary that invalidates cross-generation assumptions. |
| `Projection` | A purpose-specific read or output shape derived from canonical truth. |
| `Store` / `Log` / `Stream` | Current owned truth, retained ordered history, and ordered delivery, respectively. |

Use verbs consistently:

- `parse` converts external syntax into typed syntax; `decode` and `encode`
  implement a wire or storage contract.
- `capture` samples live boundary state; `observe` receives an event or
  snapshot; `settle` waits for live state to become stable.
- `admit` validates relationships and returns an internal value named for its
  admitted domain state;
  `resolve` turns a reference or predicate into a canonical entity.
- `evaluate` computes a predicate or rule without side effects; `reduce`
  applies an event to state and emits decisions or effects.
- `record` appends retained history; `publish` records and delivers an event;
  `commit` updates canonical owned truth.
- `execute` runs a domain command; `dispatch` crosses a platform, process, or
  transport boundary.
- `project` derives a purpose-specific value; `render` turns typed values into
  presentation.

Execution truth, interpretation, and presentation are separate currencies.
Results own execution outcome and evidence; one canonical projector derives a
report; JSON, compact text, human text, and JUnit render that report. Do not add
a parallel result wrapper, report graph, recording status, or wire-only semantic
model when custom `Codable` can project the canonical type directly.

Avoid `get`, `handle`, `process`, `make`, and `build` when a canonical verb
states the operation precisely. Avoid `Builder` and `Factory` type names for
internal architecture; use the domain noun for what the type actually owns, such
as `Collector`, `Accumulator`, `Projector`, `Renderer`, `Parser`, `Admission`,
`Codec`, or `Resolver`. Swift result builders are the exception because
`@resultBuilder` is the language feature name. Platform-boundary injection
closures may describe the boundary they provide, but should still avoid
spreading factory vocabulary into core logic. Reserve `require` and precondition
failures for unreachable programmer errors, never normal pipeline control flow.

## Tuist Project Generation

This project uses [Tuist](https://tuist.io) to generate Xcode projects and workspaces. The generated `.xcodeproj` and `.xcworkspace` files are local artifacts and are not checked into git.

### Project structure

| File | Purpose |
|------|---------|
| `Workspace.swift` | Defines the `ButtonHeist` workspace (includes root project + `TestApp`) |
| `Project.swift` | Root project: TheScore, TheInsideJob, ButtonHeist frameworks + tests |
| `TestApp/Project.swift` | The `BH Demo` test app |
| `Tuist.swift` | Tuist configuration (default) |
| `Tuist/Package.swift` | External dependencies (ArgumentParser, AccessibilitySnapshotParser) |

### When to regenerate

Re-run the canonical generate script after changing any `Project.swift`, `Workspace.swift`, or `Tuist/Package.swift`:

```bash
./scripts/generate-project.sh
```

The script wraps `tuist install && tuist generate --no-open` and then runs `scripts/clean-pbxproj.py` over every generated `project.pbxproj` to strip known dirty patterns: hardcoded `SRCROOT = /Users/...`, duplicate `$(inherited)` entries, and duplicate header / framework / runpath search path entries. The generated projects stay ignored.

Calling `tuist generate` directly still works for quick iteration, but prefer the wrapper before local Xcode builds.

**Never edit `.xcodeproj` or `.xcworkspace` files directly.** Always modify the Tuist configuration (`Project.swift`, `Workspace.swift`, `Tuist/Package.swift`) and regenerate locally. Do not commit generated project or workspace files.

**Never commit hardcoded absolute paths in `.xcodeproj` files.** Xcode resolves `SRCROOT` automatically from the `.xcodeproj` location — never set it explicitly in build settings. Hardcoded paths like `SRCROOT = /Users/...` break builds for every other developer and CI. The cleaner strips these automatically; if you see one survive, investigate the Tuist configuration.

## Canonical Test Runner

Use `scripts/test-runner.py` as the canonical way to run repository test suites locally and in CI. The runner is the sole owner of suite names, schemes, destinations, result bundles, heist result directories, and split build/test execution.

- Do not use `swift test` for normal verification. SwiftPM does not model the hosted iOS test setup correctly and can produce misleading failures in this mixed macOS/iOS repo.
- Do not call `tuist test` or test-driving `xcodebuild` commands directly. Use them only when debugging the runner, Tuist, or Xcode behavior.
- Every mode runs the full suite. The runner drives `xcodebuild` directly and never `tuist test`, which reports a failing suite as `✖ Error` plus a forum link where `xcodebuild` names the test and its assertion.
- The runner selects an explicit iOS simulator and emits its resolved UDID destination. Agents should pass their task slug with `--simulator-name` to preserve simulator isolation.
- CI's build-once optimization uses the runner's `build-for-testing` and `test-without-building` commands. Those commands are full-suite phases and share one deterministic derived-data path.

Recommended commands:

```bash
scripts/test-runner.py run MacFrameworkTests
scripts/test-runner.py run TheInsideJobLogicTests
scripts/test-runner.py run TheInsideJobWindowTests
scripts/test-runner.py run TheInsideJobIntegrationTests
scripts/test-runner.py run HostedBehaviorTests
```

From a clean checkout, install declared dependencies and run a portable suite with:

```bash
scripts/test-runner.py run MacFrameworkTests --install-dependencies
```

### Adding a dependency

1. Add the package to `Tuist/Package.swift`
2. Run `tuist install` to fetch it
3. Reference it in the relevant target with `.external(name: "PackageName")`
4. Run `tuist generate`

### App targets

One app in `TestApp/Project.swift`, embedding TheInsideJob and TheScore:

| App | Bundle ID | Sources | Purpose |
|-----|-----------|---------|---------|
| **BH Demo** | `com.buttonheist.testapp` | `TestApp/Sources/` | SwiftUI demo, UIKit harnesses, and research screens for agents and benchmarking. |

All include a post-build script that copies the `AccessibilitySnapshotParser` resource bundle into the app (workaround for Tuist not handling this automatically).

When adding new screens:
- **Demo screens** (controls, scroll tests, standard UI patterns) go in `TestApp/Sources/` and are wired into `RootView.swift`
- **Research screens** (SPI experiments, trait probing, runtime inspection) also go in `TestApp/Sources/` and are exposed from `RootView.swift`

## No `accessibilityIdentifier` in Demo Screens

`accessibilityIdentifier` is an escape hatch, not a feature. It helps developers write UI tests, but it does nothing for accessibility users — VoiceOver never reads it, Switch Control never sees it, and it actively harms Button Heist's mission. The whole point is to navigate apps through the real accessibility user space: labels, values, traits, hints, and actions. If an element can only be found by identifier, that element is invisible to a real user and the heist should fail.

**Do not add `accessibilityIdentifier` to demo app screens** (`TestApp/Sources/`). Instead, make every element findable by its natural accessibility properties — the same properties a VoiceOver user relies on. This is the bar: if the agent can't find it, a blind user can't either, and the fix is better accessibility, not an identifier.

Research harness screens are exempt when they probe the accessibility tree at the SPI level and use identifiers functionally to locate specific test fixtures.

## Simulator Quick Start

Build and deploy the demo app to an iOS Simulator for end-to-end testing.

### Agent isolation model

Multiple agents run simultaneously, each with their own simulator. The full convention is documented in `.context/bh-infra/docs/MULTI_AGENT_SIMULATORS.md` (if available — clone via `/setup-context bh-infra`). The short version: **simulator name = token = instance ID = `{workspace}-{task-slug}`**.

Every agent must:

1. **Create a dedicated simulator** named `{workspace}-{task-slug}` (e.g. `accra-scroll-detection`)
2. **Launch the app with a unique port and a human-readable token** derived from the same slug
3. **Connect using that port and token** — mismatches are rejected, and the token tells you whose session you hit

The token is not just auth — it's a label. When an agent sees `accra-scroll-detection` in a connection error, it knows immediately whether that's its session or someone else's. Never use UUIDs or opaque strings as tokens.

### 1. Create a simulator for your task

Derive the simulator name and token from your workspace and task:

```bash
# Convention: {workspace}-{task-slug}
TASK_SLUG="accra-scroll-detection"

# Create a dedicated simulator
SIM_UDID=$(xcrun simctl create "$TASK_SLUG" "iPhone 16 Pro")
xcrun simctl boot "$SIM_UDID"
```

The same `TASK_SLUG` is used as the simulator name, the auth token, and the `INSIDEJOB_ID` — everything is self-documenting. Running `xcrun simctl list devices booted` becomes a dashboard of what every agent is doing.

### 2. Build the demo app

```bash
xcodebuild -workspace ButtonHeist.xcworkspace -scheme BH Demo \
  -destination "platform=iOS Simulator,id=$SIM_UDID" build
```

Use the `BH Demo` scheme — this embeds TheInsideJob and all frameworks. Building just the `TheInsideJob` scheme only produces the framework without the app.

### 3. Install and launch

```bash
# Find the freshest build
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/ButtonHeist*/Build/Products/Debug-iphonesimulator/BHDemo.app | head -1)

# Pick a unique port; use the task slug as the token
INSIDEJOB_PORT=$((RANDOM % 10000 + 20000))

# Install and launch (bundle ID: com.buttonheist.testapp)
xcrun simctl install "$SIM_UDID" "$APP"
SIMCTL_CHILD_INSIDEJOB_PORT="$INSIDEJOB_PORT" \
SIMCTL_CHILD_INSIDEJOB_TOKEN="$TASK_SLUG" \
SIMCTL_CHILD_INSIDEJOB_ID="$TASK_SLUG" \
xcrun simctl launch "$SIM_UDID" com.buttonheist.testapp
```

Ports and tokens are dynamic — each agent must generate its own at launch time. Without env vars, the server picks an OS-assigned port and auto-generates a UUID token (visible in console logs). **Never use UUIDs or opaque strings as tokens** — use the human-readable task slug so agents can reason about session ownership.

### 4. Build the CLI and add to PATH

```bash
cd ButtonHeistCLI && swift build -c release && cd ..
export PATH="$PWD/ButtonHeistCLI/.build/release:$PATH"
```

This uses the repo-relative path so it works in any workspace.

### 5. Verify

**If Bonjour works** (no firewall stealth mode):

```bash
timeout 5 dns-sd -B _buttonheist._tcp .
```

Should show an `Add` entry with the app name.

**If Bonjour is broken** (MDM stealth mode — see `docs/BONJOUR_TROUBLESHOOTING.md`):

```bash
BUTTONHEIST_DEVICE="127.0.0.1:$INSIDEJOB_PORT" BUTTONHEIST_TOKEN="$TASK_SLUG" buttonheist session
```

### 6. Teardown

The canonical test runner deletes every dedicated simulator it selects. Split
workflows may pass `--retain-simulator` only while a later step still uses that
simulator, and must finish with:

```bash
scripts/test-runner.py cleanup --simulator-name "$TASK_SLUG"
```

For manually created demo simulators, clean up when the task is complete:

```bash
xcrun simctl shutdown "$SIM_UDID"
xcrun simctl delete "$SIM_UDID"
```

## Pre-Commit Checklist

Before pushing any commit, verify the following:

### 1. Generate Xcode Projects
- **Run the project generator before local Xcode builds** so ignored `.xcodeproj` and `.xcworkspace` files exist and match the Tuist configuration.
  ```bash
  ./scripts/generate-project.sh
  ```

### 2. Build Verification
- **All targets must build successfully.** Run the full build:
  ```bash
  xcodebuild -workspace ButtonHeist.xcworkspace -scheme TheScore build
  xcodebuild -workspace ButtonHeist.xcworkspace -scheme ButtonHeist build
  xcodebuild -workspace ButtonHeist.xcworkspace -scheme TheInsideJob -destination 'generic/platform=iOS' build
  ```
- For device builds, include signing:
  ```bash
  xcodebuild -workspace ButtonHeist.xcworkspace -scheme BH Demo \
    -destination 'platform=iOS,name=Device' -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=YOUR_TEAM_ID build
  ```

### 3. Tests Pass
- **All existing tests must pass.** Run the test suite:
  ```bash
  scripts/test-runner.py run MacFrameworkTests
  scripts/test-runner.py run TheInsideJobLogicTests
  scripts/test-runner.py run TheInsideJobWindowTests
  scripts/test-runner.py run TheInsideJobIntegrationTests
  scripts/test-runner.py run HostedBehaviorTests
  ```
- If tests fail, fix the code or update tests to reflect intentional changes.

### 4. Documentation Up to Date
- **Documentation must reflect the current implementation.** Check these files:
  - `README.md` - Quick start, features, usage examples
  - `docs/API.md` - Public API documentation
  - `docs/ARCHITECTURE.md` - System design and component interaction
  - `docs/WIRE-PROTOCOL.md` - Message format and protocol details
  - `docs/USB_DEVICE_CONNECTIVITY.md` - USB connection guide
- When changing behavior, ports, message formats, or configuration:
  - Update all affected documentation
  - Ensure code examples are correct and runnable
  - Verify Info.plist keys and default values are accurate

### 5. Test Coverage for New Systems
- **Major new features require tests.** When introducing:
  - New message types → Add protocol tests
  - New API methods → Add unit tests
  - New connection paths → Add integration tests
- Tests should be automatable (no manual verification required).

## Testing Philosophy

### One True Way

`scripts/test-runner.py` is the one true way to run tests in this repository.

- `TheScoreTests` and `ButtonHeistTests` are canonical portable suites. `MacFrameworkTests` is the real aggregate scheme used by the consolidated CI lane.
- `TheInsideJobLogicTests` is the unhosted deterministic iOS logic suite.
- `BH Demo`-hosted coverage is split across foreground-window `TheInsideJobWindowTests`, isolated `TheInsideJobIntegrationTests`, and aggregate `HostedBehaviorTests`. The aggregate owns the hosted behavior, dogfood, and adversarial targets and excludes the window target through the runner's canonical projection.
- The runner resolves and records an explicit simulator destination for every iOS suite. Running one suite does not cover the other three.
- Treat `swift test` as a package-debugging tool, not as the source of truth for CI-style verification.

### Test Framework

`TheScore` value-type tests and MCP sync tests use Swift Testing (`@Test` / `#expect`); everything else uses `XCTestCase`. Keep the split consistent — don't port across frameworks opportunistically.

### Determinism First

All unit tests must be fully deterministic — no dependency on running apps, Bonjour discovery, network state, or wall-clock timing. Tests that touch real network or Keychain are **integration tests** and must be clearly labeled as such.

### Mocking Strategy

**Never let real Bonjour discovery or `NWConnection` run in a unit test.** These find live apps on the network, making tests flaky and environment-dependent.

The mock boundary is at the network layer: `DeviceConnecting` and `DeviceDiscovering` protocols. Real `TheFence` and `TheHandoff` are used in tests, but with mock closures injected (`makeDiscovery`, `makeConnection`) so no real network I/O occurs.

TheHandoff receives injectable closures (`makeDiscovery`, `makeConnection`) so tests can inject mock implementations. Default closures create the real `DeviceDiscovery` and `DeviceConnection`.

### What Belongs Where

| Test type | Can use | Must NOT use |
|-----------|---------|-------------|
| **Protocol tests** (TheScore) | Value types, Codable round-trips | Any networking or UIKit |
| **Handler/dispatch tests** (TheFence) | Real TheFence/TheHandoff with mock DeviceConnecting injected via TheHandoff factory, pure arg parsing | Real Bonjour, NWConnection |
| **Connection logic tests** (DeviceConnection) | Message injection, forced isConnected | Real NWListener, real TCP sockets |
| **Auth/session tests** (TheMuscle) | Callback injection | Real networking, real UI alerts |
| **Integration tests** (TLS, Keychain) | Real NWListener on loopback, real Keychain | Must be clearly labeled, must clean up after themselves |

### Naming Conventions

- Unit test files: `{Type}Tests.swift` (e.g., `TheFenceHandlerTests.swift`)
- Integration test files: `{Feature}IntegrationTests.swift` (e.g., `TLSIntegrationTests.swift`)
- Integration tests that require entitlements (Keychain, etc.) must note this in a file-level comment.

## Feature Development: API → Tests → Implementation

New features follow a strict three-phase workflow — define the contract, prove it with tests, then fill in the code.

### Phase 1: Define the API

Start by writing the public types, protocols, and method signatures. This is the contract — what the feature looks like from the outside. Stub out the bodies with `fatalError("not implemented")` or empty returns so it compiles but doesn't work yet.

- Define new enums, structs, and protocol requirements.
- Add method signatures to existing types (TheFence commands, TheHandoff callbacks, etc.).
- Wire up CLI commands and MCP tool definitions as thin shells.

### Phase 2: Write the tests

Write tests against the API you just defined. Every test should fail (red) because the implementations are stubs. This is eating your vegetables — it's the part you do first so the reward at the end is real.

- Unit tests for each new public method or message type.
- Handler/dispatch tests for new TheFence commands.
- Round-trip Codable tests for any new wire types in TheScore.
- Tests define the expected behavior; the implementation must satisfy them, not the other way around.

### Phase 3: Fill in the implementation

Now write the real code until every test goes green. When all tests pass, dessert is served — the feature is done and proven correct.

- Implement one test at a time if helpful; the test suite is your progress tracker.
- Do not skip back to Phase 1 to change the API just to make implementation easier — if the API needs to change, update the tests first.
- A feature is not complete until all tests from Phase 2 pass.

### Why this order matters

Writing tests before implementation keeps the design honest. If a test is hard to write, the API is probably wrong — and it's cheaper to fix the API before the implementation exists. By the time you're writing code in Phase 3, you have a clear target and an automated way to know when you've hit it.

## Git Branch Conventions

- **"main" means `origin/main`**. When instructions or conversation refer to `main`, always use `origin/main`. The local `main` branch may be stale.
- Before creating PRs, diffing, or merging, always `git fetch origin main` first.
- Periodically update local `main` to track `origin/main`: `git checkout main && git pull origin main`.

## Commit Hygiene

- **Always ensure code builds before committing.** Never commit code that doesn't compile or pass basic build checks.
- Run `xcodebuild` to verify the project builds successfully before staging changes.
- Keep commits atomic and focused on a single logical change.
- **Squash merge PRs into main.** When merging a PR to `main`, use squash merge with a single descriptive commit message that summarizes the entire change.

## Strict Build Policy

All targets build with **warnings as errors** (`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`) and **strict concurrency** (`SWIFT_STRICT_CONCURRENCY = complete`). SwiftLint runs as a pre-commit hook (via `scripts/pre-commit`) and in CI as a dedicated job. All three must pass cleanly — no `// swiftlint:disable`, no `@preconcurrency import`, no `nonisolated(unsafe)` escape hatches, no `#warning` left behind.

The pre-commit hook is configured automatically when you run `mise install` (via the `postinstall` hook in `mise.toml`).

The goal is to use the features of the language — structured concurrency, Sendable checking, actor isolation — rather than silencing the compiler. If a warning surfaces, fix the design, don't suppress the diagnostic. If SwiftLint flags a pattern, refactor to satisfy the rule rather than disabling it inline.

When adding or changing code:
- Fix any new warnings introduced by your change before committing.
- Do not raise the SwiftLint `disabled_rules` list or add file-level disable comments.
- Do not weaken the concurrency strictness level for any target.
- If an upstream dependency produces warnings, isolate it behind a wrapper rather than lowering the project settings.

## Type Safety: Enums Over Raw Strings

Prefer typed enums (`enum Foo: String`) over raw strings for any value that has a known set of valid cases — command names, action types, status codes, option values, etc. Convert to and from strings only at system boundaries (CLI argument parsing, JSON deserialization, MCP tool dispatch). Internally, pass the enum everywhere.

- `TheFence.Command` is the canonical example: strings enter via `execute(request:)`, are parsed to the enum at the boundary, and flow as typed values through dispatch and handlers.
- `EditAction`, `SwipeDirection`, `ScrollDirection`, `ScrollEdge` follow the same pattern.
- When adding a new command, action type, or option set: define it as a `String`-backed enum with `CaseIterable` in the appropriate module, not as string literals scattered across switch statements.
- Use `.rawValue` only at serialization boundaries — never compare `.rawValue` against a string literal deeper in the stack.

## Trait Policy: One Source of Truth

`AccessibilityPolicy` (in `ButtonHeist/Sources/TheScore/AccessibilityPolicy.swift`) is the single source of truth for trait-related rules-of-the-world: which traits are transient (state, not identity), which are interactive, which are static-only, and which drive heistId synthesis. UIKit-bitmask projections live in `AccessibilityPolicy+UIKit.swift` (TheVault) and are derived from the `Set<HeistTrait>` policy — they cannot drift.

- If you're tempted to write `if traits.contains(.button) || traits.contains(.link) || ...`, check whether `AccessibilityPolicy` already encodes the rule you're checking.
- If you're tempted to define a local `Set<HeistTrait>` of "state traits" or "actionable traits", read from `AccessibilityPolicy` instead.
- Adding a new transient/interactive/static-only trait is a one-line edit to `AccessibilityPolicy`; every consumer picks it up automatically.
- `synthesisPriority` is wire-format — reordering it changes every synthesised heistId. Locked by `SynthesisDeterminismTests`. Treat changes as a coordinated release.

## Explicit State Machines

Model multi-phase lifecycle as an enum with associated data — not as coordinated optionals and booleans at the class/struct level. The litmus test: if two or more fields co-vary to represent a single "phase", they belong inside an enum case's associated value, not as top-level properties.

**What to watch for:**
- Optional resources that must be non-nil only during certain phases (e.g. `writer: AVAssetWriter?` that exists only while recording).
- Task handles paired with a phase flag (`pollingTask: Task? + isPolling: Bool`).
- Booleans derived from other state (`didLogWarning` that tracks whether an array hit a cap).
- Parallel collections tracking the same entity through lifecycle stages (e.g. `pendingClients: Set<Int>` + `authenticatedClients: Set<Int>` — a client's phase should be a single enum value in one dictionary, not membership in multiple sets).
- Cleanup methods that nil out a dozen fields to return to "idle" — a sign the idle state carries no data but the type allows stale data to linger.

**Rules:**
- Each enum case carries exactly the data valid for that phase. Transitioning between cases is the only way to enter or leave a phase — no partial setup, no stale fields.
- If a phase needs mutable bookkeeping (frame counts, timestamps), put it in a struct and store the struct as the associated value.
- Prefer making impossible states unrepresentable over guarding against them at runtime. A `guard` that checks for an impossible combination is a sign the state model is too loose.
- When an existing type already has a state enum but stores phase-specific data as sibling optionals, refactor the data into associated values on the enum cases.

**Example — before (implicit):**
```swift
var state: State = .idle
var writer: AVAssetWriter?      // non-nil only during .recording/.finalizing
var captureTimer: Task?          // non-nil only during .recording
var startTime: Date?             // non-nil only during .recording/.finalizing
```

**After (explicit):**
```swift
enum State {
    case idle
    case recording(RecordingSession)
    case finalizing(FinalizingSession)
}
```

Where `RecordingSession` and `FinalizingSession` are structs carrying exactly the fields valid for that phase. Canonical examples: `ConnectionPhase`, `ReconnectPolicy`, `RecordingPhase` in TheHandoff.

## Functional Over Imperative

Swift has first-class support for a functional style — value types, enums with associated data, `map`/`compactMap`/`reduce`, `lazy` sequences, result builders, and strong generics. Use them where they make ownership and transformation clearer. Functional syntax is not the invariant: prefer a local mutable accumulator when it preserves linear complexity, early exit, or a natural traversal direction. The goal is code where correctness is structural without hiding cost or control flow.

**Use the language:**

- **Choose the smallest linear collection operation.** Use `map`/`compactMap`/`filter` when each input independently produces an output. Use `reduce` when the accumulator is the meaning of the operation. Use a local `for` loop or `inout` accumulator when the operation needs early exit, path-dependent state, or would otherwise repeatedly copy accumulated collections.
- **`lazy` sequences for substantial multi-step pipelines.** When chaining `filter`/`map`/`compactMap` over large element collections, use `lazy` when it avoids intermediate allocations without obscuring the resulting type or control flow.
- **Enums with associated data as result types.** Instead of returning a tuple of optionals or a struct with fields that are only valid in certain states, return an enum where each case carries exactly its data. `Result<T, E>` is the simplest case; domain-specific enums (like `ResolutionResult`) are better when there are more than two outcomes.
- **One algebraic owner for recursive traversal.** When walking a recursive enum like `AccessibilityHierarchy`, define one canonical fold or traversal operation. Callers provide transformations; they do not switch and recurse independently. Match the algebra to the natural traversal direction and use an internal accumulator when that avoids closure towers or repeated collection concatenation.
- **Struct tokens over parameter sprawl.** When a function needs to capture a snapshot of state (for before/after comparison, deferred processing, etc.), bundle it into a struct. The snapshot type prevents mixing up arguments. Canonical example: `captureBeforeState()` returns a `BeforeState` struct consumed by `actionResultWithDelta(before:)`, replacing four loose parameters.
- **Computed properties over synchronized state.** If a value can be derived from other state, make it a computed property. A cache is acceptable when profiling justifies it — but key the cache on source data (fingerprints, hashes), not imperative "dirty" flags.

**Design principles:**

- **One codepath, not two.** When success and failure need different data in the result, make that difference a parameter (a flag, an optional error kind), not a structural fork. Two codepaths assembling the same result type will inevitably drift.
- **Separate pure reads from side effects.** If a function both queries state and mutates it, split it. Pure reads are testable without setup, composable without ordering constraints, and safe to call speculatively.
- **Declarative predicates over imperative decisions.** Express skip/include/transform decisions as value comparisons (fingerprint equality, set membership), not as stateful flags set at an earlier point. The decision should be auditable from the values alone.

**What to watch for:**
- Repeated `array + [element]`, `[element] + descendants`, or nested concatenation while accumulating a result.
- A closure tower or bottom-up fold used to simulate a naturally top-down traversal.
- A `map`/`reduce` pipeline that hides early exit, repeatedly copies state, or is harder to audit than one local accumulator.
- A `for` loop building a result array when a direct `map` or `compactMap` expresses the same one-to-one transform without additional state.
- Two branches assembling the same return type with overlapping but slightly different logic.
- Functions that take more than 3-4 parameters of "context" that are really a snapshot of state at a point in time — bundle them into a struct.
- A `var didX: Bool` that exists only to prevent doing X twice — derive the need from whether X's precondition still holds.
- Ad-hoc recovery code that patches up inconsistencies created by an earlier imperative step. If you need recovery, the pipeline has a structural gap — fix the pipeline.

## Currency Types: Elements and Targets

Two type families are the currency for referring to UI elements. Use them everywhere — never invent new types to represent a subset of their data.

**Canonical element types** (from AccessibilitySnapshotParser):
- `AccessibilityElement` — a leaf element with label, identifier, value, traits, frame, activation point, and custom actions. This is the parsed representation of a live UIKit accessibility element.
- `AccessibilityHierarchy` — the parser tree: `.element(AccessibilityElement, traversalIndex)` or `.container(AccessibilityContainer, children)`.

**Interface types** (TheInsideJob):
- `InterfaceTree` — the durable, targetable accessibility tree. It owns typed element/container facts plus a value-only viewport capture. It never owns UIKit references. `merging(_:)` is pure last-read-wins: the newer entry replaces the older entry on heistId conflict, and the newer viewport capture wins.
- `InterfaceObservation` — one observed interface value: an `InterfaceTree` paired with the `LiveCapture` for that tree's viewport. The live half contains weak UIKit references and is replaced wholesale on every parse.
- `TheVault` is the owner. It stores `interfaceTree` as targetable truth, `latestObservation` for current live dispatch evidence, and optional `diagnosticObservation` for a failed settle. Do not add another store, index, or projection around these values.

**Target types** (ThePlans wire types):
- `AccessibilityTarget` — how callers refer to a delivered accessibility node: `.predicate(ElementPredicateTemplate, ordinal:)`, `.container(ContainerPredicateExpr, ordinal:)`, `.within(container:target:)`, or `.ref(HeistReferenceName)`. This is the single target currency passed through actions, predicates, `get_interface` subtree selection, TheFence, TheSafecracker, MCP, and CLI. Only TheVault resolves it against live state.
- `ElementPredicate` — the ordered check chain over label, identifier, value, hint, traits, actions, custom content, and rotors. Exclusion is one recursive check shape: `.exclude(.traits([...]))`, `.exclude(.actions([...]))`, etc. String fields use case-insensitive equality with typography folding (smart quotes/dashes/ellipsis fold to ASCII; emoji/accents/CJK pass through). Matching is **exact or miss** — on a miss the resolver returns structured suggestions through the diagnostic path; there is no substring fallback. The same semantics are evaluated by `HeistElement.matches` on the client (TheScore) and `AccessibilityElement.matches` on the server (TheInsideJob), via the shared `ElementPredicate.stringEquals` helper.
- `HeistElement` — the wire representation sent to clients via `get_interface`. Contains heistId, label, value, traits, actions, frame, etc. Built by TheVault from `AccessibilityElement` + heistId assignment. This is a progressive-disclosure view for external consumers.

**Rules:**
- Pass `AccessibilityElement` and `AccessibilityHierarchy` internally when working with parsed accessibility data.
- Pass `InterfaceTree` for target resolution, matching, diffing, and committed interface reads.
- Pass `InterfaceObservation` only when a parse, settle, or exploration step also needs current live evidence.
- Pass `AccessibilityTarget` when referring to an element or container abstractly (all layers above TheVault).
- Do not create wrapper structs, snapshot types, or intermediate representations to hold subsets of these types. If you need a subset, pass the original and read what you need.
- Wire types (`AccessibilityTarget`, `ElementPredicate`, `HeistElement`) cross the Codable boundary. Internal types (`AccessibilityElement`, `AccessibilityHierarchy`, `InterfaceTree`, `InterfaceObservation`, `LiveCapture`) stay inside TheInsideJob.

**Strict off-screen rule**: semantic target resolution reads `InterfaceTree` only. `LiveCapture` can prove current actionability and geometry for an interface element, but diagnostic settle evidence is not targetable by default.

## heistId synthesis is wire-format-stable

`synthesizeBaseId(_:)` in `TheVault.IdAssignment` produces deterministic heistIds derived from element content. **Synthesis is wire format.** Modifications are equivalent to changes to the JSON schema — they break fixture references and the agent's predict-the-heistId pattern that benchmarks rely on. Treat any change to the synthesis rule like a wire-protocol bump.

The contract is locked by `SynthesisDeterminismTests` (property test across 200+ random permutations, plus a regression table of known input → known output). If you find yourself wanting to "improve" the heistId format, run the core `TheInsideJobLogicTests` scheme first — that test exists to make the contract auditable. Any change requires updating the regression table in the same PR.

## Versioning and Releases

There is one version: `buttonHeistVersion` in `ButtonHeist/Sources/TheScore/Wire/Messages.swift`. It uses SemVer (`MAJOR.MINOR.PATCH`), and CLI, MCP, and the iOS server all read it via TheScore. There is no separate "wire protocol version" — the handshake compares the server's and the client's `buttonHeistVersion` for exact equality and rejects on any mismatch. Inside (iOS server) and outside (CLI/MCP) must always be the same release; wire-format changes do not get their own version bump.

`buttonHeistVersion` is bumped only by `scripts/release.sh`. Commits between releases are not releases — the version constant stays put. Treat any temptation to bump the version mid-feature as a sign you're working around the release flow rather than with it. From a clean `main`, the script validates and bumps the source version, builds CLI and MCP, commits and pushes the release source, waits for CI on that exact commit, then tags it. Pushing the tag triggers `.github/workflows/release.yml`, which builds the release artifacts, creates the GitHub release, and updates the Homebrew tap. `scripts/release-readiness.sh` owns optional local preflight; exact-commit main CI is the release gate.

```bash
./scripts/release.sh               # Patch bump: 0.6.28 -> 0.6.29
./scripts/release.sh --minor       # Minor bump: 0.6.29 -> 0.7.0
./scripts/release.sh --major       # Major bump: 0.7.0 -> 1.0.0
./scripts/release.sh 0.7.1         # Explicit version
./scripts/release.sh --tag-current # Publish an already-bumped source version
./scripts/release.sh --dry-run     # Preview only
./scripts/release-readiness.sh     # Run optional local preflight
```

## Callback Isolation Discipline

Public callback typealiases must declare their isolation in the closure type, not in a docstring. The compiler should enforce the isolation contract; documentation drifts.

```swift
// Good
public var onStatus: (@ButtonHeistActor (String) -> Void)?

// Bad — isolation lives in a comment
/// Fires on @ButtonHeistActor.
public var onStatus: ((String) -> Void)?
```

If a callback fires on a non-actor thread (network queue, ObjC runtime), still annotate explicitly: `@Sendable` for non-isolated, or document with the actor specified.

The Bumper rule `buttonheist.callback_isolation` requires stored callback types to declare `@Sendable` or a global actor, including file-local callback aliases.

## Value Isolation and Sendability

Data-only `Sendable` structs and enums should not carry `@MainActor` or `@ButtonHeistActor`; their conformance already permits safe cross-actor transfer. Value types whose behavior or stored values are genuinely actor-bound may declare that isolation when the compiler requires it. Caseless namespace enums that expose UIKit or scene-state helpers are a legitimate example.

If a lock-backed boundary type must use `@unchecked Sendable`, place a safety justification directly above its declaration. Name the synchronization mechanism and the complete mutable state it protects; do not use a lint suppression as the justification.

## Task Lifetime Tracking

Every `Task { ... }` whose handle would otherwise be dropped must be stored at a known lifecycle point and cancelled on teardown. The handle being unobservable is the smell — fire-and-forget tasks contend for shared state and survive past the type that spawned them.

SwiftUI:

```swift
@State private var pendingTask: Task<Void, Never>?

// ...
.onAppear { pendingTask?.cancel(); pendingTask = Task { ... } }
.onDisappear { pendingTask?.cancel() }
```

Actors / `@MainActor` types:

```swift
private var pendingTasks: Set<Task<Void, Never>> = []

private func schedule() {
    let task = Task { /* work */ }
    pendingTasks.insert(task)
    // Tasks are cancelled in tearDown; if you need a task to remove itself
    // from the set on completion, factor that into a helper rather than
    // reaching for an IUO inside the closure.
}

func tearDown() {
    for task in pendingTasks { task.cancel() }
    pendingTasks.removeAll()
}
```

The single-line `Task { @MainActor in self.callback(...) }` bridge is its own anti-pattern — the call site has no handle, no cancellation, no ordering guarantee. Annotate the callback's isolation in its closure type and call it directly.

## One Error Type Per Logical Domain

Don't introduce a new `enum FooError: Error` without first asking whether an existing error type covers the case. The codebase has authoritative error types per layer:

- `TheScore.ServerError` — wire-level errors broadcast from server to client
- `TheHandoff.ConnectionError` — connection lifecycle; also the associated value of `ConnectionPhase.failed` (the type is `Equatable` so the phase compares structurally)
- `FenceError` — CLI/MCP-facing dispatch errors
- `BookKeeperError` — session lifecycle errors

Per-module private errors are acceptable but should be auditable. If a new domain genuinely needs a new error type, document its boundary and what the existing types couldn't carry.

## CLI-First Development

- **The CLI is the canonical test client.** All features must be usable from the command line.
- This enables a full feedback loop for agentic workflows where automated tools can exercise the entire feature set.
- When adding new functionality, ensure corresponding CLI commands or flags are available.

## CLI/MCP Sync Contract

- `buttonheist session` is a thin interface over `TheFence`; the MCP server exposes 25 purpose-built tools that each dispatch to `TheFence`.
- The command source of truth is `TheFence.Command` enum in `ButtonHeist/Sources/TheButtonHeist/TheFence+CommandCatalog.swift`.
- Any command add/remove/rename must update the `Command` enum in the same change.
- MCP tool definitions live in `ButtonHeistMCP/Sources/ToolDefinitions.swift`; keep them in sync with `Command.allCases`.
- For rapid MCP driving: prefer action `delta` responses and only call `get_interface` when context is stale.
- When handoff/session behavior changes, validate both builds in the same branch:
  - `cd ButtonHeistCLI && swift build -c release`
  - `cd ButtonHeistMCP && swift build -c release`

## Feedback Loop Workflow

- **Development and diagnostics should be driven by feedback loops.** Make changes, then validate their output entirely via CLI and tools that an agent can use and verify.
- Avoid workflows that require manual GUI interaction for validation—if an agent can't verify it, automate it until it can.
- Build observability into features so their behavior can be inspected programmatically.

## End-to-End Testing with iOS Simulator

- Follow the **Simulator Quick Start** section above to build, install, and launch the test app.
- After making code changes, rebuild and reinstall using those same steps.
- Verify changes via CLI commands (`buttonheist session`, `buttonheist activate`, `buttonheist action`, `buttonheist screenshot`, etc.) — not manual GUI inspection.

## Benchmark and Validation Harness

The `bh-infra` repo (`.context/bh-infra/`, clone via `/setup-context bh-infra`) contains an agent-driven benchmark and validation harness. It launches Claude with the BH MCP server against the BH Demo app and scores results against expected values across 15 tasks.

### Quick validation after code changes

```bash
cd .context/bh-infra
./pool.sh --validate --workers 3
```

Runs all tasks, bh config, 1 trial each, 3 parallel workers. Exits 0 (pass) or 1 (fail). Use `--min-score 1.0` for strict mode (default 0.5 allows partial credit).

### Full benchmark

```bash
./pool.sh --workers 3 -c bh -n 3 --save-baseline bh-YYYYMMDD-description
```

### Reports and comparisons

```bash
./report.sh results/<run-id>/ --verdict                              # pass/fail gate
./report.sh results/<run-id>/ --baseline bh-20260402-state-machines  # vs stored baseline
./report.sh results/<new-run>/ --compare results/<old-run>/          # two runs
```

Save a new baseline when landing major changes.

## Product and framework naming

- **Product name**: **Button Heist** (colloquially "the button heist"). We are not renaming to TheButtonHeist, Interface Heist, or UI Heist.
- **Formally** (code, API, module): use **TheInsideJob** for the iOS server framework.
- **Colloquially** (prose, chat): "inside job" or "Inside Job" is fine for that framework; don't over-correct.

## AccessibilitySnapshotBH Submodule

The `AccessibilitySnapshotBH` submodule points at our fork (`TheButtonHeist/AccessibilitySnapshotBH`) on `main`. Upstream is `cashapp/AccessibilitySnapshot` (default branch: `main`). Our `main` is rebased on upstream `main` and carries five targeted commits:

1. `elementVisitor` closure on the hierarchy parser + xcodegen project support
2. `Hashable` conformance on `AccessibilityElement`
3. `traitNames` computed property and `fromNames` static method on UIAccessibilityTraits
4. `containerVisitor` closure on the hierarchy parser + `.scrollable(contentSize:)` container type
5. Popover modal sibling fix: traverse from the last modal subview onward (`subviews[lastModalIndex...]`) so popover content presented as a sibling after an empty dismiss region is not dropped

**Rules for this submodule:**
- Only touch files in the hierarchy parser (`Sources/AccessibilitySnapshot/Parser/`).
- Keep changes minimal and targeted — do not modify snapshot testing, examples, or package config.
- When upstream `cashapp/AccessibilitySnapshot:main` updates, rebase our `main` onto the new upstream `main` rather than merging.
- After updating the submodule, run `git submodule update --remote` and commit the new pin.

## Swift File Structure

Every Swift file follows the same section order. Skip sections that don't apply, but never reorder them.

1. **Conditional compilation guards** (`#if canImport(UIKit)`, `#if DEBUG`)
2. **Imports** — system frameworks, then project modules, then third-party. One blank line between groups when there are three or more imports total.
3. **File-level declarations** — loggers, constants, free functions. Never at the bottom.
4. **Primary type declaration** with a DocC summary comment.
5. **Nested types** (`MARK: - Nested Types`) — enums, structs, typealiases. If >30 lines, move to its own file.
6. **Properties** (`MARK: - Properties`) — stored lets, stored vars, computed vars. Grouped by visibility. Properties always come before methods.
7. **Init** (`MARK: - Init`)
8. **Responsibility groups** — each logical responsibility gets its own `MARK: -` section. Name the MARK after what it does, not what it is (`MARK: - Refresh Pipeline`, not `MARK: - Methods`). Within each section: public first, then internal, then private.
9. **Private helpers** (`MARK: - Private Helpers`) — catch-all for small utilities that don't fit a responsibility group.
10. **Conditional compilation closing** (`#endif // DEBUG`, `#endif // canImport(UIKit)`)

Rules:
- No bare methods floating outside of a MARK section (except properties and init).
- Never interleave properties with methods.
- Extensions on the same type in the same file use MARK sections, not `extension` blocks — unless the extension is for a protocol conformance.
- Extension files (`TheBrains+Dispatch.swift`) have a single MARK at the top of the extension body describing their purpose.
- `#endif` comments always say what they close.

## DocC Documentation

DocC comments (`///`) go on the API surface — types, public/internal methods, and public/internal properties that aren't self-evident. Use a one-line summary. Add a longer description only when the behavior isn't obvious from the name and signature.

```swift
/// Resolve a target to a unique element.
///
/// Returns `.resolved` on success, `.notFound` or `.ambiguous` with
/// diagnostics on failure.
func resolveTarget(_ target: AccessibilityTarget) -> TargetResolution {
```

Do NOT document:
- Private methods with self-evident names
- Properties where the type and name say it all
- Code flow that reads clearly
- Closing braces or section separators

Remove noise comments when encountered:
- Empty `// MARK: -` with no text
- `// TODO:` or `// FIXME:` with no actionable content
- Comments that restate the code
- Commented-out code

## Dossier Maintenance

Crew member dossiers live in `docs/dossiers/`. When a PR changes a crew member's responsibilities, adds/removes types, or changes architecture:
- Update the relevant dossier file
- Update `docs/dossiers/README.md` (the overview) if module dependencies change
- Keep diagrams current
