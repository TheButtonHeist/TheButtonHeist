# CI integration

Heists run in CI in two topologies. Pick by where the test logic should live:
inside the app's own test bundle, or in a runner script that drives the app
from outside.

Both topologies share the version rule: the embedded `TheInsideJob` build and
the `buttonheist` CLI/MCP build must be the same release. The wire handshake
compares versions for exact equality and rejects mismatches, so pin the CLI to
the release your app embeds rather than installing "latest" in CI.

## App integration conformance

CI builds two small consumer apps:

- [SourceConsumer](../tests/fixtures/insidejob-source-consumer/Project.swift)
  compiles the current checkout through the `TheInsideJob` Swift package product.
- [BinaryConsumer](../tests/fixtures/insidejob-binary-consumer/Project.swift)
  uses only the prebuilt zip and its integration script.

Neither app imports TheInsideJob or calls its startup API. One shared check,
`scripts/check-insidejob-integration.py`, builds both apps in Debug and Release
for devices and simulators. Simulator Debug must start automatically and return
the app's accessibility tree through the matching CLI. Simulator Release must
run without a server listener.

The check also verifies that prebuilt frameworks are dynamic and weak-linked.
Release must exclude every distributed framework and resource. Source Release
must exclude the Debug loader symbols.

The hosted CI lane runs these checks before simulator cleanup. Release CI
repeats them before publication. Device builds use unsigned apps. Physical-device
execution remains a separate check.

## Result artifact contract

CI result capture uses the repository's existing wrapper, collector, and
manifest scripts. The contract is the script flow and the raw result files it
uploads, not a new evidence format:

- `scripts/run-with-heist-results.sh` wraps a test or replay command, sets
  `BUTTONHEIST_RESULTS_DIR` and `BUTTONHEIST_RESULTS_MODE`, preserves the
  wrapped command's exit status, and supports `--ios-sandbox` for
  simulator-hosted test processes that must write results inside their own
  container.
- `scripts/collect-ios-heist-results.sh` copies `*.json` and `*.json.gz`
  results from simulator `buttonheist-results` directories into the host
  artifact directory. It also writes `collection-diagnostics.txt`, and missing
  results are diagnostics rather than collection-script failures.
- `scripts/write-ci-heist-result-manifest.sh` writes `manifest.txt` and
  `result-files.txt` into the artifact directory so downloaded CI artifacts
  are readable without custom tooling.

Upload the whole result directory after the manifest step. Consumers should
look for `manifest.txt`, then inspect the raw `.json` or `.json.gz` results
listed in `result-files.txt`.

## Topology 1: app-hosted tests (recommended)

Heists embed directly in XCTest or Swift Testing through `ButtonHeistTesting`
and execute in-process. There is no server, port, or token: the test host runs
the heist runtime against its own accessibility tree. Any CI that can run your
iOS test bundle can run heists — no extra infrastructure.

```swift
import ButtonHeistTesting
import XCTest

@MainActor
final class CheckoutHeistTests: XCTestCase {
    func testCheckoutCompletes() async throws {
        try await runHeist("Checkout.pay") {
            Activate(.label("Pay"))
                .expect(.elementsChanged([.appeared(.label("Payment Complete"))]))
        }
    }
}
```

For app-hosted targets that share teardown machinery with synchronous test
suites, use `runHeistSync` (see
[Swift heist authoring](SWIFT-HEIST-AUTHORING.md)). Failures report through
`XCTFail` at the call site, so heist failures appear in your runner's normal
test results — no separate report plumbing.

To keep results as build artifacts, record them explicitly and upload the
directory:

```swift
runHeistSync("Checkout.pay", recordResult: .always, to: resultsURL) {
    Activate(.label("Pay"))
        .expect(.elementsChanged([.appeared(.label("Payment Complete"))]))
}
```

If no URL is supplied, results are written under the process temporary
directory at `buttonheist-results/`.

In this repository, use the canonical test runner. It applies the result
wrapper and owns the Xcode result-bundle and recorded-heist-result paths:

```bash
BUTTONHEIST_RESULTS_MODE=failures \
  scripts/test-runner.py run ButtonHeistTests
```

iOS simulator-hosted test bundles write inside the app/test process sandbox.
The runner selects an explicit simulator, applies the sandbox sentinel, and
collects results after each run and during failure cleanup:

```bash
BUTTONHEIST_RESULTS_MODE=failures \
  scripts/test-runner.py run TheInsideJobWindowTests \
  --simulator-name "$TASK_SLUG"
```

