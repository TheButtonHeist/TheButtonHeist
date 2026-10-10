# The Button Heist API

This page documents the public integration contracts and invariants around
The Button Heist. It is not a command or parameter catalog.

Descriptor-owned surfaces are the source of truth for executable behavior:

- [Accessibility Contract](ACCESSIBILITY-CONTRACT.md) - canonical product
  contract, boundary map, and conformance cases
- `buttonheist --help` and `buttonheist <command> --help` - canonical CLI usage
- MCP `tools/list` - MCP adapter tools and input schemas projected from the Fence command contract
- [Wire Protocol](WIRE-PROTOCOL.md) - transport envelopes, handshake,
  authentication, and wire-only examples
- [Heist Format](HEIST-FORMAT.md) - generated heist artifact and plan IR format

## Contract Layers

The Button Heist has one product command contract: `TheFence.Command`. CLI
commands, JSON-lines stdin, MCP tools, and heist execution all route through
that contract. MCP exposes one tool per exposed command, projected from
Fence-owned command descriptors.

The typed `FenceCommandDescriptor` values in `TheFence.Command.descriptors`
solely own public command names, families, connection admission, adapter
exposure, descriptions, timeout semantics, response and failure projections,
input schemas, and MCP annotations. The committed
`tests/fixtures/public-cli-mcp-command-contract.json` is generated from those
descriptors as a release drift sentinel, not a second schema or an authoring
surface. It stores those typed facts and a deterministic schema digest, not a
duplicate schema. Do not hand-edit it. After reviewing an intentional descriptor
change, regenerate it with:

```bash
BUTTONHEIST_UPDATE_PUBLIC_COMMAND_CONTRACT=1 scripts/swift-test-gate.sh \
  ButtonHeistMCP --filter ToolSyncTests.publicCommandContractMatchesCommittedDescriptorSnapshot
```

The raw wire protocol lives one layer lower in TheScore. Wire message
discriminators such as `requestInterface` and `heistPlan` are transport names,
not the public CLI/MCP command namespace. Side-effecting public commands lower
to one-step or composed `HeistPlan`s before crossing the device wire. The full
module map and the wire boundary are drawn in the
[crew map diagram](diagrams/crew-map.md).

## Public Surface Matrix

| Surface | Public status | Entry points | Contract source | Compatibility policy |
|---------|---------------|--------------|-----------------|----------------------|
| SwiftPM products and modules | Public integration surface | `ButtonHeistTesting`, `TheInsideJob`, `ButtonHeist`, `TheScore`, `ThePlans`, `heist-plan` | `Package.swift`, this document, [Swift Heist Authoring](SWIFT-HEIST-AUTHORING.md), and [Wire Protocol](WIRE-PROTOCOL.md) | Released as one product version. `ThePlans` is the single Swift heist authoring and plan module. Use matching package, CLI, MCP, and embedded app builds. |
| Homebrew release | Public install surface | `buttonheist`, `buttonheist-mcp`, `heist-plan`, installed `ThePlans` compiler artifacts | `Formula/buttonheist.rb` and `scripts/release-contract.sh` | Formula and release archives use SemVer `MAJOR.MINOR.PATCH`. |
| CLI commands | Public command surface | `buttonheist <command>` | `TheFence.Command` descriptors and `buttonheist --help` | Command names, CLI exposure, and parameters are descriptor-owned. |
| JSON-lines input | Public CLI session surface | `buttonheist json_lines` | `TheFence.Command` descriptors and command help | Each line is one ordered JSON command and produces one ordered response. MCP-only tools are excluded. Raw plan IR fields are not the public `run_heist` input shape. |
| MCP tools | Public agent tool surface | `buttonheist-mcp` tools | MCP `tools/list` schemas projected from `TheFence.Command` descriptors | Tool names and schemas are descriptor-owned. `perform` is MCP-only and accepts one durable DSL instruction; `run_heist` accepts durable source `plan` or generated `.heist` `path`. |
| `.heist` artifact format | Public generated artifact | `<name>.heist/manifest.json` and `plan.json` | [Heist Format](HEIST-FORMAT.md) | Generated package artifact. Do not hand-author it; regenerate artifacts when the plan or manifest contract changes. |
| Plan DSL/source | Public authoring source | Swift DSL files, canonical ButtonHeist source strings, `heist-plan compile`, `run_heist --plan`, MCP `run_heist(plan:)` | [Swift Heist Authoring](SWIFT-HEIST-AUTHORING.md) and [Heist Format](HEIST-FORMAT.md) | Source must compile to canonical `HeistPlan` IR. MCP and JSON-lines should pass source or paths, not raw IR fields. |
| Config and environment keys | Public runtime configuration | `.buttonheist.json`, `~/.config/buttonheist/config.json`, `BUTTONHEIST_*`, `INSIDEJOB_*` | This document, [Authentication](AUTH.md), and command help | Explicit flags and target config win over environment values where command-specific precedence applies. Unknown keys must fail or be ignored only as documented. |
| Wire compatibility policy | Public transport contract | TheScore newline-delimited TLS JSON | [Wire Protocol](WIRE-PROTOCOL.md) | Exact product-version lockstep. Client and server `buttonHeistVersion` must match exactly; mismatch returns `protocolMismatch` and closes the connection. |

