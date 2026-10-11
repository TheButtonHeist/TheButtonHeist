# Offline heist validation

Status: Implemented

## Summary

Add a `validate_heist` command to MCP, the top-level CLI, and JSON-lines. It
validates a durable Button Heist plan without discovering, connecting to, or
communicating with an app. Every surface uses the same source loading, root
`HeistPlan` admission, runtime-safety, root-argument, linting, and response
pipeline. The command returns deterministic diagnostics and canonical Button
Heist source that a human, agent, or CI job can repair before calling
`run_heist`.

The intended agent loop is:

```text
author source
→ validate_heist
→ repair diagnostics
→ validate_heist
→ run_heist
→ inspect result
```

`validate_heist` proves that a plan and its optional root invocation can enter
the runtime. It does not predict whether the app contains a target or whether
an expectation will pass.

## Goals

- Give agents and CLI users a deterministic validation step before UI
  mutation.
- Require no active or configured Button Heist session.
- Return domain diagnostics as structured data suitable for an automated
  generate-and-repair loop.
- Return canonical source for every admitted plan.
- Validate the root argument with the same rules as `run_heist`.
- Keep authoring-quality lint separate from executable-plan admission.
- Make the operation read-only and idempotent.
- Give one-shot CLI callers useful process exit status for CI and scripts.
- Keep `run_heist` admission mandatory. Prior validation is never an execution
  capability or a bypass token.

## Non-goals

`validate_heist` does not:

- discover devices;
- read or change session state;
- connect to an app;
- read the accessibility hierarchy;
- resolve targets against a live interface;
- prove that a target exists or is unique;
- dispatch actions, waits, or heists;
- settle the interface;
- predict action support or expectation outcomes;
- create a result;
- compile trusted local Swift source;
- accept raw `HeistPlan` JSON intermediate representation;
- write or update `.heist` artifacts;
- cache a validation result for later execution;
- weaken or skip validation in `run_heist`.

## Meaning of offline

For this feature, offline means that the result depends only on:

- the CLI, MCP, or JSON-lines argument envelope;
- inline canonical Button Heist source, or a local `.heist` artifact;
- local plan loading, linting, and canonical rendering.

The command MUST NOT call `TheFence.start()`, `DeviceDiscovery`,
`DeviceConnection`, `TheHandoff`, Bonjour, `NWConnection`, simulator tools, or
server wire APIs. It MUST work when no app is running and no target is present
in `.buttonheist.json`.

Reading a caller-supplied local `.heist` path is allowed. The command performs
no network I/O and no filesystem writes.

## Public command contract

### Tool name

```text
validate_heist
```

The same typed `TheFence.Command.validateHeist` command is exposed through:

- the MCP `validate_heist` tool;
- `buttonheist validate_heist`;
- `buttonheist json_lines` with `{"command":"validate_heist","plan":"..."}`.

The `buttonheist plan` commands are the lower-level local compiler and artifact
tools.

### Tool description

Use this description in the command catalog:

> Validate a durable Button Heist plan without connecting to an app. Returns
> runtime-admission diagnostics, optional authoring lint, and canonical source.
> Provide exactly one of `plan` or `path`. This cannot verify live targets or
> UI outcomes. Call `run_heist` only after `admissible` is true.

### MCP annotations

```swift
MCPToolAnnotationSpec(
    readOnlyHint: true,
    idempotentHint: true
)
```

### Connection policy

```swift
requiresConnectionBeforeDispatch: false
```

This descriptor value is a correctness requirement, not an optimization.

### CLI command

The top-level CLI command accepts:

```text
buttonheist validate_heist \
  (--plan SOURCE | --path FILE) \
  [--argument JSON] \
  [--lint none|composition_quality|strict_test] \
  [--format human|compact|json]
```

Examples:

```bash
buttonheist validate_heist \
  --plan 'HeistPlan { Activate(.label("Pay")).expect(.screenChanged()) }'

buttonheist validate_heist \
  --path Checkout.heist \
  --lint strict_test \
  --format json
```

The command MUST NOT expose connection, device, token, reconnect, or session
options. It MUST use the local TheFence path used by `list_heists` and
`describe_heist`, not `CLIRunner.run`'s connection workflow.

The CLI forwards inline source and `.heist` paths to TheFence without parsing
the plan itself. It MUST reject `.swift`, `.json`, and every other path type.
Trusted Swift source already has one offline validation pipeline:
`buttonheist plan compile`. Keeping Swift out of `validate_heist` makes the CLI, MCP,
and JSON-lines source contracts identical.

### CLI exit status

