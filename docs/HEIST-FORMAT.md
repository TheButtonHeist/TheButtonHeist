# Heist format

The Button Heist has one durable DSL boundary and one generated artifact
format.

`HeistPlan` is the durable DSL artifact boundary. Anything that must survive
storage, catalog discovery, MCP composition, replay, or canonical rendering MUST
lower to a validated `HeistPlan`. Humans and agents SHOULD author canonical
ButtonHeist DSL source. Swift authoring frontends MAY generate `HeistPlan`
values locally, but arbitrary Swift structure is not durable language. A
`.heist` path is a durable generated package directory that carries that plan;
it is not a hand-authored JSON file.

Direct viewport, debug, and session commands are transient client commands. They
MAY inspect or control the current live session, but they MUST NOT be stored in a
`.heist` artifact or represented as durable `HeistPlan` steps.

For the authoring boundary, see [Heist language spec](HEIST-LANGUAGE-SPEC.md).
The author-to-replay pipeline is drawn in the
[heist lifecycle diagram](diagrams/heist-lifecycle.md); the step types and
predicate forms are drawn in the [DSL grammar diagram](diagrams/dsl-grammar.md);
the test-process entry points that replay plans are drawn in the
[test entry points diagram](diagrams/test-entry-points.md).

## File Roles

| Role | Meaning |
|------|---------|
| `.swift` | Full Swift source for reusable authored heists, tests, helpers, and local constants. |
| `plan` source string | ButtonHeist DSL source for MCP/CLI inline authoring. It is Swift-like, but accepts only the DSL constructs The Button Heist can parse and render canonically. |
| `.heist` | Durable generated package artifact containing `manifest.json` and `plan.json`. Do not hand-author it. |
| `.json` | Runtime `HeistPlan` wire IR for internal diagnostics and generated tooling only. It is not public heist authoring input or a public artifact API. |

`run_heist` accepts durable plans only: canonical ButtonHeist source that parses
to a `HeistPlan`, or a generated `.heist` package through `path`. CLI authoring
helpers MAY accept trusted local Swift input only by compiling it to a validated
`HeistPlan` before dispatch. The closed command descriptor rejects generated
wire payload keys and all other unknown top-level fields. Public run input MUST
NOT accept direct viewport/debug/session commands.

## Package Shape

A `.heist` path is a package directory:

```text
SearchFlow.heist/
  manifest.json
  plan.json
```

Plain JSON with a `.heist` extension is invalid. Generate a fresh `.heist`
package from Swift/DSL source when crossing public artifact boundaries.

## Manifest

`manifest.json` is the artifact envelope:

