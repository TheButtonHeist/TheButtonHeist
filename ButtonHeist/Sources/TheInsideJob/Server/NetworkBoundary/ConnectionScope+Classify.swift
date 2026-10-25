import Foundation
import Network

import TheScore

struct ConnectionPathEvidence {
    let host: NWEndpoint.Host
    let localHost: NWEndpoint.Host?
    let interfaceFacts: [InterfaceFact]
    let path: Path

    init(host: NWEndpoint.Host, localHost: NWEndpoint.Host? = nil, interfaceNames: [String] = []) {
        let interfaceFacts = interfaceNames.map(InterfaceFact.init(name:))
        self.host = host
        self.localHost = localHost
        self.interfaceFacts = interfaceFacts
        self.path = Self.path(for: host, localHost: localHost, interfaceFacts: interfaceFacts)
    }

    enum Path: Equatable {
        case simulator(SimulatorReason)
        case usb(USBReason)
        case network(NetworkReason)

        var scope: ConnectionScope {
            switch self {
            case .simulator:
                return .simulator
            case .usb:
                return .usb
            case .network:
                return .network
            }
        }
    }

    enum SimulatorReason: Equatable {
        case ipv4LoopbackAddress
        case ipv4LoopbackRange
        case ipv6LoopbackAddress
        case loopbackInterface(name: String)
    }

    enum USBReason: Equatable {
        case appleNetworkPrivateInterface(name: String)
        case coreDeviceTunnel(name: String)
    }

    enum NetworkReason: Equatable {
        case noLocalPathEvidence
    }

    struct InterfaceFact: Equatable {
        let name: String
        let heuristic: InterfaceHeuristic?

        init(name: String) {
            self.name = name
            self.heuristic = InterfaceHeuristic(name: name)
        }
    }

    enum InterfaceHeuristic: Equatable {
        case loopback
        case appleNetworkPrivateInterface
        case tunnel

        init?(name: String) {
            if name.hasPrefix("lo") {
                self = .loopback
            } else if name.hasPrefix("anpi") {
                self = .appleNetworkPrivateInterface
            } else if name.hasPrefix("utun") {
                self = .tunnel
            } else {
                return nil
            }
        }
    }

    private static func path(
        for host: NWEndpoint.Host,
        localHost: NWEndpoint.Host?,
        interfaceFacts: [InterfaceFact]
    ) -> Path {
        switch host {
        case .ipv4(let address):
            if address == .loopback {
                return .simulator(.ipv4LoopbackAddress)
            }
            if address.rawValue.first == 127 {
                return .simulator(.ipv4LoopbackRange)
            }
        case .ipv6(let address):
            if address == .loopback {
                return .simulator(.ipv6LoopbackAddress)
            }
        default:
            break
        }

        if let interface = interfaceFacts.first(where: { $0.heuristic == .loopback }) {
            return .simulator(.loopbackInterface(name: interface.name))
        }

        if let interface = interfaceFacts.first(where: { $0.heuristic == .appleNetworkPrivateInterface }) {
            return .usb(.appleNetworkPrivateInterface(name: interface.name))
        }

        if let interface = interfaceFacts.first(where: { $0.heuristic == .tunnel }),
           isCoreDevicePair(host: host, localHost: localHost) {
            return .usb(.coreDeviceTunnel(name: interface.name))
        }

        return .network(.noLocalPathEvidence)
    }

    // shortcut: CoreDevice fd00::/8 pairs use device ::1 and host ::2; revisit when tunnel addressing changes.
    private static func isCoreDevicePair(host: NWEndpoint.Host, localHost: NWEndpoint.Host?) -> Bool {
        guard case .ipv6(let remote) = host,
              case .ipv6(let local) = localHost else { return false }
        let localBytes = local.rawValue
        let remoteBytes = remote.rawValue
        return localBytes.first == 0xfd
            && localBytes.prefix(8) == remoteBytes.prefix(8)
            && localBytes.suffix(8).elementsEqual([0, 0, 0, 0, 0, 0, 0, 1])
            && remoteBytes.suffix(8).elementsEqual([0, 0, 0, 0, 0, 0, 0, 2])
    }
}

extension ConnectionScope {
    /// Classify a remote host into a connection scope using typed Network framework values.
    ///
    /// - Loopback address or loopback interface evidence → `.simulator`
    /// - Apple Network Private Interface evidence → `.usb` (CoreDevice tunnel)
    /// - Tunnel interface with the CoreDevice private IPv6 endpoint pair → `.usb`
    /// - Everything else → `.network`
    ///
    /// Capture the local host and interface names from `NWConnection.currentPath`
    /// after the connection reaches `.ready`.
    static func classify(
        host: NWEndpoint.Host,
        localHost: NWEndpoint.Host? = nil,
        interfaceNames: [String] = []
    ) -> ConnectionScope {
        let evidence = ConnectionPathEvidence(host: host, localHost: localHost, interfaceNames: interfaceNames)
        return classify(evidence)
    }

    static func classify(_ evidence: ConnectionPathEvidence) -> ConnectionScope {
        evidence.path.scope
    }
}