## Swift API Breakage

The former `ButtonHeistDSL` product and module have been removed. Swift heist
authors import `ThePlans` directly; there is no compatibility alias or adapter.
`ButtonHeist` re-exports that authoring module for client applications, but it
does not re-export `TheScore`. Code that names wire, result, or diagnostic
types from `TheScore` must depend on and import that product explicitly.

Action spellings such as `Activate(...)` and `oneFingerTap(...)` are
constructor functions that return one `Action` value. `Action` owns the fluent
`.expect(...)`, `.withoutExpectation(...)`, and `.until(...)` transitions and
produces `HeistContent`; `.withoutExpectation(...)` waives only an additional
authored outcome and still proves terminal no-change evidence. Command and
expectation bookkeeping are not exposed.
`HeistContent` is an opaque authoring fragment with no public step, definition,
diagnostic, or admission-candidate collections. Swift authoring feeds that
fragment into `HeistBuilder`; canonical source is parsed into the same
private recursive `HeistPlan` shape. One root runtime-safety admission then
produces the executable public `HeistPlan`.

CI checks public Swift API compatibility against the latest `v*` release tag
reachable from `origin/main` with:

```bash
scripts/check-swift-api-breaking-changes.sh
```

The script fetches tags and `origin/main`, resolves the newest merged release
tag, and runs SwiftPM's native API breakage diagnostic:

```bash
swift package diagnose-api-breaking-changes "$BASELINE_TAG"
```

Set `BUTTONHEIST_SWIFT_API_BASELINE_TAG` to compare against a specific release
tag locally. The script is strict by default. Intentional source-shape
tightening may use one exact baseline-tag waiver for a coordinated breaking
release. The waiver expires as soon as that release becomes the new baseline,
without forcing compatibility aliases back into the package.
`BUTTONHEIST_SWIFT_API_BREAKAGE_MODE=report` is available for local
investigation only.

### Payload Value Admission

Public ThePlans payload values are admitted when they are constructed, not
repaired when they reach execution. `GestureDuration` accepts only finite
values greater than zero and no more than 60 seconds. `WaitTarget` accepts an
omitted timeout or a finite value greater than zero and no more than the
configured `WaitTimeout` maximum. That maximum defaults to 60 seconds and can
be overridden with `BUTTONHEIST_MAX_WAIT_TIMEOUT`. Immediate predicate
evaluation is a separate operation, not a zero timeout. A timeout above the
maximum is rejected rather than clamped.

