# Bumper Bowling Rules

Button Heist uses Bumper Bowling for source boundaries that Swift and package
manifests cannot fully express.

The repository's named Bumper rules own component paths, internal dependency
direction, platform imports, and banned concurrency escape hatches. Swift access
control owns private construction. Behavioral tests own runtime and wire behavior.

## Component Boundaries

`.bumper/Sources/BumperRules/ButtonHeistHouseStyle.swift` maps each production
target to one component and lists every allowed internal dependency. The package
manifests remain the build graph source of truth. Bumper makes the intended
direction visible and rejects source imports that cross it.

| Rule or test | What it protects | Repair |
| --- | --- | --- |
| `buttonheist.component_boundary` | A component imports only its listed Button Heist dependencies. | Move the work to the owning component or pass a typed value across an allowed edge. |
| Component-map test | The declared component graph stays acyclic. | Remove the reverse edge and restore one direction of ownership. |
| `buttonheist.source_ownership` and component-map test | Every included Swift file has one owner, and component paths do not overlap. | Update the component paths. |
| `buttonheist.platform_import` | Only named components can import each listed platform module. | Move the platform work to an allowed boundary and pass typed values inward. |
| `buttonheist.checked_concurrency` | Production code contains no `@preconcurrency` or `nonisolated(unsafe)`. | Model actor isolation and Sendability with checked Swift concurrency. |
| `buttonheist.unchecked_sendable_boundary` | Unchecked conformances belong only to the exact reviewed boundary declarations. | Use checked Sendable or review and register the declaration's safety argument. |
| `buttonheist.demo_accessibility_identifier` | Demo identifier references and overrides stay in the three named research files. | Use user-facing accessibility properties in demo screens. |

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
control cannot force. Import ownership uses Bumper 0.7.1 shared checks.
Source ownership, declaration access, contract types, and callback alias resolution
also use the upstream helpers. The component map and policy remain local.

| Rule ID | What it protects | Repair |
| --- | --- | --- |
| `buttonheist.any_boundary` | The exact current Foundation and Objective-C bridge declarations are the only production declarations that use `Any`. The rule does not prove runtime normalization. | Convert the external value to a typed Button Heist value at its boundary. |
| `buttonheist.callback_isolation` | Optional function slots, `onFoo` callbacks, and exported callback aliases declare `@Sendable` or a known global actor. File-local alias chains use nearest lexical scope. | Add the callback's actor or Sendability contract to its outer function type. |
| `buttonheist.heist_content_opacity` | `HeistContent` exposes no public members, including methods, initializers, subscripts, aliases, or nested types. | Keep builder state internal and create `HeistPlan` through its public initializer. |
| `buttonheist.plan_else_ownership` | Only `WaitFor` and `IfContent` expose a public DSL `else` branch. Private/internal helpers are permitted. | Use a wait predicate or an enclosing conditional instead of a loop-local alternate body. |
| `buttonheist.exported_tuple_contract` | Public, open, and package declarations use named contract types instead of multi-value tuples. | Add a named Swift type or narrow the declaration's access. |

The tuple rule covers function parameters and returns, initializer parameters,
typed properties, subscripts, typealiases, enum payload types, associated-type
defaults, protocol requirements, and inherited extension access. It ignores
setter access modifiers when evaluating getter visibility. It permits local
tuple scratch values and non-exported declarations. Named enum case parameters
such as `case pair(left: Int, right: Int)` are not tuple-valued payloads.

Bumper resolves access through same-file declarations. For unresolved targets,
the rules check written access on the declaration or its immediate type owner.
A tuple contract with written export intent fails with a repair message that
states the visibility uncertainty. Use a named type or narrow the declared
access. File colocation is not a required repair. Unresolved contracts without
written export intent remain unchecked. The opacity and DSL `else` rules use
the same public API intent policy. This does not prove compiler visibility.

| Rule ID | What it protects | Repair |
| --- | --- | --- |
| `buttonheist.transport_import_ownership` | `Network` and `FoundationNetworking` imports stay in the listed transport boundaries. | Pass typed values from the transport owner. |
| `buttonheist.security_import_ownership` | `Security` imports stay in the shared TLS boundary. | Use the canonical TLS operation. |

The callback rule covers explicitly typed optional function slots and `onFoo`
contracts. It also checks public and package function aliases whose names end
in `Callback`, `Handler`, or `Completion`, plus optional function aliases with
any name. Exported aliases are checked before any stored use. Private and
internal aliases still participate in resolution of checked variable types.

Ordinary non-optional synchronous dependency functions and aliases such as
`Predicate` remain allowed. These names define the convention; syntax alone
cannot establish that every function is a callback.

