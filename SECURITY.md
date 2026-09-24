# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in The Button Heist, please report it through [GitHub Security Advisories](https://github.com/TheButtonHeist/TheButtonHeist/security/advisories/new). This allows us to assess the issue in private before any public disclosure.

**Do not open a public GitHub issue for security vulnerabilities.**

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

## Response Timeline

- **Acknowledge**: Within 48 hours of report submission
- **Triage and timeline**: Within 7 business days
- **Fix or mitigation**: Depends on severity; critical issues are prioritized for the next patch release

## Scope

### In Scope

| Component | Description |
|-----------|-------------|
| TheInsideJob | iOS server framework (auth, TLS, touch injection, accessibility parsing) |
| ButtonHeist | macOS client framework (connection, command dispatch) |
| buttonheist CLI | Command-line interface |
| ButtonHeistMCP | MCP server for AI agent tool use |
| TheScore | Wire protocol types and message definitions |

Specific areas of interest:

- Authentication bypass in token-based auth
- Unauthorized access to session-locked devices
- Buffer overflow or memory corruption in wire protocol handling
- Remote code execution via crafted messages
- TLS implementation weaknesses

### Out of Scope

The Button Heist intentionally uses private iOS APIs for synthetic touch injection and accessibility inspection. The following are **by design** and not considered vulnerabilities:

- Use of private UIKit/IOKit APIs (`UIApplication.sendEvent`, IOHIDEvent creation, UIKeyboardImpl)
- ObjC runtime method swizzling and `+load` hooks
- Access to the accessibility hierarchy
- Local network TCP communication (this is the core transport mechanism)
- Token values visible in process environment variables (standard configuration method)

**Release builds**: TheInsideJob is compiled only in `#if DEBUG` builds. Release builds contain no server code, no network listeners, no private API usage, and no attack surface. Vulnerabilities that require a release build are out of scope.

**Denial of service on localhost**: The server is a development tool. Local DoS is not a meaningful threat.

**Token brute-force**: The auth token is a coordination primitive for agent isolation, not a security credential. The server enforces rate limiting (5 failures / 30s lockout) but does not claim to resist a determined local attacker.

## Supported Versions

Only the latest release is supported with security updates.

## Safe Harbor

We consider security research conducted in good faith to be authorized. We will not pursue legal action against researchers who:

- Make a good-faith effort to avoid privacy violations, data destruction, and service disruption
- Report vulnerabilities through the process described above
- Allow reasonable time for a fix before public disclosure

## Disclosure

We follow coordinated disclosure. After a fix is released, we will credit the reporter (unless they prefer anonymity) in the release notes.
