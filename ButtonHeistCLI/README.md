# ButtonHeist CLI

The CLI is the terminal adapter for The Button Heist. It routes through
`TheFence.Command`, the same product command contract used by JSON-lines stdin,
MCP, and heist execution.

This README covers build, targeting, and common workflows. It does not maintain
a hand-written command or parameter catalog.

Reference surfaces:

- `buttonheist --help` and `buttonheist <command> --help` - canonical CLI usage
- MCP `tools/list` schemas from ButtonHeistMCP - MCP adapter tools
- [API](../docs/API.md) - product invariants and integration context

## Build

```bash
cd ButtonHeistCLI
swift build -c release
```

Binary:

```bash
.build/release/buttonheist
```

## Device targeting

All device-backed commands accept `--device <filter>`. The filter matches
discovered metadata such as service name, app name, device name, short ID,
installation ID, instance ID, simulator UDID, or a named target from config.

```bash
buttonheist --device a1b2 get_interface
buttonheist --device demo perform 'Activate(.identifier("loginButton"))'
```

Without `--device`, direct commands require exactly one reachable target.

## Command surface

Run local help for executable usage:

```bash
buttonheist --help
buttonheist <command> --help
```

The command contract is owned by `TheFence.Command` descriptors. If this README
and local command help disagree, the descriptor-backed help wins.

## Workflows

### Inspect and act

```bash
buttonheist get_interface
buttonheist get_interface --label "Checkout" --traits button
buttonheist perform 'Activate(.element(.label("Sign In"), .traits([.button])))'
buttonheist perform 'TypeText("user@example.com", into: .identifier("emailField"))'
```

Semantic statements identify elements in the canonical Button Heist language.
The Button Heist resolves the target, moves the viewport if needed, refreshes,
and uses fresh live geometry before acting.

### Viewport and screenshots

```bash
buttonheist action '{"type":"scroll","payload":{"direction":"down"}}'
buttonheist action '{"type":"scrollToVisible","payload":{"target":{"checks":[{"kind":"identifier","match":{"mode":"exact","value":"submitButton"}}]}}}'
buttonheist get_screen --output screen.png
```

The low-level `action` command accepts exactly one canonical
`HeistActionCommand` JSON object. Explicit viewport actions expose viewport
state because moving the viewport is their purpose; they are not setup for
ordinary semantic actions. Screenshots write artifact files by default; inline
PNG data is an explicit raw output mode.

### Replay authored heists

```bash
buttonheist run_heist --path checkout.heist --junit report.xml
```

Heist replay uses durable semantic selectors and matchers. Capture-local
annotations are evidence and diagnostics, not replay identity. Source is
authored; a `.heist` package is a generated replay artifact.

### JSON-lines mode

`buttonheist json_lines` keeps a single connection open and accepts canonical
JSON requests on stdin.

```bash
buttonheist json_lines
echo '{"command":"get_interface"}' | buttonheist json_lines
printf '%s\n' '{"command":"run_heist","plan":"HeistPlan(\"smoke\") { Activate(.label(\"Sign In\")).expect(.changed(.screen())) }"}' | buttonheist json_lines
```

JSON-lines mode auto-reconnects after connection loss, then the next command
refreshes state through the same Fence path.

## Environment

| Variable | Description |
|----------|-------------|
| `BUTTONHEIST_DEVICE` | Default device filter or named target |
| `BUTTONHEIST_TOKEN` | Auth token |
| `BUTTONHEIST_DRIVER_ID` | Driver identity for session locking |
| `BUTTONHEIST_SESSION_TIMEOUT` | Idle timeout for `buttonheist json_lines` |

Flags take precedence over environment variables.

## Output

Standalone commands default to human-readable text on a TTY and JSON when
piped. JSON-lines mode defaults to JSON. Use `--format human` or `--format json`
to choose explicitly.

Status messages go to stderr.

## See also

- [MCP Server](../ButtonHeistMCP/)
- `buttonheist --help`
- [Project Overview](../README.md)
