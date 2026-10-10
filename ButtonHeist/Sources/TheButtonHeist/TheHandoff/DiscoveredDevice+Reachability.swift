import Foundation
import ButtonHeistSupport

import TheScore

extension Array where Element == DiscoveredDevice {
    /// Probe all devices in parallel and return only those that are reachable.
    /// Uses a passive transport/TLS-ready probe as a lightweight liveness check.
    /// Reachability never enters the post-handshake session lifecycle or asks
    /// the server for pre-auth identity.
    func reachable(token: SessionAuthToken? = nil, timeout: TimeInterval = 1.5) async -> [DiscoveredDevice] {
        await withTaskGroup(of: (Int, DiscoveredDevice?).self) { group in
            for (index, device) in self.enumerated() {
                group.addTask {
                    let reachable = await device.reachability(token: token, timeout: timeout).isReachable
                    return reachable ? (index, device) : (index, nil)
                }
            }
            var indexed: [(Int, DiscoveredDevice)] = []
            for await (index, device) in group {
                if let device { indexed.append((index, device)) }
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

@ButtonHeistActor
var makeReachabilityConnection: ((DiscoveredDevice) -> any TransportReachabilityConnecting)?

enum DeviceReachability: Equatable {
    case reachable
    case unavailable
    case failed(DisconnectReason)

    var isReachable: Bool {
        if case .reachable = self {
            return true
        }
        return false
    }
}

extension DiscoveredDevice {
    @ButtonHeistActor
    func isReachable(token: SessionAuthToken? = nil, timeout: TimeInterval = 1.5) async -> Bool {
        await reachability(token: token, timeout: timeout).isReachable
    }

    @ButtonHeistActor
    func reachability(token: SessionAuthToken? = nil, timeout: TimeInterval = 1.5) async -> DeviceReachability {
        let connection = makeReachabilityConnection?(self) ?? DeviceConnection(device: self, token: token)
        let result = TimedOneShot<DeviceReachability>()

        // Wire the connection callbacks to resolve the probe:
        // raw socket readiness resolves reachable; `.disconnected` records
        // contract failures that should not be flattened into transport misses.
        // The resolver is one-shot so a subsequent `.disconnected` after a
        // successful socket-ready signal is a no-op.
        connection.onTransportReady = {
            result.resolve(returning: .reachable)
        }
        connection.onEvent = { event in
            switch event {
            case .connected:
                break
            case .message:
                break
            case .sendFailed:
                break
            case .disconnected(let reason):
                result.resolve(returning: Self.reachabilityDisconnectResult(reason))
            }
        }

        return await result.wait(
            cancellationValue: .unavailable,
            onRegistered: { result in
                result.armTimeout(after: .seconds(timeout)) {
                    result.resolve(returning: .unavailable)
                }
                connection.connect()
            },
            onFinished: {
                connection.disconnect()
            }
        )
    }

    private static func reachabilityDisconnectResult(_ reason: DisconnectReason) -> DeviceReachability {
        switch reason.phase {
        case .tls:
            return .failed(reason)
        case .discovery, .setup, .transport, .authentication, .session,
             .request, .protocolNegotiation, .client, .server:
            return .unavailable
        }
    }
}