The one-shot CLI uses validation semantics suitable for CI:

| Outcome | Exit status |
|---|---:|
| Plan and invocation are admissible, with no lint errors | `0` |
| Plan or invocation is not admissible | `1` |
| Selected lint mode returns one or more error findings | `1` |
| Warnings only | `0` |
| Malformed request or internal tool failure | `1` |

This policy is CLI-specific. `FenceResponse.isFailure` remains false for an
ordinary validation report so MCP can consume and repair diagnostics. The CLI
adapter inspects `HeistValidation.Report` after rendering output and returns
`ExitCode.failure` when `report.commandPassed` is false, where:

```text
commandPassed = admissible && no lint finding has severity "error"
```

JSON-lines does not assign a per-request process exit status. It returns the
same structured report and continues reading requests.

### Input schema

The shared command accepts these top-level fields:

| Field | Type | Required | Default | Meaning |
|---|---|---:|---|---|
| `plan` | string | Conditional | — | Inline canonical Button Heist source whose root is `HeistPlan` |
| `path` | string | Conditional | — | Path to a generated `.heist` package |
| `argument` | object | No | `{"type":"none"}` | Root invocation argument, using the `run_heist` argument schema |
| `lint` | string enum | No | `composition_quality` | Authoring lint mode: `none`, `composition_quality`, or `strict_test` |

Exactly one of `plan` or `path` MUST be present. The generated JSON Schema MUST
continue the repository convention of ordinary properties with
`additionalProperties: false`; it MUST NOT introduce top-level `oneOf`,
`anyOf`, or `allOf`. TheFence enforces mutual exclusion during admission.

The tool MUST reuse the `run_heist` root `argument` schema and decoding path.
The CLI and JSON-lines surfaces MUST use that representation too. No surface
defines a parallel root-argument shape.

The lint field maps as follows:

| Public value | Internal behavior |
|---|---|
| `none` | Do not run authoring lint |
| `composition_quality` | Run `plan.lint(.compositionQuality)` |
| `strict_test` | Run `plan.lint(.strictTest)` |

`composition_quality` is the default because a heist may be an operational
workflow rather than a strict semantic test. Callers that intend to preserve a
heist as a test SHOULD request `strict_test`.

### Accepted source forms

Inline source:

```json
{
  "plan": "HeistPlan { Activate(.label(\"Pay\")).expect(.screenChanged()) }",
  "lint": "strict_test"
}
```

Generated artifact:

```json
{
  "path": "Checkout.heist",
  "argument": {
    "type": "string",
    "value": "Milk"
  }
}
```

The tool MUST reject:

- calls containing neither `plan` nor `path`;
- calls containing both `plan` and `path`;
- `.swift`, `.json`, or other non-`.heist` paths;
- empty inline source;
- unknown top-level fields;
- an argument that does not match the shared root-argument schema;
- unknown lint values.

Rejection has two public forms:

| Condition | MCP `isError` | Result |
|---|---:|---|
| Missing or conflicting source selection | `true` | Ordinary request error |
| Unknown field, wrong JSON type, or unknown lint value | `true` | Ordinary request error |
| Argument object cannot decode as any `HeistArgument` | `true` | Ordinary request error |
| Empty inline source or unsupported path extension | `false` | Validation report with `plan.valid: false` |
| Inline syntax, root structural admission, or runtime-safety rejection | `false` | Validation report with build diagnostics |
| Artifact read, format, or version rejection | `false` | Validation report with build diagnostics |
| Decoded argument kind does not bind to the admitted root parameter | `false` | Validation report with `invocation.status: invalid` |

`argumentProvided` is true whenever the caller includes the `argument` field,
including an explicit `{"type":"none"}` argument. It is false only when the
field is absent and TheFence supplies the normal `.none` default.

Canonical Button Heist source is untrusted declarative input. The MCP server
MUST parse it with the restricted source compiler. It MUST NOT invoke `swiftc`,
load a dynamic library, or evaluate arbitrary Swift.

## Validation model

Validation has three independent outcomes:

1. **Plan validity**: source parsed or artifact JSON decoded and produced one
   root-admitted, runtime-safe `HeistPlan`.
2. **Invocation validity**: the supplied argument, or the default `.none`
   argument, binds to the root plan parameter.
3. **Lint result**: the admitted plan satisfies the requested authoring mode.

The response derives these booleans:

```text
admissible = plan.valid && invocation.valid
lint.passed = no lint finding has severity "error"
```

Lint MUST NOT change `plan.valid`, `invocation.valid`, or `admissible`. Existing
architecture defines lint as authoring guidance, not runtime admission. A plan
may therefore be admissible while `lint.passed` is false.