The canonical runner exposes four iOS suites:

| Runner suite | Hosting and coverage |
|--------------|----------------------|
| `TheInsideJobLogicTests` | Unhosted deterministic runtime and protocol logic |
| `TheInsideJobWindowTests` | `BH Demo`-hosted foreground-window, gesture, and live-observation coverage |
| `TheInsideJobIntegrationTests` | `BH Demo`-hosted real loopback, TLS, and server-transport integration coverage |
| `HostedBehaviorTests` | `BH Demo`-hosted behavior, dogfood, and adversarial aggregate |

The logic suite owns Button Heist's finite semantic algebra and complete
execution scheduling over explicit inputs. Its deterministic runtime scenarios
author notification records, pulse readings, virtual elapsed time, semantic
observations, and typed action outcomes; they do not start `CADisplayLink`,
read process notifications, capture a window, or wait on wall time. The window
and behavior suites keep assertions whose value comes from UIKit identity,
capture, gestures, focus, scrolling, presentation, app lifecycle, or the real
BH Demo process. Moving a semantic assertion into logic does not replace its
distinct platform canary.

### Test fixture ownership

| Layer | Canonical fixture owner | Contract |
|-------|-------------------------|----------|
| Portable plans, values, wire, and report projection | Target-local `TestSupport` values | No UIKit, networking, process state, or alternate semantic model |
| Admitted accessibility truth | `TheInsideJobTests/Shared/LogicWindow` element and observation values | Explicit value input with no live-capture fallback |
| Execution reducer | `HeistExecutionTestSupport.swift` | Reducer driven over typed snapshots, events, effects, and outcomes |
| Complete semantic runtime | `DeterministicRuntimeScenarioDriver.swift` | Real stream, Vault, host, reducer, result, and render projection over explicit inputs |
| Foreground UIKit boundary | `TheInsideJobWindowTests` specialist fixtures | Windows, live objects, capture, gestures, focus, scrolling, and restoration |
| Real application behavior | `ButtonHeistHostedTestSupport` and `AdversarialScenarioCatalog` | Authored heists against the actual BH Demo accessibility surface |

A higher-layer fixture composes the already tested lower implementation; it
does not recreate that implementation as a mock. Only platform action effects,
viewport exploration, and failure capture are scripted by the complete
deterministic runtime driver.

`TheInsideJobWindowTests` and `HostedBehaviorTests` share the
`HostedBehaviorTests` Xcode scheme and build products. The runner selects only
the window target for the former and excludes it from the latter, which runs
the hosted behavior, dogfood, and adversarial targets. Both projections run
serially on pull requests in one dedicated simulator. The scheduled
adversarial workflow owns the complete external-driver scenario matrix, with a
short daily pass and a deeper Sunday soak.

CI budgets macOS capacity explicitly:

- Portable release, parser, workflow, timing-parser, and automation contracts
  run on Linux.
- Pull requests use exactly three macOS runners: consolidated macOS validation
  (including every portable framework test target),
  deterministic iOS logic plus a trimmed demo smoke using one shared build,
  and foreground-window plus hosted behavior coverage.
- Pushes to `main` run those same three mandatory lanes. The genuine
  `TheInsideJobIntegrationTests` suite then runs behind the completed iOS logic
  lane, keeping macOS concurrency at three.
- A final `exact-sha-suite` job records the commit, workflow revision, run ID,
  and every required suite conclusion in `buttonheist-exact-sha-suite`. Release
  admission accepts only that successful aggregate and validates its manifest.
- Successful jobs publish timing summaries. Recorded heist results and Xcode
  result bundles are retained only when a job fails; the release admission
  manifest is retained for every main run.

This keeps the main validation topology within the same three-runner ceiling
while making the exact release SHA prove the complete required suite. CI and
local validation both delegate test driving to `scripts/test-runner.py`.

Run the complete portable framework suite with:

```bash
scripts/test-runner.py run MacFrameworkTests
```

For a bounded, maintained projection of a contract or critical invariant, use a
named focus instead of reconstructing scheme and test selectors:

```bash
scripts/test-runner.py catalog
scripts/test-runner.py run --focus contract-results
```

Every invocation writes `run.json` beside its result artifacts. The record
includes the exact commit, whether the tracked source tree was clean, the
selected tests, phase, outcome, exit code, timeout state, duration, and executed
test count. Tuist-backed runs reject a missing result bundle or zero executed
tests.

