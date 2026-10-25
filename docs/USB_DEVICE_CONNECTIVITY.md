# USB Device Connectivity

Connecting to iOS devices over USB via CoreDevice IPv6 tunnels, bypassing WiFi/mDNS discovery.

## Overview

When WiFi is unreliable, Button Heist can connect to physical devices over the
CoreDevice IPv6 tunnel. The default `simulator,usb` scope allows recognized
developer-tunnel traffic. Direct LAN traffic requires `network` scope.

USB uses the same TLS wire protocol as other transports. The difference is how the endpoint is found: direct/named target configuration for USB, Bonjour only when `network` scope is explicitly enabled.

## How It Works

### The CoreDevice IPv6 Tunnel

When an iOS device is connected via USB and recognized by Xcode/CoreDevice:

1. **CoreDevice creates a tunnel** on a `utun` interface (typically `utun5`)
2. **IPv6 addresses are assigned**:
   - Mac: `fd9a:6190:eed7::2` (or similar ULA prefix)
   - Device: `fd9a:6190:eed7::1`
3. **TCP connections can be made** directly to the device's IPv6 address

### Endpoint Configuration

Button Heist does not auto-discover CoreDevice tunnels. Use a fixed
`INSIDEJOB_PORT` / `InsideJobPort` and find the device tunnel address. Pass the
resulting `[IPv6]:port` endpoint through `--device`, `BUTTONHEIST_DEVICE`, or a
named target. All three use the same direct-target connection path.

### Requirements

1. **Device must be "connected"** in devicectl (USB cable attached, trusted)
2. **TheInsideJob must use IPv6 dual-stack** (enabled by default)
3. **App must be running** on the device with TheInsideJob started
4. **A fixed InsideJob port and explicit endpoint or named target** for the tunnel
5. **Xcode command line tools** installed (`xcrun` must be available)

## Usage

### CLI

Connect to the tunnel endpoint directly:

```bash
buttonheist connect --device '[fd9a:6190:eed7::1]:7331' --token my-token
```

Use the current tunnel address and the port and token configured in the app.
To reuse this endpoint, store it as a named target:

```bash
# List configured targets and connect to the default target
buttonheist list_targets
buttonheist connect

# Commands reuse the configured target
buttonheist perform 'Activate(.identifier("myButton"))'

# Take a screenshot over USB; writes an artifact by default
buttonheist get_screen --output screen.png
```

### MCP Server

Configure the fixed tunnel endpoint in `.buttonheist.json`:

```json
{
  "targets": {
    "usb": {
      "device": "[fd9a:6190:eed7::1]:7331",
      "token": "my-token"
    }
  },
  "default": "usb"
}
```

The MCP server resolves that same default target, so `.mcp.json` only needs
the server command:

```json
{
  "mcpServers": {
    "buttonheist": {
      "command": "./ButtonHeistMCP/.build/release/buttonheist-mcp"
    }
  }
}
```

## Building and Deploying to Device

### Command Line Build

```bash
xcodebuild -workspace ButtonHeist.xcworkspace \
  -scheme BH Demo \
  -destination 'platform=iOS,name=Your Device Name' \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  build
```

### Install to Device

```bash
xcrun devicectl device install app \
  --device "Your Device Name" \
  ~/Library/Developer/Xcode/DerivedData/ButtonHeist-*/Build/Products/Debug-iphoneos/BHDemo.app

xcrun devicectl device process launch \
  --device "Your Device Name" \
  --terminate-existing --activate \
  com.buttonheist.testapp
```

## Discovering the Tunnel Manually

### Check Device Status

```bash
xcrun devicectl list devices
```

Look for `connected` status:
```
Test Phone 15 Pro     Test-Phone-15-Pro.coredevice.local    ...   connected   iPhone 15 Pro
```

### Find the IPv6 Tunnel Address

```bash
xcrun devicectl device info details --device "Your Device Name"
```

Read the tunnel IP address from the connection details. Confirm that the
transport is wired. The address can change when CoreDevice reconnects; refresh
it after launching the app.

### Manual Connection (for debugging)

The protocol requires TLS before any JSON messages and token authentication
before commands. Plain `nc` is not a valid production client. For manual
debugging, put the tunnel endpoint and token in a named target, then run
`buttonheist connect`.

## Message Protocol