If a root parameter is required and `argument` is omitted, validation applies
the same default `.none` argument as `run_heist`. The plan remains valid, but
the invocation is not valid and `admissible` is false. This makes a successful
validation call a faithful preview of the corresponding `run_heist` request.

## Validation pipeline

The implementation MUST run these phases in order.

### 1. MCP input preflight

Apply the existing public MCP limits before converting arguments into
`HeistValue`:

- maximum request bytes: `PublicJSONInputLimits.maxRequestBytes`;
- maximum nesting depth: `PublicJSONInputLimits.maxNestingDepth`;
- maximum object keys: `PublicJSONInputLimits.maxTotalObjectKeys`;
- finite JSON numbers only.

Then validate the closed command schema. Unknown fields and wrong JSON types
are request errors.

### 2. Source admission

Use the existing plan-source parameter types and enforce exactly one source.
The descriptor-driven command schema is the sole owner of unknown top-level
field rejection, including raw wire-IR keys.

Failures that mean the caller did not identify one plan source are request
errors:

- missing both source fields;
- supplying both source fields;
- unknown fields;
- schema-invalid values.

### 3. Plan loading and root admission

Load the selected source through the same `HeistPlanSourceAdmission` and
`HeistPlanLoading` path used by
`run_heist`, `list_heists`, and `describe_heist`:

```text
inline plan
→ restricted Button Heist source parser
→ direct root HeistPlan structural admission
→ one HeistPlanRuntimeSafetyValidator pass
→ admitted HeistPlan

.heist path
→ HeistArtifactCodec
→ strict JSON decoding and version checks
→ direct root HeistPlan structural admission
→ one HeistPlanRuntimeSafetyValidator pass
→ admitted HeistPlan
```

The source parser and JSON decoder may store and return recursive intermediate
values among private helpers inside their owning boundary. Those values never
escape that boundary or become a separate package or public currency. Swift
DSL construction enters the same throwing root `HeistPlan` initializer.
Source, generated artifact JSON, and Swift DSL construction therefore expose
exactly one admitted value: `HeistPlan`.

Root structural admission runs once, followed by the single
`HeistPlanRuntimeSafetyValidator`. There is no validation alias, adapter,
parallel result, alternate admitted representation, or second runtime-safety
route.

This phase includes all existing plan contracts, including:

- strict unknown-key decoding;
- canonical action and predicate payloads;
- definition and invocation path validation;
- duplicate definition checks;
- unresolved invocation checks;
- argument kind checks between definitions and invocations;
- recursion and call-cycle rejection;
- non-durable action rejection;
- bounded plan size, nesting, loops, and timeouts;
- reference scope and binding validation;
- target and predicate grammar validation.

Do not reproduce these checks in `TheFence` or the MCP package.

Admission failures throw `HeistPlanBuildError`. Its diagnostics retain the
canonical order in which the parser, decoder, or runtime-safety traversal
produced them. Source syntax failures preserve their exact code, message,
source name, offset, line, column, and length. Structural and runtime-safety
failures preserve their exact canonical plan path. Equivalent nested source
and artifact JSON must report the same code, message, and full path; for
example:

```text
$.body[0].conditional.cases[0].body[0].heist.body[0].invoke.path
```

The validation command catches `HeistPlanBuildError` only to project those
ordered diagnostics into its public report. It does not normalize, regroup, or
revalidate them.

Trusted Swift compilation is not a `validate_heist` input and is never invoked
by this command. Its lower-level contract still converges on the same admitted
plan: `compileFile(_:)` returns `HeistPlan`, while failure throws
`HeistPlanBuildError` with ordered diagnostics. `compileDirectory(_:)` returns
`HeistCatalogCompilationResult`; its `catalog` is the successful value and its
`diagnostics` retain ordered non-error diagnostics. A single anonymous
capability succeeds with `catalogAnonymousCapability` as a warning. The same
condition in a multi-source catalog is an error and throws
`HeistPlanBuildError`. Compiler arguments flow directly from artifact
resolution to execution without a second artifact or validation result shape.

### 4. Root invocation validation

After plan admission, decode `argument` through the existing
`decodeRootHeistArgument` representation and call the same
`HeistArgumentAdmission.validateRootArgument` operation used by `run_heist`.

This phase is skipped only when plan admission did not produce a `HeistPlan`.
It performs no target resolution. An accessibility-target argument is checked
for grammar and type, not for presence in an app.

### 5. Authoring lint