Run the logic, window, integration, and hosted behavior suites for complete iOS coverage:

```bash
scripts/test-runner.py run TheInsideJobLogicTests
scripts/test-runner.py run TheInsideJobWindowTests
scripts/test-runner.py run TheInsideJobIntegrationTests
scripts/test-runner.py run HostedBehaviorTests
```

CI preserves build-once execution without owning Xcode arguments:

```bash
scripts/test-runner.py build-for-testing TheInsideJobLogicTests
scripts/test-runner.py test-without-building TheInsideJobLogicTests
scripts/test-runner.py build-for-testing HostedBehaviorTests
scripts/test-runner.py test-without-building TheInsideJobWindowTests
scripts/test-runner.py test-without-building HostedBehaviorTests
```

## Topology 2: external driver

A CI step boots a simulator, launches the app with the embedded server
configured through environment variables, and drives it with the `buttonheist`
CLI. Use this when the flows live as `.heist` artifacts or when the driver is
an agent rather than a test bundle.

```bash
# One slug names everything this job owns: simulator, token, instance ID.
SLUG="ci-${CI_JOB_ID:-local}-checkout"
PORT=$((RANDOM % 10000 + 20000))

# Boot a dedicated simulator.
SIM_UDID=$(xcrun simctl create "$SLUG" "iPhone 16 Pro")
xcrun simctl boot "$SIM_UDID"
xcrun simctl bootstatus "$SIM_UDID" -b

# Install the debug build that links TheInsideJob, then launch it with an
# explicit port and token. simctl forwards SIMCTL_CHILD_* variables into the
# app process.
xcrun simctl install "$SIM_UDID" path/to/YourApp.app
SIMCTL_CHILD_INSIDEJOB_PORT="$PORT" \
SIMCTL_CHILD_INSIDEJOB_TOKEN="$SLUG" \
SIMCTL_CHILD_INSIDEJOB_ID="$SLUG" \
xcrun simctl launch "$SIM_UDID" com.example.yourapp

# Drive it. Simulator loopback needs no Bonjour, which CI machines often
# block anyway — connect directly by host:port.
export BUTTONHEIST_DEVICE="127.0.0.1:$PORT"
export BUTTONHEIST_TOKEN="$SLUG"

buttonheist run_heist --path Heists/Checkout.heist --junit report.xml
STATUS=$?

# Teardown.
xcrun simctl shutdown "$SIM_UDID"
xcrun simctl delete "$SIM_UDID"
exit $STATUS
```

`run_heist --junit` writes a JUnit XML report, so any CI system that ingests
JUnit can render heist steps as test results.

### Parallel jobs

Each job must own its simulator, port, and token. The convention is one
human-readable slug for all three — simulator name = token = instance ID —
so `xcrun simctl list devices booted` reads as a dashboard of running jobs and
an auth failure names whose session you hit. Ports are per-job; pick from a
range or let each job derive one. The full convention and its rationale are in
[Authentication](AUTH.md).

### Compiling artifacts in CI

To validate authored Swift heists without running them, compile in a build
step:

```bash
swift build --target ThePlans
swift build --package-path ButtonHeistCLI
HEIST_THEPLANS_BUILD_DIR="$PWD/.build/debug" \
  ButtonHeistCLI/.build/debug/buttonheist plan compile Heists/Checkout.swift --entry makeCheckoutHeist --output Checkout.heist
```

Artifact resolution options and diagnostics are covered in
[Swift heist authoring](SWIFT-HEIST-AUTHORING.md#compilation-boundary).

Validate the generated artifact without booting a simulator or establishing a
Button Heist session:

```bash
buttonheist validate_heist --path Checkout.heist --lint strict_test --format json
```

The command exits nonzero when the plan or root invocation is inadmissible, or
when the selected lint mode emits an error. Lint warnings do not change the
exit status. The same command is available through JSON-lines and MCP.

## Which topology when

| Situation | Topology |
|-----------|----------|
| Heists are regression tests for one app | App-hosted — failures land in the suite that owns the screen |
| Flows stored as `.heist` artifacts, replayed across builds | External driver |
| An agent explores or authors in CI | External driver |
| System dialogs or other-process surfaces in the flow | Pair with an out-of-process shell such as XCUITest; Button Heist still asserts only app-owned surfaces. See [Scope and limits](SCOPE-AND-LIMITS.md) |
