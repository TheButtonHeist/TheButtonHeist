# CI integration

Heists run in CI in two topologies. Pick by where the test logic should live:
inside the app's own test bundle, or in a runner script that drives the app
from outside.

Both topologies share the version rule: the embedded `TheInsideJob` build and
the `buttonheist` CLI/MCP build must report the same full version. The wire
handshake compares versions for exact equality and rejects mismatches. Pin the
CLI to the release or development contract that your app embeds.

## Contract version guard

The required `release-contract` job runs `scripts/check-contract-version.py`
on pull requests and pushes to `main`. Development changes retain the last
release number and append a checked-in contract hash, such as
`0.7.0-a81d93c047e2`. These identities do not create releases or tags.

The hash covers every Swift source in `TheScore` and `ThePlans`, including
paths, comments, additions, deletions, and renames. The version declaration
itself is excluded. ThePlans defines plan and action types that TheScore sends
over the wire. Adapter and runtime implementation changes outside these modules
do not change this fingerprint.

After a shared contract change, update the checked-in version:

```bash
python3 scripts/check-contract-version.py --update
```

The script uses the first 12 hexadecimal characters of SHA-256 over ordered
source paths and contents. Every build reads the resulting version constant.
Consumers need no Git checkout or build-time generator.

For pull requests, CI checks the exact base and head commits. For main pushes,
it checks the previous and new main commits. CI rejects a missing, malformed,
or stale hash. Worktree changes cannot mask a stale committed value.

To prepare a release, change the release number and clear the hash:

```bash
scripts/bump-version.sh <new-version>
```

A release preparation must exceed the newest release tag. Unpublished version
numbers can be reconciled before publication. A release bump clears the hash;
later contract changes require a hash again. Release publication is a separate
operation and rejects development versions.

To check two committed snapshots locally:

```bash
python3 scripts/check-contract-version.py origin/main HEAD
python3 scripts/tests/check-contract-version-test.py
```

## App integration conformance

CI builds two small consumer apps:

- [SourceConsumer](../tests/fixtures/insidejob-source-consumer/Project.swift)
  compiles the current checkout through the `TheInsideJob` Swift package product.
- [BinaryConsumer](../tests/fixtures/insidejob-binary-consumer/Project.swift)
  uses only the prebuilt zip and Debug-only build settings.

Neither app imports TheInsideJob or calls its startup API. One shared check,
`scripts/check-insidejob-integration.py`, builds both apps in Debug and Release
for devices and simulators. Simulator Debug must start automatically and return
the app's accessibility tree through the matching CLI. Simulator Release must
run without a server listener.

The check also verifies that the prebuilt framework is dynamic and contains its
resources. Its only dynamic dependencies must be Apple libraries. Release and a
custom Staging configuration must exclude the runtime from linking and embedding. Source Release
must exclude the Debug loader symbols.

The same check compiles an external Mac Swift package consumer of `ButtonHeist`
and `TheScore`. It runs the public client against source-linked, prebuilt-linked,
and injected runtimes. Each path must capture current geometry, select a subtree,
tap a button, wait for changed UI, return failed-heist evidence, continue after
that failure, and reconnect through both `ButtonHeist.run` overloads.
Injection uses an unlinked Release host and the same XCFramework slices.

`SwiftClientTests` in `MacFrameworkTests` cover connection rejection, cancellation
before and during connection, server errors, wrong reply types, send failures,
response deadlines, and overlapping request identities through mocked transport.
Window tests prove that current capture refreshes geometry and removes vanished
visible elements without discovery scrolling.

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
  and every required suite conclusion in `buttonheist-exact-sha-suite`.
  Release admission checks the signature and GitHub job results for that exact
  SHA. It requires a successful push run from `ci.yml` on `main`, including all
  five suites and the aggregate in its current attempt. It reads every page of
  job results. The diagnostic manifest can expire without blocking admission.
  Publication reuses the existing CI result and starts no source CI run.
- Successful jobs publish timing summaries. Recorded heist results and Xcode
  result bundles are retained only when a job fails; the release admission
  manifest is retained for every main run.

This keeps the main validation topology within the same three-runner ceiling
while making the exact release SHA prove the complete required suite. CI and
local validation both delegate test driving to `scripts/test-runner.py`.

## Release publication

Run `scripts/release.sh` from clean, signed, green `main`. If the version needs
a bump, the script prepares it and stops for review and merge. Otherwise it
creates the official tag and dispatches `release.yml` from `main`.

The workflow has three jobs:

1. **Admit:** Run trusted scripts from the protected main workflow revision.
   Validate `vMAJOR.MINOR.PATCH`, resolve the tag once, verify its source version,
   signature and existing main CI, then check the tap token's actual Contents
   write permission. The permission check recreates the tap's existing Git tree;
   it changes no branch or commit.
2. **Build:** Check out only the admitted SHA. Build and verify the archives,
   including both app integration methods, then retain them for 14 days.
   This job has read-only credentials and no tap token.
3. **Publish:** Run trusted publication scripts from the main workflow revision.
   Download the verified archives, verify uploaded bytes, publish the release,
   and update both Homebrew formulas. Formula templates come from the admitted
   release commit so older archive layouts remain installable.

Retry a failed publication job with **Re-run failed jobs**. The successful build
job does not repeat. If the release is already published, dispatch a new workflow:

```bash
gh workflow run release.yml --repo TheButtonHeist/TheButtonHeist --ref main -f tag=v0.7.1
```

Admission still runs. An already-published release skips the build and verifies
its published assets before repairing the tap. A missing or invalid tap token
fails the release. Tags and published archives are never replaced during recovery.

Keep `main` protected. The [creation rule](https://github.com/TheButtonHeist/TheButtonHeist/rules/25949171)
restricts `v*` tags to maintain/admin roles. The
[immutability rule](https://github.com/TheButtonHeist/TheButtonHeist/rules/25949146)
blocks updates and deletion without a bypass. Release dispatch must use `main`; tag pushes do
not start the new workflow. Older workflow revisions still exist in Git history,
so tag protection remains part of the release boundary.

Parser validation checks the exact pinned tag and every tracked lockfile revision.
It does not require that tag to equal the parser's current main branch. Use
`scripts/bump-parser.sh --dry-run` to check for newer parser work.

Mac binary archives include project and linked dependency licenses and notices
under `Licenses`. Homebrew retains them under the formula's shared data directory.

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