If `lint` is not `none`, call `HeistPlan.lint` once with the selected mode.
Preserve finding order from the canonical traversal. Do not convert lint
findings into build diagnostics.

Each public lint finding contains:

| Field | Type | Meaning |
|---|---|---|
| `severity` | `warning` or `error` | Existing `HeistPlanLintFinding.Severity` |
| `path` | string | Public rendering of the canonical typed `HeistPlanPath` |
| `message` | string | What the authoring issue is |
| `suggestion` | string, optional | A concrete repair |

### 6. Canonical rendering

For an admitted plan, render `plan.canonicalSwiftDSL()` and return it as
`canonicalPlan`. Canonical rendering runs regardless of root-argument or lint
outcome because both operate on an already valid reusable plan.

If canonical rendering cannot represent an admitted plan, return a Button
Heist internal/tool failure. Do not report the plan as valid without canonical
source. This condition indicates implementation drift between admission and
the canonical renderer.

### 7. Response projection

Assemble one immutable `HeistValidation.Report` value. Public JSON, compact
text, and MCP `structuredContent` MUST project from that value. Do not assemble
three similar response shapes independently.

## Result semantics

### Plan rejection is a successful tool operation

An invalid plan is the expected result of a validation tool. When a
well-shaped call identifies one source but its plan cannot parse, decode, pass
root structural admission, or pass runtime-safety validation:

- MCP `isError` MUST be `false`;
- public `status` MUST be `ok`;
- `plan.valid` MUST be `false`;
- `admissible` MUST be `false`;
- structured build diagnostics MUST be present;
- `canonicalPlan` MUST be absent;
- invocation and lint MUST be marked `not_evaluated`.

This lets an agent consume diagnostics and retry without treating ordinary
authoring mistakes as transport failures.

### Malformed tool calls are errors

The operation MUST use the ordinary MCP error response and `isError: true`
when it cannot identify a valid validation request. Examples include unknown
arguments, wrong JSON types, oversized input, and missing or conflicting source
selection.

Unexpected internal failures also use the ordinary error response.

### No validation capability

The response MUST NOT contain a validation token, execution token, cached plan
handle, or flag that causes `run_heist` to trust prior work. `run_heist` parses
and validates its own inputs again immediately before any connection or
dispatch.

## Structured response contract

### Response shape

```json
{
  "status": "ok",
  "admissible": true,
  "plan": {
    "valid": true,
    "version": 3,
    "name": "checkout",
    "parameter": {
      "type": "none"
    },
    "definitionCount": 0,
    "topLevelStepCount": 1
  },
  "invocation": {
    "status": "valid",
    "argumentProvided": false,
    "diagnostics": []
  },
  "lint": {
    "mode": "composition_quality",
    "status": "passed",
    "findings": []
  },
  "buildDiagnostics": [],
  "canonicalPlan": "HeistPlan(\"checkout\") {\n    Activate(.label(\"Pay\"))\n        .expect(.screenChanged())\n}"
}
```

The public status spellings are:

```text
invocation.status = valid | invalid | not_evaluated
lint.status = passed | findings | not_evaluated
```

`lint.status` is `findings` when one or more findings exist, regardless of
severity. `lint.passed` is not a separate wire field; callers derive pass/fail
from whether any returned finding has severity `error`. This avoids storing two
representations of the same fact.

`plan.name` is omitted for an anonymous root plan. A `none` parameter omits a
name. String and accessibility-target parameters include their declared name:

```json
{
  "type": "string",
  "name": "query"
}
```

The public type spelling for an accessibility-target parameter is
`accessibility_target`, matching `HeistParameterKind.rawValue`.

`definitionCount` and `topLevelStepCount` count only the root plan's immediate
`definitions` and `body`. They do not flatten nested definitions or control
flow.

The response reuses the existing `PublicHeistBuildDiagnostic` JSON shape:

```json
{
  "code": "heist.source.invalid_syntax",
  "kind": "error",
  "phase": "source_compilation",
  "message": "…",
  "hint": "…",
  "path": "…",
  "sourceSpan": {
    "sourceName": "validate_heist-inline.plan",
    "offset": 18,
    "line": 1,
    "column": 19,
    "length": 8
  }
}
```

Optional diagnostic fields are omitted rather than encoded as `null`.

### Invalid source example

Request:

```json
{
  "plan": "HeistPlan { Activate(.label()) }"
}
```

Response shape:

