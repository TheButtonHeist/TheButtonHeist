# The Button Heist MCP agent guide

The Button Heist drives iOS apps through the settled accessibility interface. When the app exposes a complete accessibility contract, agents can target declared labels, identifiers, values, traits, and actions instead of calculating screen coordinates.

## Durable boundary

`HeistPlan` is the durable DSL artifact boundary. Anything intended for
storage, `.heist` packaging, discovery, composition, replay, or canonical
rendering MUST be represented as a validated `HeistPlan`.

`run_heist` MUST receive a durable plan: canonical ButtonHeist source whose top
level is `HeistPlan`, or a generated `.heist` artifact path. `perform(step:)`
MUST receive exactly one durable DSL step. Runtime wire JSON IR is
internal/generated and MUST NOT be used as the authoring language.

Observation and session tools are direct client commands. Non-durable viewport
and debug action types remain outside MCP's durable `perform` surface and MUST
NOT appear inside `HeistPlan` source or `.heist` artifacts.

## Core loop

1. **Read** — `get_interface` returns the app accessibility state with labels, values, traits, actions, canonical element targets, and capture-local diagnostic annotations.
2. **Act** — use `perform(step:)` with one durable ButtonHeist DSL step for ordinary app controls. Always attach `.expect(...)` when you know what should change.
3. **Read the response** — tool text is the concise summary; `structuredContent` carries the full public JSON result. If the delta answers your question, skip `get_interface`.
4. **Wait if needed** — when the delta shows a transient state, call `perform(step:)` with one `WaitFor(...)` statement. The server checks the current settled state first, then watches settled accessibility state until the predicate is true.
5. **Repeat** — only re-fetch when you need elements you haven't seen.

## Choosing tools

**Observing**: `get_interface` returns the delivered accessibility tree;
`get_screen` returns visual context plus fresh visible geometry. These are direct
client commands, not DSL. Pass `subtree` an `AccessibilityTarget`, using the
same element checks, container predicate, ordinal, or descendant scope used by
actions and predicates. Container identifiers match any delivered parser
container type that carries the identifier, not only semantic groups.
`containerName` remains a capture-local diagnostic name, not a semantic target.
Reach for `get_screen` when layout, pixels, or current viewport geometry matters.

**Acting**: `perform(step:)` runs one durable ButtonHeist DSL instruction. Use it when one line is enough: one action, or one `WaitFor(...)` statement.

Allowed `perform(step:)` statements are one action or one `WaitFor(...)` statement:

```swift
Activate(.label("Pay")).expect(.screenChanged)
TypeText("milk", into: .label("Search"))
    .expect(.exists(.element(.label("Search"), .value("milk"))))
Increment(.label("Quantity"))
    .until(.element(label: "Quantity", value: "10"), timeout: 5)
Decrement(.label("Quantity"))
CustomAction("Archive", on: .label("Message"))
Rotor("Headings", on: .label("Article"))
SetPasteboard("hello")
Edit(.paste)
dismissKeyboard()

oneFingerTap(.label("Map"))
longPress(.label("Message"))
swipe(.label("Carousel"), .left)
drag(.label("Slider"), to: ScreenPoint(x: 200, y: 40))

WaitFor(.exists(.label("Checkout")), timeout: 5)
```

`perform(step:)` accepts one durable DSL step only. It rejects program-shaped
source: multiple statements, `HeistPlan`, `HeistDef`, `RunHeist`, `If`,
`WaitFor(...).else { ... }`, `ForEach`, `RepeatUntil`, `Warn`, and `Fail`. It
also rejects raw wire IR and direct viewport/debug/session command text. Use
`run_heist(plan:)` for durable plans.

**Targets**: actions, predicates, and `get_interface.subtree` share one
`AccessibilityTarget` grammar:

```swift
.label("Pay")
.identifier("pay_button")
.value("Milk")
.element(.label("Pay"), .traits([.button]))
.element(.label(.prefix("foo")), .label(.contains("bar")), .label(.suffix("baz")))
.target(.element(.label("Delete"), .traits([.button])), ordinal: 1)
.container(.identifier("Checkout"))
.within(container: .identifier("Checkout"), .label("Pay"))
```

Ordinal belongs inside the target:

```swift
Activate(.target(.label("Pay"), ordinal: 0))
```

Machine clients should prefer the optional `target` returned with an eligible
`get_interface` element. Keep that target unchanged and send it back to The
Button Heist. It was selected against the complete captured interface, including
matching elements hidden by response limits. Build a target from semantic fields
only when the response does not provide one.