Callback isolation recognizes `MainActor`, the imported `ButtonHeistActor`, and
file-local `@globalActor` declarations. Actor names need no suffix. Optional and
qualified local aliases are supported; cycles terminate as unresolved. An
extension target's own aliases take precedence over file-level aliases. Aliases
provided by other extensions remain unresolved. C and
Objective-C ABI function types retain their calling convention instead of a
Swift isolation annotation. Computed function properties and protocol
requirements must preserve the same explicit contract.

These checks inspect explicit syntax. They do not infer types, resolve imported
aliases, prove symbol identity, or prove the absence of I/O through Foundation.
Compiler checks still own actor validity and concurrency correctness.

## Reviewed Boundary Exceptions

`BoundaryExceptionRules.swift` records four unchecked-conformance exceptions.
Each entry matches one repository-relative file and one qualified owner name.
Other types in the same file, same-named types in another file, and local types
remain subject to the rule. Same-file extensions of a registered owner are
permitted. Checked `Sendable` conformances need no exception.

| Owner | File under `ButtonHeist/Sources/TheInsideJob/` | Safety argument to maintain |
| --- | --- | --- |
| `PendingAccessibilityNotificationCallback` | `TheTripwire/AccessibilityNotificationObserver.swift` | Foreign notification payloads cross to the main queue for normalization. |
| `ConnectionAdmission` | `Server/NetworkBoundary/SocketConnectionAdmission.swift` | A lock protects the complete admission state machine. |
| `NetworkSocketListener` | `Server/NetworkBoundary/SocketListenerRuntime.swift` | The actor owns lifecycle; the Network boundary owns callbacks and invalidation is locked. |
| `PendingSocketConnections.OwnedConnection` | `Server/NetworkBoundary/SocketListenerRuntime.swift` | A connection leaves the locked registry for cancellation after its state transition. |

New exceptions need a reviewed safety argument and an exact registry entry.
The rule does not prove synchronization or validate comment contents. Changes
to an approved wrapper still need a review of its ownership and mutable state.

Demo identifier exceptions are exactly `ScrollSPIHarnessView.swift`,
`TraitValidationView.swift`, and `TraitProbeView.swift` under `TestApp/Sources/`.
The rule checks written references, including modifiers, assignments, reads,
key paths, and property overrides. A new research file needs an explicit entry;
a name containing `Research`, `Probe`, or `Harness` grants no exception.
Dynamic Objective-C lookup and inferred symbol identity remain outside this
syntax check. The rule protects our testing method; it does not prove VoiceOver
or Switch Control usability.

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
only the tests. CI uses the complete check on every change. The wrapper reports
build, tests, and lint durations with each phase's exit status, including failures.
It builds the CLI and rule tests first. The test and lint phases retain Bumper's
incremental SwiftPM checks and sandboxed source evaluation.

Pass file scopes to `Rules.files` and `Rules.forbid` so unrelated files skip
query traversal. In Bumper 0.7.1, query-level `within` filters after extraction.
`ContractDeclarationScope.swift` excludes getter-local scratch declarations
while keeping fields in local types subject to contract rules. Remove this
workaround after adopting the [upstream accessor-scope fix](https://github.com/TheButtonHeist/BumperBowling/pull/64). Getter-local alias
lookup still needs that upstream fix; this workaround does not change resolution.

Bumper Bowling is pinned to 0.7.1 in the ordinary `.bumper` Swift package.
It requires macOS 15 and Swift 6.4. Its SwiftLint-backed engine reports native
diagnostics. The wrapper keeps lint sandboxed and runs every rule test first.
Bumper's dependencies are separate from the app and framework package graph.

The suite covers custom matching, configured transport owners, component import
boundaries, concurrency checks, and source ownership. Component-map tests reject
overlapping paths and dependency cycles. Repository lint rejects unowned Swift
files directly; there is no separate filesystem coverage guard.

Coverage applies to Swift files using Bumper's hidden-file and exclusion
conventions. ThePlant's Objective-C shim is represented in the component map
but is not analyzed by SwiftSyntax. A native-only ownership scope is valid.

Tests exercise each repository convention with allowed and forbidden fixtures.
Repository lint checks the registered rules against real source.

## Rule Lifecycle

A new custom rule must protect an invariant that Swift access control, target
boundaries, and the existing rules cannot express. It needs one valid
fixture, one valid violating Swift fixture, and a clear repair.

Delete a custom rule when Swift or an existing rule can reject the same
invalid state. Delete its fixtures and documentation in the same change.