```json
{
  "status": "ok",
  "admissible": false,
  "plan": {
    "valid": false
  },
  "invocation": {
    "status": "not_evaluated",
    "argumentProvided": false,
    "diagnostics": []
  },
  "lint": {
    "mode": "composition_quality",
    "status": "not_evaluated",
    "findings": []
  },
  "buildDiagnostics": [
    {
      "code": "heist.source.invalid_syntax",
      "kind": "error",
      "phase": "source_compilation",
      "message": "…"
    }
  ]
}
```

### Valid plan with invalid invocation

A parameterized plan without its required argument remains a valid reusable
plan but is not admissible as the corresponding `run_heist` request:

```json
{
  "status": "ok",
  "admissible": false,
  "plan": {
    "valid": true,
    "version": 3,
    "name": "search",
    "parameter": {
      "type": "string",
      "name": "query"
    },
    "definitionCount": 0,
    "topLevelStepCount": 1
  },
  "invocation": {
    "status": "invalid",
    "argumentProvided": false,
    "diagnostics": [
      {
        "code": "heist.planning.invalid_root_argument",
        "kind": "error",
        "phase": "planning",
        "message": "…",
        "hint": "Supply a string root argument."
      }
    ]
  },
  "lint": {
    "mode": "composition_quality",
    "status": "passed",
    "findings": []
  },
  "buildDiagnostics": [],
  "canonicalPlan": "…"
}
```

Root-argument diagnostics belong under `invocation.diagnostics`, not the
top-level `buildDiagnostics`. Top-level diagnostics describe whether the plan
itself could be built. This prevents a valid reusable plan from appearing to
have plan-build errors.

### Valid plan with lint findings

```json
{
  "status": "ok",
  "admissible": true,
  "plan": {
    "valid": true,
    "version": 3,
    "parameter": {
      "type": "none"
    },
    "definitionCount": 0,
    "topLevelStepCount": 1
  },
  "invocation": {
    "status": "valid",
    "argumentProvided": false,
    "diagnostics": []
  },
  "lint": {
    "mode": "strict_test",
    "status": "findings",
    "findings": [
      {
        "severity": "error",
        "path": "body[0]",
        "message": "Semantic action has no expectation",
        "suggestion": "Attach .expect(...) or .withoutExpectation(\"reason\") to state the authored outcome; every action still proves terminal no-change."
      }
    ]
  },
  "buildDiagnostics": [],
  "canonicalPlan": "HeistPlan {\n    Activate(.label(\"Pay\"))\n}"
}
```

The plan is admissible because lint does not control runtime safety. The compact
text MUST make the lint finding visible before suggesting execution.

## Compact output

MCP text and CLI `--format compact` use the same concise summary. The full
canonical source and every diagnostic remain in MCP `structuredContent` and
CLI JSON output.

Admissible with no findings:

```text
heist validation: admissible; lint composition_quality: passed; canonical source in structuredContent
```

Admissible with findings:

```text
heist validation: admissible; lint strict_test: 1 error, 0 warnings
lint[error body[0]]: Semantic action has no expectation
suggestion: Attach .expect(...) or .withoutExpectation("reason")
canonical source in structuredContent
```

Invalid source:

```text
heist validation: not admissible; plan invalid
diagnostic[heist.source.invalid_syntax source_compilation error]: …
hint: …
```

Invalid invocation:

```text
heist validation: not admissible; plan valid; invocation invalid
diagnostic[heist.planning.invalid_root_argument planning error]: …
hint: …
canonical source in structuredContent
```

Do not include the entire canonical plan in compact text. That would duplicate
the structured response and consume agent context unnecessarily.

## CLI output

- `--format json` emits the exact public response contract documented above.
- `--format compact` emits the compact summary and diagnostics without the
  canonical plan body.
- `--format human` emits the readable summary and diagnostics, followed by a
  `Canonical plan:` section when plan admission succeeds.
- Automatic output selection remains unchanged: human for an interactive
  terminal and JSON when piped.

The command MUST render its report before applying the CLI exit-status policy.
CI receives diagnostics even when the command exits with status `1`.

## Internal design

### Command catalog

Add the typed command case:

```swift
case validateHeist = "validate_heist"
```

Route it through the existing heist command descriptor owner. Keep the current
`heistRuntime` family for this change to avoid an unrelated public command-family
migration. The descriptor is:

```swift
case .validateHeist:
    return makeDescriptor(
        family: .heistRuntime,
        requiresConnectionBeforeDispatch: false,
        parameters: Self.validationParameters,
        responseProjection: .heistValidation,
        projection: .cliAndMCP(
            Self.validateHeistDescription,
            mcpAnnotations: MCPToolAnnotationSpec(
                readOnlyHint: true,
                idempotentHint: true
            )
        )
    )
```