```json
{
  "createdAt": "2026-06-05T00:00:00Z",
  "format": "com.royalpineapple.buttonheist.heist",
  "formatVersion": 2,
  "producer": {
    "name": "buttonheist"
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `format` | `HeistArtifactFormat` as one JSON string | Closed vocabulary with the sole canonical value `com.royalpineapple.buttonheist.heist`. |
| `formatVersion` | `Int` | Package/container schema version. Current value is `2`. |
| `producer` | `HeistArtifactProducer` | Tool that generated the artifact. |
| `createdAt` | `Date` | Artifact creation timestamp. |

`producer.name` is an open-vocabulary `HeistArtifactProducerName`, encoded as
one nonblank JSON string. `producer.version` is an optional open-vocabulary
`HeistArtifactProducerVersion`, also encoded as one nonblank JSON string.
Neither wrapper trims or normalizes an admitted producer spelling. The closed
`format` vocabulary is represented by `HeistArtifactFormat`, not a producer-name
string.

The required root `HeistPlan.name` and supported plan version live only in
`plan.json`. The manifest does not duplicate either value. Parameterized
definitions are reusable capabilities, not artifact entries; run them from a
root plan with `RunHeist("Name", argument)`.

The manifest does not contain app bundle IDs, step counts, screenshots,
accessibility evidence, repair provenance, trace IDs, target labels, command
lists, or source metadata. Those belong in `plan.json`, external evidence, or
future sidecars.

Excluding app identity is a deliberate tradeoff. An artifact describes an
accessibility dialogue, not an app binary, so the same `.heist` can replay
against any app that fulfills the contract — including the same product
rebuilt on a different UI framework. The cost: replaying against the wrong app
fails as ordinary `elementNotFound` misses, indistinguishable from a broken
contract in the right app. Callers own pointing an artifact at the app it was
recorded for; name artifacts and organize directories so that stays obvious.

## Plan JSON

`plan.json` is the canonical generated `HeistPlan` value. It is storage, wire,
and internal IR. It is not the surface humans or agents should write by hand,
and it MUST NOT be treated as the authoring language.

The wire contract is executable, not prose-only. Keep this document aligned
with:

- `ButtonHeist/Tests/ThePlansTests/HeistPlanWireContractTests.swift`
- `ButtonHeist/Tests/ThePlansTests/ThePlansBoundaryTests.swift`
- `ButtonHeist/Tests/TheScoreTests/HeistPlaybackTests.swift`

The root shape is:

```json
{
  "version": 3,
  "name": "purchaseFlow",
  "parameter": { "type": "none" },
  "definitions": [],
  "body": [
    {
      "type": "warn",
      "warn": { "message": "checkpoint" }
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `version` | `Int` | Must match the supported `HeistPlan` version. |
| `name` | `HeistPlanName?` as one JSON string | One identifier naming the root or local definition. Required for `.heist` root entries and stored definitions; optional for inline one-step plans. |
| `parameter` | `HeistParameter` | Optional reusable-heist parameter declaration. Omitted means no parameter. |
| `definitions` | `[HeistPlan]` | Local named reusable heist definitions. |
| `body` | `[HeistStep]` | Ordered list of typed heist steps. The body must be non-empty unless the plan only provides definitions. |

Unknown keys are rejected. There is no app identifier, source metadata, runtime
ID, capture-local element ID, geometry, or implicit viewport state in the root
plan contract.

## Compatibility

Three version values exist, and they answer different questions:

- **`manifest.json.formatVersion`** (currently `2`) governs the package shape.
- **`plan.json.version`** (currently `3`) governs the plan IR. The runtime
  accepts only the version it supports and rejects others at load with a
  diagnostic; it never guesses at an unsupported shape.
- **`buttonHeistVersion`** encodes the typed `ButtonHeistVersion` used by the
  live client–server wire. The handshake requires exact equality between CLI/MCP
  and the embedded app build. It does not participate in artifact validity: a
  stored `.heist` is not invalidated by releases that keep `plan.json.version`
  stable.

The durable investment is the DSL source. `.heist` packages are generated
artifacts: when `plan.json.version` bumps, regenerate them from source rather
than migrating JSON by hand. Within a plan version, grammar additions add new
step or predicate shapes without invalidating existing artifacts; the strict
unknown-key rule constrains what a reader accepts, not what an older artifact
may contain.

Invocation steps encode `HeistInvocationPath` as one dotted string:

```json
{ "type": "invoke", "invoke": { "path": "Cart.addItem" } }
```

Definition paths are authoring structure and lower into nested named
`HeistPlan` definitions; invocation paths remain a distinct type in memory.

## Authored shape

Use canonical ButtonHeist source when explaining or authoring portable heists.
It is Swift-shaped, but it is the source language accepted by MCP and
`run_heist(plan:)`; checked-in Swift files are covered in
[Swift heist authoring](SWIFT-HEIST-AUTHORING.md).

The generated plan uses one `AccessibilityTarget` shape for action targets and
predicate targets. Expectations use one context-typed predicate tree:
`exists`, `missing`, `changed`, and `announcement` at the root;
`changed.screen` accepts current-tree `exists`/`missing`; `changed.elements`
also accepts `appeared`, `disappeared`, and `updated`. The generated wire form
is strict: `{"type":"changed","scope":"screen|elements","assertions":[]}`.
Artifacts do not carry aliases or compatibility spellings.

```swift
HeistPlan("purchaseFlow") {
    TypeText("milk", into: .label("Search Items"))
        .expect(.exists(.element(.label("Search Items"), .value("milk"))))

    Activate(.label("Milk"))
        .expect(.elementsChanged([.appeared(.element(
            .label(.prefix("Milk")),
            .identifier(.contains("cart"))
        ))]))

    WaitFor(.missing(.label("Loading")), timeout: 5)
        .else {
            Fail("Loading did not finish")
        }
}
```

The same primitives scale up without creating a second runtime:

```swift
HeistDef<String>("addToCart", parameter: "item") { item in
    TypeText(item, into: .label("Search Items"))
        .expect(.exists(.element(.label("Search Items"), .value(item))))

    Activate(.label(item))
        .expect(.elementsChanged([.appeared(.element(
            .label(.prefix(item)),
            .identifier(.contains("cart"))
        ))]))
}

HeistPlan("cartFlow") {
    ForEach("Milk", "Eggs") { item in
        RunHeist("addToCart", item)
    }

    If {
            Case(.label("Checkout")) {
                Activate(.label("Checkout"))
                    .expect(.screenChanged([.exists(.label("Receipt"))]))
            }

        Else {
            Fail("Checkout unavailable")
        }
    }
}
```

`RepeatUntil` is the bounded repetition form, serialized as a `repeat_until`
step. The body always executes once before the predicate is evaluated; only an
unmet post-body predicate turns that action into another iteration. The timeout
is mandatory and is the step's totality bound:

```swift
RepeatUntil(.exists(.label("Inbox empty")), timeout: 10) {
    Activate(.label("Delete"))
}
```

Semantic ForEach binds a target expression, not a cached element handle:

```swift
ForEach(.label("Delete"), limit: 20) { target in
    Activate(target)
        .expect(.missing(target), timeout: 2)
}
```

At runtime each iteration re-resolves the target through the normal semantic
pipeline. The body receives no UIKit object, live geometry, runtime ID, capture
ID, or viewport handle.

## Rejected historical forms

These forms existed during the prototype phase and should not appear in public
docs, demos, or new fixtures:

- a tracked `.heist` file containing raw JSON instead of a package directory
- `target.matcher` or `matcher` target wrappers
- raw authored JSON examples that teach generated step names instead of DSL
- public source spellings that use internal payload keys instead of DSL targets
- viewport setup before semantic action as a durable heist step
- geometry, runtime IDs, capture-local IDs, or container names as semantic identity

The generated `plan.json` may contain internal wire names. Do not copy those
names into agent-facing examples. If a heist is meant for humans or agents to
edit, render it as canonical DSL.

## Runtime contract

Normal heists express semantic intent and semantic outcomes. The Button Heist owns
viewport reveal, element inflation, observation, live geometry, deadline
enforcement, and diagnostics while the plan runs.

Runtime validation rejects non-executable plans before dispatch: unresolved
refs, invalid payloads, oversized loops, excessive depth, noncanonical
commands, nested collection loops, and unknown fields.

Lint is separate quality guidance for authored or composed plans:

| Mode | Purpose |
|------|---------|
| `compositionQuality` | Warns when composed plans look like fragile transcripts. |
| `strictTest` | Fails missing expectations, spatial gesture actions, viewport/debug/session action steps, and empty branches. |

Lint returns structured findings with severity, step path, message, and a fix
suggestion. It does not replace runtime validation.

## Non-goals

The durable heist AST is small on purpose. It does not support:

- arbitrary dynamic code execution over the wire
- unbounded loops, sleeps, retries, catch/recover, or arbitrary polling loops
- native Swift control flow as runtime control flow
- hidden pre-action viewport movement for semantic actions
- viewport/debug/session commands as durable semantic action steps
- generic variables or expression evaluation beyond typed string and target refs
- geometry, runtime IDs, capture-local IDs, or container names as durable selectors
- unknown JSON keys
- spatial gesture actions in strict semantic tests unless explicitly waived

## Live composition

Live composition turns completed interactions and settled semantic evidence into
semantic action intent plus validated semantic expectation.

Rules:

- observation commands are scratchpad and add no steps
- wait is an assertion primitive and becomes a wait step
- failed actions add no steps
- unmet expectations add no steps
- direct viewport/debug/session commands add no steps
- scroll setup before semantic action adds no setup step
- coordinate gestures survive only when no semantic element intent exists
- composed heists should pass composition-quality lint

Composed and authored heists must not depend on scroll position, geometry,
runtime IDs, capture-local IDs, or container names as semantic identity. Direct
viewport/debug/session commands may use a current `containerName` while
inspecting the live interface, but those commands are not durable heist
primitives.
