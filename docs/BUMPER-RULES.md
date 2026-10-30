# Bumper Bowling Rules

Button Heist uses Bumper Bowling for source boundaries that Swift and package
manifests cannot fully express.

Bumper's architecture model owns component paths, internal dependency direction,
platform imports, and banned concurrency escape hatches. Custom rules fill the
remaining source-level gaps. Swift access control owns private construction.
Behavioral tests own runtime and wire behavior.

## Architecture Model

`BumperBowling.swift` maps each production target to one component. It also
lists every allowed internal dependency. The package manifests remain the build
graph source of truth. Bumper makes the intended direction visible and rejects
source imports that cross it.

| Bumper assertion | What it protects | Repair |
| --- | --- | --- |
| `component_boundary` | A component imports only its listed Button Heist dependencies. | Move the work to the owning component or pass a typed value across an allowed edge. |
| `declared_dependency_cycle` | The declared component graph stays acyclic. | Remove the reverse edge and restore one direction of ownership. |
| `duplicate_ownership` | Component source paths do not overlap. | Remove the overlapping `Owns` declaration. This assertion does not detect an unowned path. |
| `forbidden_import` | Only named components can import each listed platform module. | Move the platform work to an allowed boundary and pass typed values inward. |
| `forbidden_syntax_node` | Production code contains no `@preconcurrency` or `nonisolated(unsafe)`. | Model actor isolation and Sendability with checked Swift concurrency. |

The internal dependency graph is:

| Component | Allowed Button Heist dependencies |
| --- | --- |
| ThePlans | None |
| TheScore | ThePlans |
| TheInsideJob and ThePlant | ButtonHeistSupport, ThePlans, TheScore |
| ButtonHeist | ButtonHeistSupport, ThePlans, TheScore |
| ButtonHeistSupport | None |
| ButtonHeistTesting | TheInsideJob, ThePlans |
| ButtonHeistCLI | ButtonHeist, ThePlans, TheScore |
| ButtonHeistMCP | ButtonHeist, TheScore |
| BH Demo | TheInsideJob, ThePlans, TheScore |

Platform imports have narrow owners:

| Imported module | Allowed locations |
| --- | --- |
| UIKit and SwiftUI | TheInsideJob, ThePlant, and BH Demo |
| Network and FoundationNetworking | Client/server `NetworkBoundary` folders, the discovery boundary files, `ServerTransport.swift`, `NetworkTransportFailure.swift`, and `TLSPreSharedKeyMaterial.swift` |
| Security | `TheScore/Core/TLSPreSharedKeyMaterial.swift` |
| Objective-C runtime | TheInsideJob and ThePlant |
| Live accessibility parser products | TheInsideJob and ThePlant |

ThePlans also rejects persistence, test frameworks, ArgumentParser, and MCP.
TheScore rejects UI, persistence, and test frameworks.

## Custom Rules

These rules cover source invariants that the component graph and Swift access
control cannot force. Import ownership uses Bumper's standard shaper.

| Rule ID | What it protects | Repair |
| --- | --- | --- |
| `buttonheist.any_boundary` | The exact current Foundation and Objective-C bridge declarations are the only production declarations that use `Any`. The rule does not prove runtime normalization. | Convert the external value to a typed Button Heist value at its boundary. |
| `buttonheist.callback_isolation` | Optional function slots and `onFoo` callbacks declare `@Sendable` or a known global actor. Optional slots are checked regardless of the binding name. File-local alias chains use nearest lexical scope. | Add the callback's actor or Sendability contract to its outer function type. |
| `buttonheist.heist_content_opacity` | `HeistContent` exposes no public members, including methods, initializers, subscripts, aliases, or nested types. | Keep builder state internal and create `HeistPlan` through its public initializer. |
| `buttonheist.plan_else_ownership` | Only `WaitFor` and `IfContent` expose a public DSL `else` branch. Private/internal helpers are permitted. | Use a wait predicate or an enclosing conditional instead of a loop-local alternate body. |
| `buttonheist.exported_tuple_contract` | Public, open, and package declarations use named contract types instead of multi-value tuples. | Add a named Swift type or narrow the declaration's access. |

The tuple rule covers function parameters and returns, initializer parameters,
typed properties, subscripts, typealiases, enum payload types, associated-type
defaults, protocol requirements, and inherited extension access. It ignores
setter access modifiers when evaluating getter visibility. It permits local
tuple scratch values and non-exported declarations. Named enum case parameters
such as `case pair(left: Int, right: Int)` are not tuple-valued payloads.

| Rule ID | What it protects | Repair |
| --- | --- | --- |
| `buttonheist.transport_import_ownership` | `Network` and `FoundationNetworking` imports stay in the listed transport boundaries. | Pass typed values from the transport owner. |
| `buttonheist.security_import_ownership` | `Security` imports stay in the shared TLS boundary. | Use the canonical TLS operation. |

The callback rule covers explicitly typed optional function slots and `onFoo`
contracts. It permits non-optional synchronous dependency functions with other
names: syntax alone cannot establish that they are callbacks.

Callback isolation recognizes `MainActor`, the imported `ButtonHeistActor`, and
file-local `@globalActor` declarations. Actor names need no suffix. Optional and
qualified local aliases are supported; cycles terminate as unresolved. C and
Objective-C ABI function types retain their calling convention instead of a
Swift isolation annotation. Computed function properties and protocol
requirements must preserve the same explicit contract.

These checks inspect explicit syntax. They do not infer types, resolve imported
aliases, prove symbol identity, or prove the absence of I/O through Foundation.
Compiler checks still own actor validity and concurrency correctness.

## Construction Boundaries

Swift now enforces the constructor boundaries that Bumper once checked by file
name:

| Type | Compiler-enforced entry point |
| --- | --- |
| `TheSafecracker.TouchEvent` | Its private initializer is used only by `dispatch(touches:)`. |
| `HeistSwiftCompilation` | Its private initializer is used only by its static `compile` operation. |
| `TheFence.HeistExecutionBudget` | Its private initializer is used only by `project`. |
| `HeistReport` | Its private initializer is used only by `project(result:)`. |

These boundaries need no source-shape rule. Access control rejects every direct
construction outside the owning declaration.

## Test Policy

Run `scripts/check-source-shape.sh` for the complete source check. It runs the
rule tests before repository lint. `scripts/check-source-shape.sh test` runs
only the tests. CI uses the complete check on every change.

The suite covers custom matching, configured transport owners, and ownership
coverage. The coverage test reads `bumper.architecture` and requires exactly one
component owner for every included, non-excluded Swift file. It runs outside the
sandboxed rule evaluator because Bumper 0.6 discards unowned files before rules
can inspect them. The wrapper provides `BUTTONHEIST_SOURCE_ROOT` explicitly.
Remove this local filesystem guard when upstream
[Bumper issue #55](https://github.com/TheButtonHeist/BumperBowling/issues/55)
provides coverage enforcement.

Coverage applies to Swift files using Bumper's hidden-file and exclusion
conventions. ThePlant's Objective-C shim is represented in the component map
but is not analyzed by SwiftSyntax. A native-only ownership scope is valid.

Tests do not repeat Bumper's import-matching, dependency-cycle, or syntax-node
algorithms. Transport fixtures test our allowed locations. Repository lint
checks the built-in assertions against real source.

## Rule Lifecycle

A new custom rule must protect an invariant that Swift access control, target
boundaries, and Bumper's architecture model cannot express. It needs one valid
fixture, one valid violating Swift fixture, and a clear repair.

Delete a custom rule when Swift or the architecture model can reject the same
invalid state. Delete its fixtures and documentation in the same change.
