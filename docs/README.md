# Documentation

The Button Heist docs start with the executable accessibility contract, then branch by job. Pick the path closest to what you are trying to do.

Platform scope: The Button Heist automates iOS apps. The CLI and MCP server are macOS clients. There is no Android or web support.

## Understand the idea

| Document | Use it for |
|----------|------------|
| [Project overview](../README.md) | Public story, setup, first heist, and results |
| [Accessibility contract](ACCESSIBILITY-CONTRACT.md) | The runtime loop: product semantics in, settled evidence out |
| [Why in-process](WHY-IN-PROCESS.md) | What running inside the app buys, and how the out-of-process drivers differ |
| [Scope and limits](SCOPE-AND-LIMITS.md) | What The Button Heist cannot see, what "settled" means, and how to triage findings |
| [Architecture](ARCHITECTURE.md) | Component boundaries, execution flow, trace semantics, and failure paths |
| [Diagrams](diagrams/README.md) | Architecture diagrams, one Mermaid file per concern, derived from source |

## Connect an agent

| Document | Use it for |
|----------|------------|
| [MCP agent guide](MCP-AGENT-GUIDE.md) | How agents should observe, act, wait, and compose heists |
| [MCP server README](../ButtonHeistMCP/) | Adapter behavior, runtime behavior, and environment variables |
| Live MCP schemas | Call MCP `tools/list`; tool names and input schemas are projected from TheFence descriptors |

## Use the terminal

| Document | Use it for |
|----------|------------|
| [CLI README](../ButtonHeistCLI/) | Terminal workflows, device targeting, output, and JSON-lines mode |
| CLI help | Run `buttonheist --help` or `buttonheist <command> --help`; command names and parameters are descriptor-owned |

## Author heists

| Document | Use it for |
|----------|------------|
| [Swift heist authoring](SWIFT-HEIST-AUTHORING.md) | Boundaries between Swift authoring, canonical source, and runtime execution |
| [Heist format](HEIST-FORMAT.md) | `.heist` package shape, generated JSON IR, and artifact rules |
| [Design rationale](DESIGN-RATIONALE.md) | Why the heist language is shaped the way it is, and the line it will not cross |
| [Examples](../examples/README.md) | Copyable semantic command and heist examples |

## Embed and operate

| Document | Use it for |
|----------|------------|
| [API](API.md) | Public API invariants, surface matrix, and integration contracts |
| [CI integration](CI.md) | Running heists in CI: simulator topology, port/token plumbing, XCTest embedding, JUnit output |
| [Authentication](AUTH.md) | Token-derived TLS PSK, token auth, session locking, and threat model |
| [USB connectivity](USB_DEVICE_CONNECTIVITY.md) | Physical-device connections over CoreDevice IPv6 tunnels without LAN scope |
| [Bonjour troubleshooting](BONJOUR_TROUBLESHOOTING.md) | mDNS, stealth mode, fixed-port workarounds, and LAN discovery issues |
| [Wire protocol](WIRE-PROTOCOL.md) | Raw transport, envelopes, handshake, authentication, and wire examples |