Do not mark the descriptor as `.appInteraction` or `.heistPrimitive`.

### Typed request

Add a named request shape. Do not pass a tuple across files:

```swift
struct ValidateHeistRequest: Sendable {
    let source: HeistPlanLoadRequest
    let argument: HeistArgument
    let argumentProvided: Bool
    let lintMode: HeistValidationLintMode
}
```

`HeistValidationLintMode` is a `String`-backed, `CaseIterable`, `Sendable`, and
`Equatable` enum at the public command boundary. Its values map explicitly to
the existing `HeistPlanLintMode`; do not compare raw strings after decoding.

### Typed report

Use one package-only validity algebra for every result phase and compose those
values into the public report:

```swift
public enum HeistValidation {
    package enum Result<Value: Sendable & Equatable>: Sendable, Equatable {
        case valid(Value)
        case invalid([HeistBuildDiagnostic])
        case notEvaluated
    }

    public struct Report: Sendable, Equatable {
        package let plan: Result<PlanSummary>
        package let invocation: Result<InvocationSummary>
        package let argumentProvided: Bool
        package let lint: Lint
        package let canonicalPlan: String?
    }
}
```

`Result<Value>` is the sole validity state machine for plan and invocation.
`HeistValidation.Lint` owns lint's distinct mode/findings algebra. Invalid and
not-evaluated states are explicit cases, not coordinated optionals, booleans,
or phase-specific result types. The package-only algebra does not cross the
public boundary; `PublicHeistValidationResponse` renders the documented JSON
contract from `HeistValidation.Report`.

### Ownership

- `ThePlans` owns plan loading, root-argument validation, lint, and canonical
  rendering.
- `TheFence` owns public command admission, phase orchestration, the typed
  report, and response projection.
- `ButtonHeistCLI` owns option parsing, output selection, and the one-shot
  process exit policy. It owns no plan validation rules.
- `ButtonHeistMCP` remains a thin adapter. It lists the catalog-generated tool,
  forwards arguments unchanged, and renders the `FenceResponse`.
- No validation logic belongs in `ButtonHeistMCP`.

### Fence response

The Fence response carries the report directly:

```swift
case heistValidation(HeistValidation.Report)
```

Add `.heistValidation` to `FenceCommandResponseProjection` and every exhaustive
formatter/projection switch.

`FenceResponse.isFailure` MUST return `false` for `.heistValidation`, including
when `report.admissible` is false. The validation operation completed normally.

### Pure orchestration

The handler should be a pure read pipeline after request decoding:

```text
load one root-admitted HeistPlan
→ validate invocation if a plan exists
→ lint if requested and a plan exists
→ render canonical source if a plan exists
→ return report
```

It MUST NOT inspect `handoff`, `sessionConnectionSnapshot`, target config, or
the accessibility runtime.

Do not catch and flatten all errors into strings. Preserve existing
`HeistBuildDiagnostic` values and stable codes through the public projection.

### Expected file impact

The implementation should remain within the existing owners:

| Area | Expected change |
|---|---|
| `TheFence+CommandCatalog.swift` | Add the typed command and response-projection cases |
| `TheFence+CommandCatalog+RunHeist.swift` | Define the CLI-and-MCP descriptor, parameters, annotations, and description |
| `FenceParameter.swift` and `FenceParameter+Factories.swift` | Add the typed lint parameter key and enum-backed parameter |
| `TheFence+HeistAdmission.swift` | Decode the request and orchestrate the shared plan and argument admission paths |
| `TheFence+RequestPayload.swift` | Route the admitted command to its offline handler |
| New heist-validation model/projection file | Own the request result state machine, summary, and compact projection |
| `FenceResponseModels.swift` | Add the typed response case and failure semantics |
| `FenceJSON+Response.swift` | Add the public structured response projection and reuse public build diagnostics |
| `TheFence+Formatting.swift` and `TheFence+Formatting+Compact.swift` | Add exhaustive human and compact rendering |
| New `ValidateHeistCommand` CLI adapter | Parse CLI options, render the shared response, and apply exit status |
| `CLICommandAdapterCatalog` | Bind `.validateHeist` to the CLI adapter |
| CLI command-sync tests | Cover registration, arguments, output, exit status, and absence of connection options |
| ButtonHeist fence tests | Cover admission, result semantics, formatting, and isolation |
| ButtonHeistMCP tests | Cover generated tool schema, routing, annotations, and `isError` behavior |
| Public command contract fixture | Record the additive shared command contract |