USB connections use the same TLS wire protocol as other transports. See the [Wire Protocol Specification](WIRE-PROTOCOL.md) for message format, authentication flow, and command reference.

## Implementation Details

### Configurable Address-Family Server

The production `ServerTransport` uses Network framework (`NWListener`) with
TLS parameters. Plain TCP startup exists only through explicitly named test
helpers.

```swift
let parameters = ButtonHeistTLSPreSharedKey.makeNetworkParameters(token: token)
let hosts: [NWEndpoint.Host] = [
    bindToLoopback ? .ipv4(.loopback) : .ipv4(.any),
    bindToLoopback ? .ipv6(.loopback) : .ipv6(.any),
]
var requestedPort = port
var listeners: [NWListener] = []
for host in hosts {
    let listenerParameters = parameters.copy()
    listenerParameters.requiredLocalEndpoint = .hostPort(
        host: host,
        port: NWEndpoint.Port(rawValue: requestedPort) ?? .any
    )
    let listener = try NWListener(using: listenerParameters)
    let actualPort = try await startAndWaitForReady(listener)
    requestedPort = requestedPort == 0 ? actualPort : requestedPort
    listeners.append(listener)
}
```

Simulator-only scope binds to loopback (`127.0.0.1` and `::1` by default).
USB or network scopes bind to all interfaces for the configured address family
so CoreDevice USB can reach the listener. The bind address is controlled by
`ServerExposure`, and connection scope classification still rejects disallowed
sources before authentication.

This allows:
- Simulator connections via `127.0.0.1` (loopback)
- USB device connections via the CoreDevice IPv6 tunnel
- WiFi connections via local network IPv4/IPv6 only when `INSIDEJOB_SCOPE` includes `network`

### Why WiFi Might Fail

Common issues that USB bypasses:
- **VPN routing**: VPN may route local traffic through tunnel
- **mDNS blocking**: Bonjour discovery blocked or filtered
- **Network segmentation**: Device on different subnet
- **Firewall rules**: Port blocked on WiFi interface

## Troubleshooting

### "Connection refused"
- App not running or TheInsideJob not started
- Wrong port (verify Info.plist has correct port)
- Device went to sleep/background

### "No route to host"
- Device not connected or not trusted
- CoreDevice tunnel not established
- Check `xcrun devicectl list devices` for "connected" status

### "Network is unreachable"
- Wrong IPv6 prefix (check `lsof -i -P -n | grep CoreDev`)
- Tunnel interface not up (reconnect USB cable)

### USB target does not connect
- Verify device shows as "connected" in `xcrun devicectl list devices`
- Ensure app is running on the device
- Verify the named target contains the current CoreDevice IPv6 address and fixed InsideJob port
- Remember that default `simulator,usb` scope does not publish Bonjour; USB targets do not appear in `buttonheist list_devices`

## Connection Scopes

By default, TheInsideJob only accepts loopback and recognized developer-tunnel
connections. Direct LAN connections require `network` in `INSIDEJOB_SCOPE`:

```bash
# Default: simulator and USB only
INSIDEJOB_SCOPE=simulator,usb

# Also allow WiFi/LAN connections
INSIDEJOB_SCOPE=simulator,usb,network

# Developer tunnel only (reject simulator and direct LAN)
INSIDEJOB_SCOPE=usb
```

The scope filter classifies connections once they reach the `.ready` state,
using the connection's remote host, local host, and interface evidence:

- **simulator**: Loopback address or loopback interface.
- **usb**: An `anpi` interface, or a `utun` interface with matching CoreDevice
  endpoints: device `::1` and Mac `::2` in the same private `fd00::/8` `/64`.
- **network**: All other paths, including tunnel interfaces without matching
  endpoint evidence.

The `utun` rule matches the path observed on an iPhone 15 Pro running iOS
26.2.1 and the [CoreDevice tunnel address convention](https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md).
It is a platform heuristic, not authentication or proof of a physical USB
cable. CoreDevice can also carry a developer tunnel over paired Wi-Fi.
Every connection still requires the configured TLS pre-shared token.

Connections from disallowed scopes are rejected at the `.ready` state, before authentication.

## See Also

- [Wire Protocol](WIRE-PROTOCOL.md) — Message format (identical over WiFi and USB)
- [Project Overview](../README.md) — Architecture and quick start
- [CLI Reference](../ButtonHeistCLI/) — All commands work over USB