Appending text and pasteboard writes require non-empty text. Replacement text
may be empty because that is the typed clear operation. Swift construction,
canonical source parsing, and `Decodable` entry points share the same admission
rules, so a successfully constructed payload needs no later validity check.
`HeistPlanName` and `HeistReferenceName` likewise share one exact Swift-style
identifier grammar; whitespace and invalid spellings are rejected, never trimmed
or repaired by loops, validation, or rendering.

## TheInsideJob

**Import**: `import TheInsideJob`

**Platform**: iOS 16.0+

**Location**: `ButtonHeist/Sources/TheInsideJob/TheInsideJob.swift`

TheInsideJob is the iOS framework embedded in the target app. In debug builds
it auto-starts through the ObjC load hook, reads environment and Info.plist
configuration, starts a TLS TCP listener, and maintains event-driven
accessibility captures.

### Configuration

Environment variables take precedence over Info.plist values.

```bash
INSIDEJOB_DISABLE=true
INSIDEJOB_TOKEN=my-secret-token
INSIDEJOB_ID=my-instance
INSIDEJOB_SESSION_TIMEOUT=30
INSIDEJOB_SCOPE=simulator,usb
INSIDEJOB_FINGERPRINTS=true
```

```xml
<key>InsideJobDisableAutoStart</key>
<false/>
<key>InsideJobToken</key>
<string>my-secret-token</string>
<key>InsideJobInstanceId</key>
<string>my-instance</string>
<key>InsideJobScope</key>
<array>
    <string>simulator</string>
    <string>usb</string>
</array>
<key>InsideJobFingerprintsEnabled</key>
<true/>
```

Default scope is `simulator,usb`. WiFi/LAN exposure is opt-in with
`network`; only that mode requires Bonjour Info.plist entries.
Fingerprints are enabled by default and can also be disabled from code with
`try TheInsideJob.configure(fingerprintsEnabled: false)`.

### Lifecycle

`TheInsideJob.shared` owns the listener, Bonjour advertisement when enabled,
session state, current accessibility state, and event-driven change detection.
Manual `configure`, `start`, and `stop` calls are available for explicit
startup, but normal integrations link the framework and let auto-start do the
work.

Listener setup fails closed when TLS identity or TLS transport parameters
cannot be created.

## Semantic Targeting

`AccessibilityTarget` is the one target language for semantic actions, wait and
action expectations, container queries, descendant scope, CLI/MCP arguments,
and `get_interface` subtree queries. Callers provide semantic identity, not
coordinates. The Button Heist owns the element inflation loop:

1. Resolve the semantic target against current accessibility state.
2. Reveal it if viewport movement is required.
3. Refresh after movement or state change.
4. Acquire fresh live geometry.
5. Dispatch through the command-specific action path.

This applies to activation, adjustable actions, named custom actions, text
focus, and targeted gestures. If identity, element inflation, or live geometry
cannot be proven, the command fails with diagnostics instead of acting on stale
state. The resolution flowchart is drawn in the
[element inflation diagram](diagrams/element-inflation.md); the activation
decision tree is drawn in the
[activation policy diagram](diagrams/activation-policy.md).

Explicit viewport commands are different: `scroll`, `scroll_to_visible`, and
`scroll_to_edge` expose viewport state because moving the viewport is the
caller's intent. They are direct client viewport/debug commands, not HeistPlan
DSL or durable heist primitives, and they execute through direct client
dispatch as public side-effecting commands.

## Accessibility Node Identity

`HeistId` is capture-local runtime identity inside TheInsideJob. It correlates a
committed semantic node with disposable live evidence but does not cross the
public transport as a selector. Public actions, predicates, and subtree queries
use `AccessibilityTarget`. An element target carries
ordered checks for label, identifier, value, hint, traits, actions, custom
content, rotors, recursive exclusion, and optional ordinal. A container target
carries `ContainerPredicate`, and `.within(container:target:)` scopes any
target to descendants of a matching container. Public target nesting is
bounded by the shared public JSON input depth limit.

