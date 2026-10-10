# Bumper Bowling Rules

Button Heist uses Bumper Bowling for source boundaries that Swift and package
manifests cannot fully express.

Bumper's architecture model owns component paths, internal dependency direction,
capability access, and banned concurrency escape hatches. Custom rules fill the
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
| `forbidden_import` | Only named components can use each platform capability. | Move the platform work to an allowed boundary and pass typed values inward. |
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
| HeistPlanTool | ThePlans |
| ButtonHeistCLI | ButtonHeist, ThePlans, TheScore |
| ButtonHeistMCP | ButtonHeist, TheScore |
| BH Demo | TheInsideJob, ThePlans, TheScore |

Platform capabilities have narrow owners:

| Capability | Allowed components |
| --- | --- |
| UIKit and SwiftUI | TheInsideJob, ThePlant, and BH Demo |
| Network.framework | TheInsideJob, ThePlant, ButtonHeist, ButtonHeistSupport, and TheScore |
| Security.framework | TheScore |
| Objective-C runtime | TheInsideJob and ThePlant |
| Live accessibility parser products | TheInsideJob and ThePlant |

ThePlans also rejects persistence, test frameworks, ArgumentParser, and MCP.
TheScore rejects UI, persistence, and test frameworks.

## Custom Rules

These rules cover source invariants that the component graph and Swift access
control cannot force.

| Rule ID | What it protects | Repair |
| --- | --- | --- |
| `buttonheist.any_boundary` | The exact current Foundation and Objective-C bridge declarations are the only production declarations that use `Any`. The rule does not prove runtime normalization. | Convert the external value to a typed Button Heist value at its boundary. |
| `buttonheist.callback_isolation` | Stored `onFoo` callbacks declare `@Sendable` or a global actor. The rule also resolves file-local callback aliases. | Add the callback's actor or Sendability contract to its outer function type. |
| `buttonheist.heist_content_opacity` | `HeistContent` exposes no public stored or computed property. | Keep builder state internal and create `HeistPlan` through its public initializer. |
| `buttonheist.plan_else_ownership` | Only `WaitFor` and `IfContent` expose a DSL `else` branch. | Use a wait predicate or an enclosing conditional instead of a loop-local alternate body. |
| `buttonheist.exported_tuple_contract` | Public, open, and package declarations use named contract types instead of multi-value tuples. | Add a named Swift type or narrow the declaration's access. |

The tuple rule covers function parameters and returns, typed properties,
subscripts, protocol requirements, and inherited extension access. It permits
local tuple scratch values and non-exported declarations.

## Construction Boundaries

Swift now enforces the constructor boundaries that Bumper once checked by file
name:

| Type | Compiler-enforced entry point |
| --- | --- |
| `TheSafecracker.TouchEvent` | Its private initializer is used only by `dispatch(touches:)`. |
| `HeistSwiftFileCompilation` | Its private initializer is used only by its static `compile` operation. |
| `TheFence.HeistExecutionBudget` | Its private initializer is used only by `project`. |
| `HeistReport` | Its private initializer is used only by `project(result:)`. |

These boundaries need no source-shape rule. Access control rejects every direct
construction outside the owning declaration.

## Test Policy

The `.bumper/Tests` suite tests only custom matching logic. It covers alias
resolution, effective Swift access, exact bridge exemptions, and DSL ownership.

It does not repeat Bumper's own tests for imports, syntax nodes, dependency
edges, cycles, or overlapping paths. Repository lint evaluates those built-in
assertions against the real source tree.

## Rule Lifecycle

A new custom rule must protect an invariant that Swift access control, target
boundaries, and Bumper's architecture model cannot express. It needs one valid
fixture, one valid violating Swift fixture, and a clear repair.

Delete a custom rule when Swift or the architecture model can reject the same
invalid state. Delete its fixtures and documentation in the same change.