The MCP server source should require no command-specific branch. Its generic
catalog, routing, and response code must carry the new descriptor and response.
If command-specific parsing appears in `ButtonHeistMCP`, move it back to
TheFence.

## Limits and security

- Reuse the `run_heist` request-envelope limits.
- Reuse `HeistPlanRuntimeSafetyLimits` for admitted plans.
- Continue strict unknown-field rejection.
- Accept only restricted inline DSL and generated `.heist` artifacts.
- Never compile or execute arbitrary Swift from MCP.
- Expand `~` and resolve `.heist` paths exactly as `run_heist` does. Do not add
  another path interpretation.
- Do not follow a URL or fetch a remote artifact.
- Do not write canonical source, temporary artifacts, or repaired plans to
  disk.
- Do not include filesystem contents other than the selected artifact in a
  diagnostic.
- Do not include environment tokens, target configuration, or session failures
  in the report.
- Preserve deterministic diagnostic and lint ordering.

## Relationship to `run_heist`

`validate_heist` and `run_heist` share source admission and root-argument
validation, but have different terminal effects:

```text
source or artifact
→ shared plan loading
  ├→ validate_heist → lint → canonical report
  └→ run_heist → connect → wire dispatch → result
```

The common loading and root-argument prefix MUST remain one implementation
pipeline so rule changes apply to both commands.

`run_heist` MUST always repeat admission. A client may change the source or
artifact between calls, and a validation report carries no authority.

## Relationship to existing tools

- `perform` remains the one-step execution tool. It requires a session when it
  dispatches.
- `run_heist` remains the durable multi-step execution tool.
- `list_heists` remains offline catalog discovery for an admitted plan.
- `describe_heist` remains offline capability inspection for an admitted plan.
- `buttonheist plan validate` remains artifact-only local validation.
- `buttonheist plan compile` remains trusted Swift-to-artifact compilation outside
  MCP.

The top-level CLI command is the ergonomic preflight counterpart to
`run_heist`. `buttonheist plan` remains useful for explicit artifact pipelines
and format conversion.

Do not implement `validate_heist` by calling `list_heists` or
`describe_heist`. They consume an admitted plan for different purposes.

## Tests

### ThePlans tests

Existing parser, admission, lint, argument, artifact, and canonical-rendering
tests remain the source of truth. Add tests only if implementation exposes a
missing pure operation needed by both `validate_heist` and `run_heist`.

### ButtonHeist fence tests

Add handler and response tests for:

1. valid anonymous inline plan with default lint;
2. valid named inline plan;
3. valid `.heist` artifact path;
4. malformed inline source produces a normal validation report;
5. artifact decode or version rejection produces a normal validation report;
6. plan runtime-safety rejection preserves stable build diagnostics;
7. missing both sources is a request error;
8. both sources is a request error;
9. raw public JSON IR fields are rejected;
10. non-`.heist` path is rejected as plan validation output;
11. parameterless plan plus omitted argument is admissible;
12. parameterized plan plus omitted argument has valid plan and invalid
    invocation;
13. parameterized plan plus matching argument is admissible;
14. parameterized plan plus wrong argument kind has invalid invocation;
15. accessibility-target argument grammar is checked without live resolution;
16. `lint: none` returns `not_evaluated` with no findings;
17. composition-quality warnings do not change admissibility;
18. strict-test errors do not change admissibility;
19. valid plans return stable canonical source;
20. invalid plans omit canonical source;
21. compact text summarizes diagnostics without duplicating canonical source;
22. public JSON omits absent optional fields;
23. invalid plan reports make `FenceResponse.isFailure == false`;
24. malformed requests make `FenceResponse.isFailure == true`.

Add an isolation test that supplies a fence whose discovery and connection
boundaries trap or record calls. Execute valid and invalid `validate_heist`
requests and assert that neither boundary is invoked. Also assert that the
fence remains disconnected after each call.

### MCP tests

Update tool and routing tests to prove:

- `validate_heist` appears in `tools/list`;
- it is MCP-exposed;
- annotations advertise read-only and idempotent behavior;
- its schema exposes `plan`, `path`, `argument`, and `lint`;
- its schema excludes raw IR fields;
- its schema is closed and has no top-level combinators;
- `lint` advertises all three values and the correct default;
- routing forwards source text and arguments opaquely to TheFence;
- an invalid plan renders `isError: false` with structured diagnostics;
- a malformed tool request renders `isError: true`;
- canonical source is present in `structuredContent`, not duplicated in compact
  text.

### CLI tests

Add CLI contract and command tests that prove:

- `validate_heist` appears as a top-level subcommand and maps to the same Fence
  descriptor as MCP;