Container identifiers are orthogonal data on every delivered parser container,
not only semantic-group containers. A container identifier target therefore
matches any parser container type that carries that identifier. The current
delivered tree is the authority for both element and container matches.
TheVault resolves actions, predicates, and `get_interface` subtree requests
directly against its `InterfaceTree`; subtree projection happens only after that
resolution. A delivered `Interface` constructs one validated `InterfaceGraph`
for client matching and formatting. A flattened element list, screen model, or
back map is not a second query model.
Graph admission requires exactly one geometry-and-action annotation for every
element path, so downstream projections consume total element records instead
of repairing or trapping on partial wire data.
A capture-local `HeistId` is not a replay selector or geometry authority.
The string fields may be a single StringMatch or an array of StringMatch values
when one property needs multiple checks; every entry for that property must
match. Prefer ordered `checks` when string checks and trait checks belong in one
predicate chain; use `.traits([...])` for required traits and
`.exclude(.traits([...]))` for rejected traits.

Durable flows use semantic selectors and matchers: label, value, traits,
actions, custom content, rotors, recursive exclusion, an accessibility
identifier where a stable product identifier exists, and ordinal as a
last-resort disambiguator. Labels, values, and traits
carry the contract under test — they are the properties assistive technology
actually reads. Identifiers are fixture plumbing: legitimate for stable product
identifiers and test fixtures, but invisible to every accessibility user. An
element that can only be found by its identifier is an accessibility finding,
not a targeting success; the fix is better accessibility, not a better
identifier. Minimum matcher utilities can derive portable suggestions from
admitted snapshots without depending on transient handles or coordinates.

String selector fields match exact-or-miss: case-insensitive equality after
typography folding (curly quotes, long dashes, ellipsis, and typographic spaces
fold to their ASCII equivalents; emoji, accents, and non-Latin scripts pass
through unchanged). There is no substring fallback — a miss returns structured
near-miss suggestions through the diagnostic path. Broad matching modes
(`.contains`, `.prefix`, `.suffix`) are explicit opt-ins with the same
normalization. `StringMatch` is expressible by string literal, so a string
argument is exact-match sugar. Expression, core, and resolved matcher storage
are not public authoring API. See [Heist language spec](HEIST-LANGUAGE-SPEC.md)
for the full matching contract.

## Snapshots, Observation Events, and Public Deltas

`TheVault.State` is the runtime semantic owner. It atomically commits the
current snapshot and interface tree, appends exact `Observation.Event` values
to one retained `Observation.History`, and advances notification admission.
`Observation.Stream` publishes only the events returned by that commit; readers
cannot receive an event before its snapshot is current Vault truth.

`Observation.History` is the Vault-owned ordered event array. An active heist
protects the history it may still need, and each action or wait establishes its
own private baseline and history position when observation begins.
`Observation.Evidence` is the immutable bounded projection retained by a
result. Events and snapshots carry no cursors, operation identity, or replay
state, and callers cannot supply a temporal boundary.

One internal `HeistExecution` reducer advances the complete heist. Its returned
decision is `.perform(effect)`, `.wait(request)`, or `.complete(completion)`.
The MainActor host performs the typed capture, dispatch, exploration, or
screenshot effect and returns a typed event to the reducer. Actions, waits,
invocation expectations, loops, and conditional selection are private reducer
progress rather than separate executors.

The Vault deterministically reduces admitted snapshots and normalized
notification payloads into `Observation.Event` values before recording and
publishing them. The reducer owns one absolute deadline per active leaf and the
whole-heist deadline. It projects the earlier target to the MainActor host. The
leaf deadline starts before baseline acquisition and covers reveal, dispatch,
ordered predicate evaluation, and the trailing `noChange`; there is no separate
readiness allowance.

