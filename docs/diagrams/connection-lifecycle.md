# Connection Lifecycle

The client connection as a state machine (`HandoffConnectionPhase`) plus the message-level handshake that runs inside the `connecting` phase: TLS-PSK, hello exchange, exact version equality, token auth, session claim. This diagram answers "what state is my connection in, and which step rejected me?"

**Illustrates:** [AUTH.md](../AUTH.md), [WIRE-PROTOCOL.md](../WIRE-PROTOCOL.md)
**Source of truth:** `ButtonHeist/Sources/TheButtonHeist/TheHandoff/DeviceResolver.swift`, `ButtonHeist/Sources/TheButtonHeist/TheHandoff/HandoffConnectionState.swift`, `ButtonHeist/Sources/TheButtonHeist/TheHandoff/HandoffConnectionLifecycle.swift`, `ButtonHeist/Sources/TheButtonHeist/TheHandoff/NetworkBoundary/DeviceConnectionFailures.swift`, `ButtonHeist/Sources/TheInsideJob/Server/MuscleHandshakePhase.swift`, `ButtonHeist/Sources/TheScore/Core/TLSPreSharedKeyMaterial.swift`, `ButtonHeist/Sources/TheScore/Wire/Messages.swift`

## Connection phases

```mermaid
stateDiagram-v2
    state "disconnected" as disc
    state "reconnecting(HandoffReconnectAttempt)" as recon
    state "connecting(HandoffConnectionAttempt)" as conn
    state "connected(HandoffConnectedSession)" as live
    state "failed(HandoffConnectionError)" as failed

    [*] --> disc
    disc --> conn : DeviceResolutionTarget resolves to endpoint
    disc --> recon : reconnect policy engages
    recon --> conn : attempt starts
    conn --> live : handshake + auth complete (ServerInfo received)
    conn --> failed : connectionFailed / timeout / noDeviceFound /<br/>noMatchingDevice / ambiguousDeviceTarget
    live --> disc : markDisconnected(reason) — keepalive cancelled
    live --> failed : disconnected(DisconnectReason)
    failed --> [*]
```

`DisconnectReason` carries the documented failure edges: `networkError`, `bufferOverflow`, `eventBacklogOverflow`, `serverClosed`, `authFailed`, `sessionLocked`, `protocolMismatch`, `localDisconnect`, `missingToken`.

`EnvironmentConfig` admits command, config-file, or environment syntax into one
`DeviceResolutionTarget`. `TheHandoff` resolves that target by exactly one
route—direct endpoint probing or discovery—and retains the same typed target
for reconnect. It does not retain a parallel filter or consult the environment
again after admission.

## Handshake inside `connecting`

```mermaid
sequenceDiagram
    participant Client as TheHandoff (client)
    participant Server as TheMuscle (server)

    Note over Client,Server: discovery — Bonjour _buttonheist._tcp<br/>or direct host:port (BUTTONHEIST_DEVICE)
    Note over Client,Server: TLS-PSK handshake — key derived from token<br/>(HKDF-SHA256, TLS_PSK_WITH_AES_128_GCM_SHA256)
    Server->>Client: serverHello
    Client->>Server: clientHello (buttonHeistVersion in envelope)
    alt version mismatch
        Server->>Client: protocolMismatch (both versions)
        Note over Client: DisconnectReason.protocolMismatch
    else exact buttonHeistVersion equality
        Server->>Client: authRequired
        Client->>Server: authenticate (token, driverId)
        alt token invalid
            Server->>Client: error kind authFailure —<br/>"Invalid token. Retry with the configured token."
        else another driver holds the session
            Server->>Client: sessionLocked (message, activeConnections)
        else accepted
            Server->>Client: info (ServerInfo: instanceId,<br/>instanceIdentifier, listeningPort)
            Note over Client,Server: connected — commands allowed
        end
    end
```

Notes:

- The version gate compares typed `ButtonHeistVersion` values with exact equality in `MuscleHandshakePhase` before token auth. There is no separate wire-protocol version.
- TLS security and message-level auth both derive from the same `SessionAuthToken`: the TLS layer uses a pre-shared key derived from it, then the `authenticate` message proves it again in JSON. Session ownership is a typed `SessionOwner` carrying either that token or a `DriverID`.
- The auth-failure message does not disclose the server's token or identity; the server's `instanceIdentifier` travels in the Bonjour TXT record and in `ServerInfo` after successful auth (see [multi-agent-isolation.md](multi-agent-isolation.md)).