- the command accepts exactly one of `--plan` or `--path`;
- `--argument` uses the shared canonical `HeistArgument` JSON shape;
- `--lint` advertises all three values and uses the catalog default;
- the command has no connection, device, token, or session options;
- `.heist` paths and inline source reach TheFence unchanged;
- `.swift` and non-`.heist` paths are rejected, and no surface exposes an
  `entry` field;
- human, compact, and JSON formats project from the same response;
- invalid plan diagnostics are printed before exit status `1`;
- strict-test error findings produce exit status `1`;
- warning-only findings produce exit status `0`;
- an admissible plan with no lint errors produces exit status `0`;
- JSON-lines returns the normal report and continues after an inadmissible
  plan.

### Contract fixtures

Regenerate or update the public command contract fixture after the descriptor
is final. Treat the new input and response JSON shapes as public contracts.

### Canonical test commands

Run at minimum:

```bash
scripts/test-runner.py run MacFrameworkTests
```

Run the ButtonHeistMCP package tests through the repository gate:

```bash
./scripts/swift-test-gate.sh ButtonHeistCLI
./scripts/swift-test-gate.sh ButtonHeistMCP
```

If project configuration changes are required, regenerate with:

```bash
./scripts/generate-project.sh
```

Then run the relevant hosted suites when the implementation touches runtime
plan execution or shared iOS admission behavior.

## Implementation sequence

Follow the repository's API → tests → implementation workflow:

1. Add the command enum, descriptor, parameter enum, response case, and typed
   report states with non-operational stubs.
2. Add the public JSON, compact-text, CLI, routing, isolation, and MCP contract
   tests. Confirm that behavior tests do not pass against the stubs.
3. Implement request decoding and the pure shared-admission pipeline.
4. Implement canonical rendering, lint projection, and response formatting.
5. Run the focused tests, then the canonical project checks required by the
   touched targets.
6. Update the shipping documentation only when the tool behavior is present.

## Documentation changes

When the feature ships:

- add `validate_heist` to the durable-boundary and core-loop sections of
  `docs/MCP-AGENT-GUIDE.md`;
- add the offline validation branch to
  `docs/diagrams/heist-lifecycle.md`;
- add the shared request and response contract to `docs/API.md`;
- document the CLI invocation, output, and exit-status contract in
  `docs/API.md` and `docs/CI.md`;
- state in `docs/HEIST-LANGUAGE-SPEC.md` that CLI, JSON-lines, and MCP
  validation use the same root `HeistPlan` admission and runtime-safety pass as
  execution;
- update generated MCP tool documentation or fixtures;
- add a README section only if the shipped feature has no existing README
  coverage. Do not rewrite existing README prose.

Recommended agent guidance:

```text
Before run_heist, call validate_heist with the same plan and argument. Repair
build or invocation diagnostics, then validate again. Treat lint findings as
authoring guidance. A successful offline validation cannot prove that live
targets exist or that expectations will pass.
```

## Compatibility and versioning

Adding `validate_heist` is an additive CLI, JSON-lines, and MCP contract. Its
response field names, enum values, diagnostic shapes, exit semantics, and
meaning of `admissible` become public API when shipped.

The command validates against the plan and artifact versions supported by the
running Button Heist client or MCP server. It MUST report unsupported artifact
versions through structured build diagnostics. It MUST NOT migrate or silently
reinterpret older artifacts.

Canonical source reflects the running Button Heist version's one canonical
spelling. Callers SHOULD preserve authored source and regenerate `.heist`
artifacts when plan versions change.

## Acceptance criteria

The feature is complete when all of the following are true:

- An MCP client with no active app can validate inline canonical source.
- The same client can validate a local generated `.heist` artifact.
- A CLI caller can validate inline source or a `.heist` artifact without an
  active app.
- The CLI returns status `1` for inadmissible requests and lint errors after
  printing diagnostics; warnings alone return status `0`.
- JSON-lines exposes the same command and structured response without a
  per-request process exit.
- No validation path attempts discovery, connection, or app communication.
- Invalid source returns stable structured diagnostics with MCP
  `isError: false`.
- Malformed tool input returns the ordinary request error with MCP
  `isError: true`.
- Valid plans return canonical source.
- Root arguments are checked with `run_heist` semantics.
- Lint mode is explicit, deterministic, and does not alter runtime admission.
- `run_heist` still validates every request independently.
- CLI options, MCP schemas, JSON-lines routing, response projections, compact
  formatting, public contract fixtures, and documentation agree.
- Canonical repository tests pass with warnings treated as errors.