Current predicates such as `exists` and `missing` may match the baseline
snapshot immediately. Temporal predicates such as `appeared`, `disappeared`,
and `updated` consume each later history event once in order. Notifications
likewise match only after the active leaf's boundary. A standalone `waitFor`
therefore cannot consume evidence from an earlier action or heist.

A screen boundary emits departure `elementsChanged`, `screenChanged`, and
arrival `elementsChanged` events in that order. Element updates exist only
between snapshots with no intervening screen boundary. A scoped
`screenChanged` notification is authoritative replacement evidence.
Element-change notifications and normalized notification payloads do not veto
replacement inference from parsed snapshots.
Notifications are best-effort UIKit evidence, not a delivery guarantee; their
absence does not by itself prove replacement or stability.

Retained history may span multiple events and retains fast intermediate changes
until evaluation.

`noChange` has no payload. It records that the admitted snapshot has no semantic
or geometry change from the previous committed snapshot within the comparison
tolerance.

Responses may include compact public deltas named `noChange`,
`elementsChanged`, or `screenChanged`. This `delta` is a one-way temporal fold:
it stacks the ordered events, squashes them into endpoint-friendly edits, and
lets a screen marker dominate the final kind. It cannot preserve the ordered
history it folded, so predicates never consume it. The full model
is drawn in the [observation pipeline diagram](diagrams/observation-pipeline.md).

## Interface Rendering Metadata

Public interface JSON responses include `rendering` so machine clients can
distinguish complete captures from bounded projections. The state vocabulary is:

| State | Meaning |
|-------|---------|
| `full` | The response rendered every observed element in the requested projection. |
| `filtered` | The caller requested a scoped projection, such as a subtree, and the response is complete for that scope. |
| `truncated` | The Button Heist intentionally omitted part of an otherwise available projection to keep the response bounded. |
| `sparse` | The runtime had only partial semantic evidence for the screen. Clients may inspect it, but should not treat absence as conclusive. |
| `failed` | The runtime could not produce a usable semantic projection. The response should carry the product error instead of a partial tree. |

The current `get_interface` projection emits `full` or `truncated`.
`filtered`, `sparse`, and `failed` are reserved contract states for scoped or
degraded projections; they must use the same rendering object before they are
exposed. For huge scroll views, The Button Heist bounds each scrollable subtree by
`BH_SCROLL_SUBTREE_ELEMENT_BUDGET` (default `300`, clamped to `0...1000`). A
truncated scroll container keeps its scroll metrics and `observedElementCount`,
renders only the leading elements, and adds a `truncation` object with:

- `state: "truncated"`
- `reasonCode: "scroll-subtree-element-budget"`
- `observedElementCount`
- `renderedElementCount`
- `omittedElementCount`
- `visibleElementBudget`

Compact output mirrors the same decision with a `subtree truncated` line.

Whole-interface public projection is also capped by `BH_TOTAL_NODE_BUDGET`
(default and hard cap `5000`). When this cap is hit, top-level `rendering`
reports:

- `state: "truncated"`
- `reasonCode: "total-node-budget"`
- `observedElementCount`
- `renderedElementCount`
- `omittedElementCount`
- `totalNodeBudget`

Compact output mirrors the same decision with an `interface truncated` line.

Runtime knobs are read from the process that uses them. Scroll exploration
limits are app-side InsideJob knobs; public projection budgets are applied by
TheFence and therefore affect CLI, JSON-lines, and MCP output in the client
process. Test runners may prefix the same names with `TEST_RUNNER_`; the
unprefixed name wins when it is valid.

