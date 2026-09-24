<img width="1536" height="1024" alt="Noir-style heist planning board with an iPhone at center labeled The Vault, connected by red string to crew member dossiers: The Inside Job, The Safecracker, The Mastermind, The Fence, and The Bagman. A whiskey glass and desk lamp sit in the foreground." src="https://github.com/user-attachments/assets/ab62f18f-a3bd-480e-906d-3167b90c1d77" />

[![CI](https://github.com/TheButtonHeist/TheButtonHeist/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/TheButtonHeist/TheButtonHeist/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/TheButtonHeist/TheButtonHeist?label=release)](https://github.com/TheButtonHeist/TheButtonHeist/releases/latest)
[![License](https://img.shields.io/github/license/TheButtonHeist/TheButtonHeist)](LICENSE)

# The Button Heist

The Button Heist makes the iOS accessibility interface programmable.

Agents, humans, and tests act through the same contract VoiceOver depends on.

Every action is targeted and precise. The heist goes off clean, always returning with the evidence.

## One move

Begin with a single action:

```swift
Activate(.label("Pay"))
    .expect(.elementsChanged([.appeared(.label("Payment Complete"))]))
```

This is not "tap Pay." It is a contract:

- find the control the app declares as `Pay`
- perform the activation exposed by accessibility
- wait for the interface to settle
- prove that `Payment Complete` appeared
- return the receipt

The important question is not whether an event was delivered. It is whether the interface contract was fulfilled.

## Why this holds up

Contracts reduce ambiguity. The Button Heist asks the app what it declares now,
acts through that declaration, waits for the interface to settle, and returns
the evidence.

That changes the unit of automation:

- reusable product capabilities, not long transcripts of taps
- product semantics, not screen coordinates
- settled evidence, not sleeps
- the same heist language for agents and tests
- receipts you can assert, print, report, and compose

## From exploration to heist

A heist can begin as live exploration. The agent tries one item, reads the
receipts, and uses that evidence to make the next run stricter.

First, add `Milk` without writing the final contract up front:

```swift
TypeText("Milk", into: .label("Search Items"))
```

```text
type_text: elements changed (12 elements)
  ~ Search Items: value "" → "Milk"
  + "Milk":"$2.99" button

// ...
```

The receipt says what changed and what appeared. The agent can act on that
evidence instead of maintaining its own model of the transition:

```swift
Activate(.label("Milk"))
```

```text
activate: elements changed (14 elements)
  + "Milk":"$2.99" button id="cart.item"
  + "subtotal":"$2.99, 1 item" staticText

// ...
```

Now add `Eggs`, turning the observations from `Milk` into expectations:

```swift
TypeText("Eggs", into: .label("Search Items"))
    .expect(.elementsChanged([.updated(.label("Search Items"), .value("Eggs"))]))

Activate(.label("Eggs"))
    .expect(.elementsChanged([.appeared(.element(
        .label(.prefix("Eggs")),
        .identifier(.contains("cart"))
    ))]))
```

That is expectation refinement: live observations become durable assertions.
Once the refined run passes, promote the workflow into product language:

```swift
HeistDef<String>("Cart.addItem", parameter: "item") { item in
    TypeText(item, into: .label("Search Items"))
        .expect(.elementsChanged([.updated(.label("Search Items"), .value(item))]))

    Activate(.label(item))
        .expect(.elementsChanged([.appeared(.element(
            .label(.prefix(item)),
            .identifier(.contains("cart"))
        ))]))
}
```

`Cart.addItem` is reusable product semantics, not a transcript of clicks. Put
it in a plan, try it with another item, then run that same plan from a test:

```swift
import ButtonHeistTesting
import Testing

func makeShopHeist() throws -> HeistPlan {
    try HeistPlan("shop") {
        HeistDef<String>("Cart.addItem", parameter: "item") { item in
            TypeText(item, into: .label("Search Items"))
                .expect(.elementsChanged([.updated(.label("Search Items"), .value(item))]))

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

        RunHeist("Cart.addItem", "Eggs")
            .expect(.elementsChanged([.updated(.label("subtotal"), .value(.contains("2 items")))]))

        RunHeist("Cart.addItem", "Bread")
            .expect(.elementsChanged([.updated(.label("subtotal"), .value(.contains("3 items")))]))
    }
}

@Suite(.serialized)
struct ShopHeistTests {
    @MainActor
    @Test
    func addsItemsToCart() async throws {
        try await runHeist(makeShopHeist())
    }
}
```

The reusable heist owns the local workflow. The test owns the aggregate product
outcome.

## Ways to run heists

Agents and tests use the same heist language. That is the practical payoff of
defining product capabilities against the accessibility contract.

- `perform(step:)` runs one Button Heist step from MCP.
- `run_heist(plan:)` runs a composed `HeistPlan` from MCP or the CLI.
- Checked-in Swift heist files compile to the same validated plan your tests can run.

A live agent can take one step:

```swift
Activate(.label("Pay"))
    .expect(.elementsChanged([.appeared(.label("Payment Complete"))]))
```

Send that source through `perform(step:)`.

A composed job can run as a plan:

```swift
HeistPlan("checkout") {
    Activate(.label("Pay"))
        .expect(.elementsChanged([.appeared(.label("Payment Complete"))]))
}
```

Send that source through `run_heist(plan:)`.

In tests, runHeist is the assertion. If the accessibility contract is not
fulfilled, the test fails with the evidence.

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

For app-hosted XCTest/KIF-style targets that are sensitive to XCTest async
teardown, keep the test method synchronous and let Button Heist pump the main
run loop:

```swift
import ButtonHeistTesting
import XCTest

final class CheckoutHeistTests: XCTestCase {
    func testCheckoutCompletes() {
        runHeistSync("Checkout.pay") {
            Activate(.label("Pay"))
                .expect(.elementsChanged([.appeared(.label("Payment Complete"))]))
        }
    }
}
```

```swift
import ButtonHeistTesting
import Testing

@Suite(.serialized)
struct CheckoutHeistTests {
    @MainActor
    @Test
    func checkoutCompletes() async throws {
        try await runHeist("Checkout.pay") {
            Activate(.label("Pay"))
                .expect(.elementsChanged([.appeared(.label("Payment Complete"))]))
        }
    }
}
```

`RunHeist(...)` composes inside plans. `runHeist(...)` executes from Swift
tests. `run_heist` crosses the CLI/MCP tool boundary.

If a test already has a `HeistPlan`, run it through the same testing facade with
`try await runHeist(plan)` instead of constructing `Heist` directly.

`runHeistSync(..., recordResult: .always, to: resultsURL) { ... }` records
passing and failing XCTest results without relying on inherited environment
variables. If no URL is supplied, results are written under the process
temporary directory at `buttonheist-results/`.

To stop at a screen, open a ButtonHeist session, and let a human or agent
connect through MCP or the CLI, halt a synchronous XCTest after ordinary app
navigation:

```swift
func test_PARACHUTE_driveCheckout() {
    logIn()
    navigateToCheckout()
    joinHeist(token: "probe", port: 1456)
}
```

`joinHeist` defaults to simulator loopback only with a dual-stack listener, so
the printed `127.0.0.1:<port>` endpoint is reachable from the host. Pass
`addressFamily: .ipv6` or `addressFamily: .ipv4` to force one family, pass
`allowedScopes: ConnectionScope.default` to accept simulator and USB clients,
or `allowedScopes: ConnectionScope.all` when LAN clients are intentional.

The helper starts a fresh InsideJob server, prints a ready line after the
listener reports its bound port, then halts test progression while pumping the
run loop so the client can interact with the live app. If the printed endpoint
is unreachable from the host, the launch system may require external port
forwarding; the app process can report the bound simulator-side port but cannot
create that host bridge itself.

For tests that should keep running while a client connects, scope the same live
session around the code that needs it:

```swift
func testCheckoutWithExternalProbe() throws {
    logIn()
    navigateToCheckout()
    withJoinedHeistSession(token: "probe") { session in
        print(session.readyMessage)
        runExternalProbe(port: session.listeningPort, token: session.token)
    }
}
```

`withJoinedHeistSession` accepts the same `port`, `addressFamily`, and
`allowedScopes` parameters as `joinHeist`, then stops the fresh InsideJob
server when the closure exits.

The same product capability can live in source control:

```swift
func makeCheckoutHeist() throws -> HeistPlan {
    try HeistPlan("checkout") {
        Activate(.label("Pay"))
            .expect(.elementsChanged([.appeared(.label("Payment Complete"))]))
    }
}
```

```bash
buttonheist run_heist --path Heists/Checkout.swift --entry makeCheckoutHeist
```

Different doors. Same runtime. Same evidence.

## Receipts

A receipt is the durable answer to "what happened?" Not a hunch. Not a tap log. The facts.

```text
step: Activate(label: "Pay")
status: passed
before: Checkout
after: Payment
delta: screen changed
evidence:
  appeared: "Payment" [header]
  appeared: "Total $41.00" [staticText]
```

When a step cannot satisfy the contract, the evidence matters more:

```text
activate -> error[elementNotFound]
No match for: label="Calamari Fritti"
near miss:
  "Calamari Fritti, $14.00, Calamari Fritti" [button]
known elements:
  "Start drawer" [header]
  "Save" [button]
```

Boring in the useful way: receipts say what ran, what changed, and where the machine stopped. They are not live handles, replay objects, or private runtime state. They are evidence you can assert against, print, report, and compose.

## Quick start

### 1. Add `TheInsideJob`

Link `TheInsideJob` to your debug target. It starts a local TCP server via ObjC
`+load`; no app setup code is required. Release builds contain no server: all of
`TheInsideJob` is compiled under `#if DEBUG`, so the code is absent from release
binaries, not merely disabled at runtime.

By default the server accepts simulator loopback and USB-scoped connections. It does not publish Bonjour on the LAN unless you opt into network scope with `INSIDEJOB_SCOPE=simulator,usb,network` or `InsideJobScope`. Interaction fingerprints are enabled by default; disable them with `INSIDEJOB_FINGERPRINTS=false`, `InsideJobFingerprintsEnabled`, or `try TheInsideJob.configure(fingerprintsEnabled: false)`.

If you enable network scope, add the Bonjour permissions:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app uses local network to communicate with The Button Heist.</string>
<key>NSBonjourServices</key>
<array>
    <string>_buttonheist._tcp</string>
</array>
```

### 2. Install the tools

```bash
brew install TheButtonHeist/tap/buttonheist
```

The Homebrew distribution currently supports Apple Silicon macOS only.

Add the MCP server to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "buttonheist": {
      "command": "buttonheist-mcp",
      "args": []
    }
  }
}
```

### 3. Drive the app

Agents usually start with `get_interface`, then use `perform(step:)` for one
semantic step or `run_heist(plan:)` for a named capability.

The CLI exposes the same runtime as terminal commands:

```bash
buttonheist list_devices
buttonheist get_interface
buttonheist activate --label "Log In"
buttonheist type_text --text "Hello" --label "Name"
buttonheist get_screen --output screen.png
```

For long-running automation, `json_lines` keeps one connection open and accepts one command per line:

```bash
printf '%s\n' '{"command":"get_interface"}' | buttonheist json_lines
```

## Screenshots and gestures

Screenshots are visual evidence. They show the rendered interface, and The Button Heist can capture them when pixels are the right proof.

They are not the normal way to act. For buttons, fields, menus, actions, rotors, waits, and product flows, the durable control surface is the accessibility contract the app already owes its users.

Explicit mechanical gestures stay available for maps, canvases, drawing surfaces, games, and spatial products. Those are intentional spatial interactions, not setup steps for ordinary controls.

## Documentation

| Need | Read |
|---|---|
| Understand the contract loop | [Accessibility contract](docs/ACCESSIBILITY-CONTRACT.md), [Architecture](docs/ARCHITECTURE.md), [Diagrams](docs/diagrams/README.md) |
| Compare approaches, know the limits | [Why in-process](docs/WHY-IN-PROCESS.md), [Scope and limits](docs/SCOPE-AND-LIMITS.md) |
| Connect an agent | [MCP agent guide](docs/MCP-AGENT-GUIDE.md), [ButtonHeistMCP](ButtonHeistMCP/) |
| Use the terminal | [ButtonHeistCLI](ButtonHeistCLI/), `buttonheist --help`, `buttonheist <command> --help` |
| Author heists | [Swift heist authoring](docs/SWIFT-HEIST-AUTHORING.md), [Heist format](docs/HEIST-FORMAT.md), [Design rationale](docs/DESIGN-RATIONALE.md), [Examples](examples/README.md) |
| Run heists in CI | [CI integration](docs/CI.md) |
| Integrate an app | [API](docs/API.md), [Auth](docs/AUTH.md), [USB connectivity](docs/USB_DEVICE_CONNECTIVITY.md) |
| See evidence and experiments | [Heist Doctor](docs/HEIST-DOCTOR.md) |

Command names, help, and MCP schemas are projected from the Fence command descriptors at runtime.

## Troubleshooting

### Device not appearing

Check that:

1. `TheInsideJob` is linked to the debug target.
2. The app is running in the foreground.
3. The connection scope allows simulator, USB, network, or the direct target you are using.
4. Bonjour/LAN discovery, if enabled, has the `_buttonheist._tcp` Info.plist entry.

### USB connection refused

Run:

```bash
xcrun devicectl list devices
lsof -i -P -n | grep CoreDev
```

The app must be running on the device.

### Empty hierarchy

Make sure the app has an interface on a screen and that the root view exposes an accessibility hierarchy. Then run:

```bash
buttonheist get_interface
```

## Development

### Prerequisites

- Xcode with Swift 6 package support
- iOS 16+ / macOS 14+
- [Tuist](https://tuist.io)

### Build locally

```bash
git submodule update --init --recursive
./scripts/generate-project.sh
open ButtonHeist.xcworkspace
```

### Test locally

```bash
scripts/test-runner.py run MacFrameworkTests
scripts/test-runner.py run TheInsideJobLogicTests
scripts/test-runner.py run TheInsideJobWindowTests
scripts/test-runner.py run TheInsideJobIntegrationTests
scripts/test-runner.py run HostedBehaviorTests
```

### Project structure

```text
ButtonHeist/
+-- ButtonHeist/Sources/          # Core frameworks
+-- ButtonHeistCLI/               # CLI tool
+-- ButtonHeistMCP/               # MCP server
+-- TestApp/                      # SwiftUI + UIKit test apps
+-- submodules/AccessibilitySnapshotBH/
+-- docs/                         # Architecture, contracts, API, connectivity
+-- examples/                     # Canonical semantic examples
```

## Acknowledgments

- [AccessibilitySnapshot](https://github.com/cashapp/AccessibilitySnapshot), used through [AccessibilitySnapshotBH](https://github.com/RoyalPineapple/AccessibilitySnapshotBH), handles UIKit accessibility hierarchy parsing. Patient infrastructure. The kind you want under a machine that acts on what the app says.

## License

Apache License 2.0. See [LICENSE](LICENSE).