Do not write action-level ordinals:

```swift
Activate(.label("Pay"), ordinal: 0)
```

**Waiting**: use `perform(step:)` with `WaitFor(...)` when the UI is updating asynchronously — network requests, timers, animations completing. The predicate should name the specific outcome:

```swift
WaitFor(.screenChanged, timeout: 10)
WaitFor(.exists(.container(.label("Checkout"))), timeout: 5)
WaitFor(.exists(.label("Receipt")), timeout: 5)
WaitFor(.missing(.label("Loading")), timeout: 10)
WaitFor(.notification(text: .contains("saved"), element: .label("Receipt")))
```

For `.missing(...)`, the predicate means the element is absent from the current settled hierarchy. It does not require The Button Heist to prove the element existed and then vanished.

Use `.exists(.container(...))` when you need to assert that the current settled
hierarchy contains a matching container without proving that navigation just
happened. Container predicates can match `.label(...)`, `.value(...)`,
`.identifier(...)`, `.scrollable(true)`,
`.dataTable(rowCount: .init(...), columnCount: .init(...))`, or
`.matching(...)` combinations. Use `.within(container: .label("Checkout"), ...)`
when an element target must resolve inside that container. Use
`.screenChanged` or `.screenChanged("Checkout")` when the preceding action
itself must prove a screen transition. Use `.exists(...)` or `.missing(...)`
for current-tree state. Use
`.elementsChanged([.appeared(...), .disappeared(...), .updated(...)])` only
when the observed transition itself is required; final state alone never
satisfies those lifecycle assertions.

For text entry that may reflow the interface, assert the settled field state:

```swift
TypeText("Bruschetta", into: .label("Search Items"))
    .expect(.exists(.element(.label("Search Items"), .value("Bruschetta"))))
```

Use explicit property-delta expectations when the action should update a known
element in place:

```swift
Increment(.label("Quantity"))
    .expect(.elementsChanged([.updated(
        .label("Quantity"),
        .value(before: "2", after: "3")
    )]))
```

`before` and `after` use the same matcher grammar as targets and state assertions.
Omit `before:` for destination-only updates such as `.value("3")`; include an
element matcher when the update must be tied to a durable element predicate.
The update declaration does not infer the action target; name the element in
the `.updated(target, change)` assertion.

**Composing**: `run_heist` executes a durable `HeistPlan` in a single call.
Prefer the `plan` field with canonical ButtonHeist source when authoring compact
heists as an agent, or pass a generated `.heist` artifact path when reusing a
stored artifact:

Before attempting a newly authored plan, call `validate_heist` with the same
`plan` or `.heist` `path`, root `argument`, and desired lint mode. This tool is
entirely local: it does not discover an app, connect to a device, or acquire a
session. Its result distinguishes:

- `plan`: source/package admission
- `invocation`: root argument arity and type
- `lint`: `none`, `composition_quality`, or `strict_test` authoring findings

`admissible` means the plan and invocation may be submitted to `run_heist`.
It does not mean live targets exist or runtime expectations will pass. MCP
returns invalid plans as ordinary structured validation content, so inspect
`admissible` rather than treating `isError` as the validation result.

```swift
HeistPlan {
    Activate(.label("Pay"))
        .expect(.screenChanged)

    TypeText("milk", into: .label("Search"))
        .expect(.exists(.element(.label("Search"), .value("milk"))))
}
```

Use `run_heist(plan:)` for definitions, composition, branching, waits with bodies, loops, warnings, failures, or multiple steps:

```swift
HeistPlan("shop") {
    HeistDef<String>("Cart.addItem", parameter: "item") { item in
        TypeText(item, into: .label("Search Items"))
            .expect(.exists(.element(.label("Search Items"), .value(item))))
        Activate(.label(item))
            .expect(.elementsChanged([.appeared(.element(
                .label(.prefix(item)),
                .identifier(.contains("cart"))
            ))]))
    }

    RunHeist("Cart.addItem", "Milk")
        .expect(.elementsChanged([.appeared(.element(
            .label("subtotal"),
            .value(.contains("1 item"))
        ))]))

    If(.exists(.label("Pay"))) {
        Activate(.label("Pay"))
            .expect(.screenChanged)
    }.else {
        Warn("Pay button unavailable")
    }
}
```

