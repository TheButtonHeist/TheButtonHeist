import Foundation

import TheScore

/// Address families the TCP listener should bind.
///
/// `dualStack` starts one IPv4 listener and one IPv6 listener on the same port,
/// so clients can connect through either `127.0.0.1` or `::1` for loopback
/// sessions.
public enum ListenerAddressFamily: String, Sendable, CaseIterable, Codable {
    case ipv4
    case ipv6
    case dualStack
}

/// Typed exposure policy for the server listener and discovery surface.
///
/// `ConnectionScope` decides who may connect. `ServerExposure` decides which
/// surfaces are allowed to become visible before a connection reaches scope
/// classification.
struct ServerExposure: Equatable, Sendable {
    let allowedScopes: Set<ConnectionScope>
    let addressFamily: ListenerAddressFamily

    init(
        allowedScopes: Set<ConnectionScope>,
        addressFamily: ListenerAddressFamily = .dualStack
    ) {
        self.allowedScopes = allowedScopes
        self.addressFamily = addressFamily
    }

    var publishesBonjour: Bool {
        allowedScopes.contains(.network)
    }

    var bindsToLoopbackOnly: Bool {
        allowedScopes == [.simulator]
    }
}