| Variable | Default | Clamp | Purpose |
|----------|---------|-------|---------|
| `BH_TRIPWIRE_PULSE_HZ` | `10` | `1...120` | Accessibility tripwire polling frequency. |
| `BH_MAX_SCROLLS_PER_CONTAINER` | `200` | `1...2000` | Per-container scroll exploration safety limit. |
| `BH_MAX_SCROLLS_PER_DISCOVERY` | `200` | `1...2000` | Whole-discovery scroll exploration safety limit. |
| `BUTTONHEIST_MAX_WAIT_TIMEOUT` | `60` | finite seconds, at least `30` | Maximum duration accepted by `WaitTimeout`; no additional fixed policy cap. |
| `BH_SCROLL_SUBTREE_ELEMENT_BUDGET` | `300` | `0...1000` | Per-scroll-container public projection budget. |
| `BH_TOTAL_NODE_BUDGET` | `5000` | `0...5000` | Whole-interface public projection budget. |

## TheFence

**Import**: `import ButtonHeist`

**Platform**: macOS 14.0+

**Location**: `ButtonHeist/Sources/TheButtonHeist/TheFence/`

TheFence is the shared orchestration layer for CLI, JSON-lines stdin, MCP, and
heist execution. It owns command parsing, schema validation, connection
coordination through TheHandoff, typed responses, heist planning, expectations,
results, and replay integration.

Raw command key/value envelopes exist only at routing and Fence admission.
Admission produces a `FenceOperationRequest`; execution and transport lowering
consume typed commands, targets, predicates, and action values rather than
re-reading the raw dictionary.

Use `buttonheist --help`, `buttonheist <command> --help`, and MCP
`tools/list` for command names, parameters, and MCP input schemas. Those
surfaces are projected from the Fence command descriptors.

### Command Invariants

- `connect` verifies transport, handshake/authentication, and session
  ownership. Observation still starts with `get_interface`.
- `perform` accepts one durable ButtonHeist DSL instruction.
- `run_heist` accepts a durable source plan string or generated `.heist`
  package at public boundaries; execution uses the typed `HeistPlan` contract
  after source/package loading. Its whole-heist `timeout` is optional and
  defaults to 60 seconds.
- Root names, definition paths, and invocation paths enter core logic as
  `HeistPlanName`, `HeistDefinitionPath`, and `HeistInvocationPath`. Literals
  are typed authoring sugar; dynamic JSON, source, and CLI strings are
  validated once at admission.
- Swift compiler entries follow the same rule through `HeistEntrySymbol`;
  validation and lint locations remain `HeistPlanPath` values until rendered
  into diagnostics or public response JSON.
- `validate_heist` applies the same plan and root-argument admission entirely
  offline. It returns plan, invocation, and lint results plus canonical source
  for admitted plans. Invalid candidates are typed validation responses, not
  transport failures.
- Commands that support `expect` validate the expectation against the action
  result and report the observed outcome.
- Typed responses serialize to human, compact, and JSON forms from the same
  response models.

## TheHandoff

**Import**: `import ButtonHeist`

**Platform**: macOS 14.0+

**Location**: `ButtonHeist/Sources/TheButtonHeist/TheHandoff/`

TheHandoff owns client-side connection lifecycle: discovery, direct/named
target resolution, TLS trust, authentication, session state, keepalive, and
bounded reconnect.

Connection diagnostics are exposed as product-level failures: transport
failure, auth failure, session lock, protocol version mismatch, missing token,
backlog
overflow, no discovered device, or no matching target.

Named targets live in `.buttonheist.json` or
`~/.config/buttonheist/config.json`:

```json
{
  "targets": {
    "demo": {
      "device": "<host>:<port>",
      "token": "my-token"
    }
  },
  "default": "demo"
}
```

Configs are strict. Removed fields such as `certFingerprint` are invalid, even
when the file is discovered from a default config path.

## ButtonHeistMCP

**Location**: `ButtonHeistMCP/`

**Binary**: `buttonheist-mcp`

ButtonHeistMCP exposes MCP tools projected from `TheFence.Command`. The live
MCP `tools/list` response is the source of truth for tools and schemas.

Runtime behavior:

- JSON-RPC over stdio
- One reused `TheFence` instance per MCP server process
- Auto-reconnects to the device on the next tool call after disconnect
- Returns compact text as the first-glance summary and the same public JSON
  response as MCP `structuredContent`
- Returns screenshots as artifact paths by default
- Requires explicit, size-bounded inline screenshot opt-ins
- Exposes `validate_heist` without requiring a configured device, connection,
  or Button Heist session

Environment variables:

| Variable | Description |
|----------|-------------|
| `BUTTONHEIST_DEVICE` | Default device filter or named target |
| `BUTTONHEIST_TOKEN` | Auth token |
| `BUTTONHEIST_DRIVER_ID` | Driver identity for session locking |
| `BUTTONHEIST_SESSION_TIMEOUT` | MCP idle disconnect timeout (`0` disables it) |

## CLI

**Location**: `ButtonHeistCLI/`

**Binary**: `buttonheist`

The CLI is an adapter over TheFence. Run `buttonheist --help` and
`buttonheist <command> --help` for descriptor-backed local usage text.

Common environment variables:

| Variable | Description |
|----------|-------------|
| `BUTTONHEIST_DEVICE` | Default device filter or named target |
| `BUTTONHEIST_TOKEN` | Auth token |
| `BUTTONHEIST_DRIVER_ID` | Driver identity for session locking |
| `BUTTONHEIST_SESSION_TIMEOUT` | Default idle timeout for `buttonheist json_lines` (`0` disables it) |

Flags take precedence over environment variables.
Session idle timeout accepts `0` as the explicit disabled state. Positive
session and connection timeouts must be finite. A present malformed, negative,
or non-finite value fails configuration instead of silently selecting a
default.

### Notifications

`buttonheist get_notifications` reads the ordered
`[Observation.Notification]` projection retained in the Vault's canonical
history. Each notification contains normalized `text`, element `semantics`, or
both. The response does not expose observer health, raw UIKit notification
kinds, ingress sequence values, timestamps, or unresolved UIKit objects.

## Data Model Notes

### ButtonHeistTesting and XCTest Failures

Async `runHeist` APIs throw. XCTest-facing synchronous helpers preserve the
caller's file and line and route every reported failure through the single
`recordHeistXCTestIssue` path, whose only XCTest emission is `XCTFail`.

Every in-process `Heist` and `runHeist` entry point accepts a typed
`HeistTimeout`. The default is 60 seconds. Finite positive values have no policy
maximum. The same value crosses the device wire for CLI and MCP execution; the
client derives only transport headroom around that app-owned deadline.

### Interface

`Interface` is the accessibility capture returned to clients. Its public JSON
shape carries a canonical tree plus ButtonHeist annotations. Flat element
lists are projections for formatting and matching, not a second wire truth.

Each eligible element in summary and full `get_interface` JSON has an optional
`target`. This is the canonical `AccessibilityTarget` selected from the same
captured interface. Clients should keep it as opaque JSON and send it back for
actions, waits, assertions, or subtree queries. The target is valid for that
captured app state; it is not a permanent element ID.

The Fence selects targets before it applies public tree limits. An ordinal can
therefore refer to a matching element that is absent from a truncated response.
Elements without supported matcher facts omit `target`.

### HeistElement

`HeistElement` is a public value projection of parser content. Use its semantic
fields to construct `AccessibilityTarget` values for actions, durable heist
fixtures, scripts, and replay; internal capture identity is not a public target.

### ActionResult

`ActionResult` owns a typed `outcome`, one `ActionResult.Payload`, optional
message, and outcome-bound evidence. Each payload case determines its action
method and carries only the command-specific value legal for that method;
custom `Codable` projects that value directly to the public `method` plus
an optional `payload` value. There is no separate semantic or wire payload
wrapper. The pure heist reducer records one `ActionDispatchResult` and the
ordered observation evidence for its active leaf. The result projector derives
the public action result from that reducer-owned truth without a post-action
wait or parallel result shape. Failures carry
their typed action failure inside `outcome.failureKind`. Fence result projections
add an expectation result when requested and derive a public delta from the
same observation evidence.