The `plan` string is ButtonHeist source, not arbitrary Swift. Its top level MUST
be a durable `HeistPlan`. It accepts the canonical DSL constructs rendered by
The Button Heist and rejects imports, variables, functions, native Swift control
flow, interpolation, custom calls, body-local `try`, `await`, and unbounded
loops. JSON plan IR is internal/generated; use source for compact authoring
unless you are passing a generated `.heist` artifact path.

Use the same source string for discovery before execution. `list_heists(plan:)` shows the root entry and reusable `HeistDef` capabilities; `describe_heist(plan:)` describes one of those entries. These examples are copyable into `run_heist(plan:)` by removing the discovery-specific fields:

```text
list_heists detail="detailed" plan: """
HeistPlan("shop") {
    HeistDef<String>("Cart.addItem", parameter: "item") { item in
        Activate(.label(item))
    }

    RunHeist("Cart.addItem", "Milk")
}
"""
```

```text
describe_heist heist="Cart.addItem" plan: """
HeistPlan("shop") {
    HeistDef<String>("Cart.addItem", parameter: "item") { item in
        Activate(.label(item))
    }

    RunHeist("Cart.addItem", "Milk")
}
"""
```

Do not author heists as raw `version`/`name`/`parameter`/`definitions`/`body`
JSON. That shape is internal/generated IR for artifacts, storage, wire
transport, and debugging.

MCP tool arguments are preflighted before The Button Heist converts them into command values. Public machine input is bounded by `PublicJSONInputLimits.maxRequestBytes`, `PublicJSONInputLimits.maxNestingDepth`, and `PublicJSONInputLimits.maxTotalObjectKeys`; the same limits apply to JSON-lines input.

## Observation semantics

The Vault owns one ordered `Observation.History`. It deterministically reduces
admitted snapshots and normalized notification payloads into
`Observation.Event` values. Same-screen changes emit `elementsChanged`; a screen
replacement emits departure `elementsChanged`, `screenChanged`, then arrival
`elementsChanged`. `noChange` has no payload and means the admitted snapshot has
no semantic or geometry change within the comparison tolerance.

