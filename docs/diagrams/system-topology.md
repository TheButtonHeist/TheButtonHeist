# System Topology

Mac apps, agents, and test runners drive the iOS app through one client transport. The iOS runtime supports source linkage, prebuilt linkage, and launch-time injection.

**Illustrates:** [ARCHITECTURE.md](../ARCHITECTURE.md)
**Source of truth:** `ButtonHeist/Sources/TheScore/Wire/Messages.swift`, `ButtonHeist/Sources/TheScore/Core/TLSPreSharedKeyMaterial.swift`, `ButtonHeist/Sources/TheInsideJob/TheInsideJob.swift`, `ButtonHeist/Sources/TheInsideJob/Server/NetworkBoundary/SocketListenerStartup.swift`, `ButtonHeist/Sources/TheInsideJob/Server/NetworkBoundary/BonjourAdvertisement.swift`, `ButtonHeistCLI/Package.swift`, `ButtonHeistMCP/Package.swift`

```mermaid
flowchart TD
    subgraph host["Host: macOS"]
        AGENT["Agent or test runner"]
        MCP["buttonheist-mcp<br/>26 MCP tools"]
        CLI["buttonheist CLI"]
        MAC["Mac app"]
        SWIFT["ButtonHeist.withSession<br/>typed Swift operations"]
        FENCE["TheFence<br/>command admission<br/>connection policy and dispatch"]
        HANDOFF["TheHandoff<br/>discovery and connection"]
        AGENT --> MCP
        AGENT --> CLI
        MCP --> FENCE
        CLI --> FENCE
        MAC --> SWIFT
        SWIFT --> FENCE
        FENCE --> HANDOFF
    end

    subgraph app["iOS app process"]
        subgraph debug["Debug runtime"]
            LISTENER["NWListener<br/>Bonjour: _buttonheist._tcp"]
            MUSCLE["TheMuscle<br/>admission, auth, sessions"]
            CREW["Crew<br/>TheBrains · TheVault · TheSafecracker<br/>TheTripwire · TheGetaway"]
            LISTENER --> MUSCLE
            MUSCLE --> CREW
        end
        AX["UIKit accessibility tree<br/>labels · values · traits · actions"]
        CREW -- "reads via parser<br/>acts via accessibilityActivate()" --> AX
    end

    HANDOFF -- "TLS-PSK wire · token auth<br/>exact buttonHeistVersion handshake" --> LISTENER
```

Notes:

- The wire is TLS with a pre-shared key derived from the session token (`ButtonHeistTLSPreSharedKey.makeNetworkParameters(token:)`, HKDF-SHA256, cipher `TLS_PSK_WITH_AES_128_GCM_SHA256`). Token auth then happens again at the message layer (`authenticate`).
- The version handshake compares the client's and server's typed `ButtonHeistVersion` values for exact equality and rejects on any mismatch (`MuscleHandshakePhase`).
- Source Release builds exclude the runtime through `#if DEBUG`. App builds that use the prebuilt Debug runtime must exclude its framework from distribution.
- `ButtonHeist.withSession` scopes the existing Fence connection. Typed Swift calls and command adapters share plan execution, recording, and interface capture.
- CLI and MCP admit commands before Fence applies connection policy. Local commands do not enter TheHandoff. Both session adapters suspend idle expiry during active requests.
- Current-view capture refreshes live evidence without viewport exploration. Discovery remains an explicit query choice for Swift callers.