Source construction uses `ActionResult.success` and `ActionResult.failure`,
passing `observation`, `subjectEvidence`, and performance `timing` directly.
Activation results that carry an `ActivationTrace` use the fixed-method
`activationSuccess` and `activationFailure` factories. Success and failure
evidence values are output projections, not assembly inputs; successful
activation and text-entry warnings are derived from the method and subject.

Standalone announcement observations carry `ActionAnnouncementText`, and
durations carry `ElapsedMilliseconds`; dynamic values enter
through their throwing validating initializers, while valid literals remain
concise. `ServerError` likewise accepts `ServerErrorMessage` and an optional
`ServerErrorRecoveryHint`. These typed values reject empty text and negative
durations before result construction without changing their JSON
string and integer shapes.

Wait results are not actions and never embed `ActionResult`. Matched wait facts
carry `Observation.Evidence` and `ExpectationResult.Met`; unmatched wait facts
carry the same observation evidence and the unmet `ExpectationResult`.
`HeistWaitCompletion` owns whether the wait passed, failed, or was aborted by
an else-body child. Passed evidence is the closed `matched` or `handledElse`
enum, while failed and child-aborted completions carry unmatched facts
directly.

For `elementsChanged`, public responses include concrete semantic edits under
`delta.edits.added`, `delta.edits.removed`, and `delta.edits.updated` when
present. For `screenChanged`, public responses include the destination
`delta.newInterface`. Agents should inspect those payloads before deciding
whether the action achieved its intended state or merely observed scroll/loading
churn. Compact text is progressive: successful heist steps summarize the delta
kind, while failed steps include concrete evidence lines when observation evidence is
available.

### Expectations

Expectations use the concrete `AccessibilityPredicate` root with the
`ScreenPredicate` and `ElementAssertion` types. At the root, the valid forms are
`exists`, `missing`, `notification`, and `changed`. `notification` carries only
optional `text` and `element` fields. `changed` requires a `scope`: `screen`
carries an optional `match`, while `elements` carries an `assertions` array:

```json
{"type":"notification","text":{"mode":"contains","value":"Payment complete"},"element":{"checks":[{"kind":"label","match":{"mode":"exact","value":"Receipt"}}]}}
```

```json
{"type":"changed","scope":"screen","match":{"mode":"exact","value":"Receipt"}}
```

```json
{"type":"changed","scope":"elements","assertions":[{"type":"appeared","target":{"checks":[{"kind":"label","match":{"mode":"exact","value":"Receipt"}}]}}]}
```

Elements assertions permit current-tree `exists` and `missing` plus temporal
`appeared`, `disappeared`, and `updated`.
Current-tree predicates use the same `AccessibilityTarget` object as actions and
subtree queries. Both `WaitFor` and action `.expect` therefore accept element,
container, or descendant-scoped presence targets. Container presence uses a
container target:

```json
{"type":"exists","target":{"container":{"checks":[{"kind":"identifier","match":{"mode":"exact","value":"Checkout"}}]}}}
```

Scoped targets use `{"container":{"checks":[...]},"target":{...}}`. Element
update assertions use `before` and `after` matcher objects for the property
change; raw `from`/`to` fields are not accepted. Old `change`, `scopes`,
`screenChanged`, flat element/container predicate fields, aliases, and fallback
spellings are rejected rather than adapted.

Action-linked evidence is a runtime detail. It does not add Swift authoring
options, wire controls, or public result fields.

## Minimal Integration

```swift
import SwiftUI
import TheInsideJob

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

For command details, use `buttonheist --help`, `buttonheist <command> --help`,
and MCP `tools/list`.