`WaitFor`, `.expect(...)`, and `.until(...)` consume those events in order
through the same heist reducer. The reducer gives each active leaf one absolute
deadline covering baseline acquisition, reveal or dispatch, predicate
evaluation, and trailing `noChange`. It projects the earlier leaf or whole-heist
target to the host; there is no separate readiness allowance.
See [Execution and Predicate Pipeline](ARCHITECTURE.md#execution-and-predicate-pipeline).

Actions can refresh off-screen state by exploring scroll views before or after
the interaction, but exploration is not a screen boundary by itself. It broadens
current-screen knowledge. A real screen boundary is still visible to element
predicates because every old node disappears and every new node appears;
cross-generation nodes are never reported as updates.

`get_interface` returns app state. A default call may refresh discoverable off-screen content so the returned hierarchy is current. Passing `subtree` scopes that projection to the part of the hierarchy you asked for. `get_screen` is diagnostic: it returns pixels plus fresh visible geometry for the current viewport, not a replacement for the app-state hierarchy.

## Async changes

For operations that take time, keep using the DSL:

```swift
Activate(.label("Pay"))
    .expect(.screenChanged("Receipt"))

WaitFor(.exists(.label("Receipt")), timeout: 10)
```

If the action result shows a spinner or loading overlay instead of the final state,
run `WaitFor(...)` through `perform(step:)`. The Button Heist checks the
current settled hierarchy first, then watches settled accessibility state until
the final state is true or the timeout expires.

## Expectations

Every action is an opportunity to validate. Attach `.expect(...)` whenever you
know what should change:

```swift
Activate(.label("Continue"))
    .expect(.screenChanged)

TypeText("milk", into: .label("Search"))
    .expect(.exists(.element(.label("Search"), .value("milk"))))

Activate(.label("Delete"))
    .expect(.missing(.label("Delete")))
```

Before you act, ask what should be true afterward. A nav button changes the
screen. A delete removes an element. Text entry updates a value. Encode that fact
as the expectation and let the result confirm or correct you.

## Authoring heists

Heists are authored reusable instructions, not logs inferred from live clicking. Use `run_heist(plan:)` for multi-step flows and keep expectations in the source whenever the app should prove a state change.

**Attach expectations to every meaningful action.** A heist without expectations is only a sequence of commands; a heist with expectations is a self-verifying test suite that validates on every replay.

**One action, one purpose.** Each step should do exactly one thing and verify it. Do not chain five interactions and check at the end — check after each one. This makes replay failures precise: step 7 failed means the 7th interaction broke.

**Read the delta before moving on.** It is a compact, one-way fold of ordered
events: events are stacked in time, squashed into endpoint-friendly edits, and a
screen marker dominates the final kind. It is useful response evidence, but it
is not the history used by the evaluator. Use
`structuredContent.report.nodes[].evidence.action.result.delta` for the folded
added, removed, updated, or destination-interface evidence.

## Efficiency

Read the delta first — skip `get_interface` when the delta already told you what changed. Reuse a returned canonical target while the captured app state is still current. After navigation, use a target from the new delta or interface evidence. Pass `subtree` when you only need one subtree or one leaf from the current hierarchy.

## Local MCP development

Use this workflow when testing a worktree-local `ButtonHeistMCP` change through an MCP host.

**Build the worktree binary:**

```bash
cd ButtonHeistMCP
swift build -c release
```

The release binary is written to `ButtonHeistMCP/.build/release/buttonheist-mcp` in the current worktree.

**Know what `.mcp.json` loads.** The repo config starts `buttonheist` with `./scripts/buttonheist-mcp.sh`. That wrapper resolves its own directory, treats the parent as the repo root, and `exec`s that worktree's release binary. It does not build the server, choose a device, or rewrite environment variables; the MCP host's environment is inherited by the server process.

Start the MCP host or agent from the worktree you are testing. If a host loaded `.mcp.json` from another checkout, its relative `./scripts/buttonheist-mcp.sh` may still point at that checkout until the MCP session is restarted.

**Set target environment before starting the MCP host:**

- `BUTTONHEIST_DEVICE`: discovered device name, named target, or direct `host:port`. Use `127.0.0.1:<port>` for simulator direct-connect sessions that bypass Bonjour.
- `BUTTONHEIST_TOKEN`: auth token from `TheInsideJob`.
- `BUTTONHEIST_DRIVER_ID`: stable driver identity for session locking. Use a unique value per agent/session when multiple clients share a token.

Exporting these variables after the host has already launched does not update an already-running MCP server process. Start a fresh MCP session or agent after changing the target environment.

**Reload after rebuilds.** MCP hosts usually keep the server process alive for the lifetime of the loaded MCP session. Rebuilding `ButtonHeistMCP` updates the binary on disk, but an already-loaded server keeps running the old code. End the MCP session or start a fresh agent/host from this worktree after each rebuild. If tool behavior still matches the previous build after restarting, verify the host resolved `.mcp.json` from the correct worktree.

**Run against a simulator endpoint:**

```bash
TASK_SLUG="mcp-reload-debug"
SIM_UDID=$(xcrun simctl create "$TASK_SLUG" "iPhone 16 Pro")
xcrun simctl boot "$SIM_UDID"
xcrun simctl bootstatus "$SIM_UDID" -b

xcodebuild -workspace ButtonHeist.xcworkspace -scheme "BH Demo" \
  -destination "platform=iOS Simulator,id=$SIM_UDID" build
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/ButtonHeist*/Build/Products/Debug-iphonesimulator/BHDemo.app | head -1)
xcrun simctl install "$SIM_UDID" "$APP"

INSIDEJOB_PORT=$((RANDOM % 10000 + 20000))

SIMCTL_CHILD_INSIDEJOB_PORT="$INSIDEJOB_PORT" \
SIMCTL_CHILD_INSIDEJOB_TOKEN="$TASK_SLUG" \
SIMCTL_CHILD_INSIDEJOB_ID="$TASK_SLUG" \
xcrun simctl launch "$SIM_UDID" com.buttonheist.testapp

export BUTTONHEIST_DEVICE="127.0.0.1:$INSIDEJOB_PORT"
export BUTTONHEIST_TOKEN="$TASK_SLUG"
export BUTTONHEIST_DRIVER_ID="$TASK_SLUG"
```

Then start the MCP host or agent from this worktree so `.mcp.json` resolves to the same build. For a one-off stdio smoke check outside a host:

```bash
BUTTONHEIST_DEVICE="127.0.0.1:$INSIDEJOB_PORT" \
BUTTONHEIST_TOKEN="$TASK_SLUG" \
BUTTONHEIST_DRIVER_ID="$TASK_SLUG" \
./scripts/buttonheist-mcp.sh
```

When the session is done, shut down and delete the dedicated simulator:

```bash
xcrun simctl shutdown "$SIM_UDID"
xcrun simctl delete "$SIM_UDID"
```
