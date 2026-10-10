# Multi-Agent Isolation

How many agents drive many apps on one machine without stepping on each other: one simulator, one port, and one human-readable token per agent, with the same slug used as simulator name, auth token, and instance identifier. This diagram answers "whose session did I just hit, and how does an agent find its own?"

**Illustrates:** [AUTH.md](../AUTH.md)
**Source of truth:** `ButtonHeist/Sources/TheInsideJob/InsideJobRuntimeConfiguration.swift`, `ButtonHeist/Sources/TheScore/Wire/Messages.swift`, `ButtonHeist/Sources/TheScore/Wire/ServerIdentityPayloads.swift`, `ButtonHeist/Sources/TheInsideJob/Server/NetworkBoundary/BonjourAdvertisement.swift`

```mermaid
flowchart TD
    subgraph agentA["Agent A"]
        CLIA["client env:<br/>BUTTONHEIST_DEVICE = 127.0.0.1:23001<br/>BUTTONHEIST_TOKEN = accra-scroll-detection"]
        SIMA["simulator 'accra-scroll-detection'<br/>app launched with:<br/>INSIDEJOB_PORT = 23001<br/>INSIDEJOB_TOKEN = accra-scroll-detection<br/>INSIDEJOB_ID = accra-scroll-detection"]
        CLIA -- "TLS-PSK from its own token" --> SIMA
    end

    subgraph agentB["Agent B"]
        CLIB["client env:<br/>BUTTONHEIST_DEVICE = 127.0.0.1:27114<br/>BUTTONHEIST_TOKEN = lagos-settle-timing"]
        SIMB["simulator 'lagos-settle-timing'<br/>INSIDEJOB_PORT = 27114<br/>INSIDEJOB_TOKEN = lagos-settle-timing<br/>INSIDEJOB_ID = lagos-settle-timing"]
        CLIB -- "TLS-PSK from its own token" --> SIMB
    end

    CLIA -. "wrong port or token:<br/>TLS-PSK fails or authFailure —<br/>check the TXT record instanceid<br/>to see whose session it is" .-> SIMB
```

Server-side identity resolution (`InsideJobRuntimeConfiguration`):

```mermaid
flowchart LR
    TOKEN["token"] --> T1["INSIDEJOB_TOKEN env"] -- "unset" --> T2["API-provided"] -- "unset" --> T3["generated UUID v4<br/>logged at startup"]
    PORT["port"] --> P1["INSIDEJOB_PORT env"] -- "unset" --> P2["API-provided"] -- "unset" --> P3["0 — OS-assigned"]
    ID["instance id"] --> I1["INSIDEJOB_ID env"] -- "unset" --> I2["API-provided"] -- "unset" --> I3["first 8 chars of session UUID"]
```

Notes:

- The convention is `{workspace}-{task-slug}` for all three values: simulator name = token = instance ID. The token is not just auth — it is a label. `xcrun simctl list devices booted` becomes a dashboard of what every agent is doing, and a session's identity is legible everywhere it appears.
- The server advertises its identity in the Bonjour TXT record (`TXTRecordKey`: `instanceid`, `simudid`, `devicename`, `installationid`, `transport = tls-psk`). Those identity fields enter core logic as `InsideJobInstanceID`, `SimulatorUDID`, and `InstallationID`, so an agent can tell sessions apart **before** connecting.
- After successful auth, `ServerInfo` carries typed `ServerLaunchID` and `InsideJobInstanceID` values as `instanceId` and `instanceIdentifier`, plus `listeningPort`.
- A failed auth returns only "Invalid token. Retry with the configured token." — the server never discloses its token. An auth failure against the loopback usually means the wrong simulator's port, not the wrong token: find your own session by its `instanceid` instead of changing tokens.
- Never use UUIDs or opaque strings as tokens for agent work — a human-readable slug is what makes a connection error diagnosable.
