import Foundation
import ButtonHeistSupport

/// Requested device target for resolution.
///
/// This is the one value `DeviceResolver` answers. It may be automatic
/// selection, an advertised-device query, or a direct loopback endpoint.
struct DeviceResolutionTarget: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case automatic
        case query(DiscoveryResolutionQuery)
        case direct(DiscoveredDevice)
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    init(filter: String?) {
        guard let filter else {
            self.kind = .automatic
            return
        }

        guard let query = DiscoveryResolutionQuery(filter) else {
            self.kind = .automatic
            return
        }

        if let directDevice = DiscoveredDevice.directConnectTarget(from: query.rawValue) {
            self.kind = .direct(directDevice)
            return
        }

        self.kind = .query(query)
    }

    init(config target: TargetConfig, named name: TargetName) {
        if let device = DiscoveredDevice.fromHostPort(
            target.device,
            id: DiscoveryDeviceID(stringLiteral: "config-\(name.rawValue)"),
            name: name.rawValue
        ) {
            self.init(kind: .direct(device))
        } else {
            self.init(filter: target.device)
        }
    }

    var isAutomatic: Bool {
        if case .automatic = kind { return true }
        return false
    }

    var requiresDiscovery: Bool {
        if case .direct = kind { return false }
        return true
    }

    var diagnosticName: String {
        switch kind {
        case .automatic:
            return "(none)"
        case .query(let query):
            return query.rawValue
        case .direct(let device):
            return device.name
        }
    }
}

/// Resolves the requested target to exactly one discovered device.
///
/// Resolution answers only "which discovered device should we connect to?"
/// It does not open sockets, probe reachability, send messages, or apply
/// authentication/session policy.
@ButtonHeistActor
struct DeviceResolver {
    let target: DeviceResolutionTarget
    let discoveryTimeout: UInt64
    let getDiscoveredDevices: () -> [DiscoveredDevice]

    init(
        target: DeviceResolutionTarget,
        discoveryTimeout: UInt64,
        getDiscoveredDevices: @escaping () -> [DiscoveredDevice]
    ) {
        self.target = target
        self.discoveryTimeout = discoveryTimeout
        self.getDiscoveredDevices = getDiscoveredDevices
    }

    func resolve() async throws -> DiscoveredDevice {
        if case .direct(let directDevice) = target.kind {
            return directDevice
        }

        let start = DispatchTime.now().uptimeNanoseconds

        while true {
            let discovered = getDiscoveredDevices()
            if !discovered.isEmpty {
                switch Self.selection(from: discovered, target: target) {
                case .selected(let device):
                    return device
                case .ambiguous(let matches):
                    throw HandoffConnectionError.ambiguousDeviceTarget(
                        filter: target.diagnosticName,
                        matches: matches.map(\.resolutionDiagnosticLabel)
                    )
                case .missing:
                    break
                }
            }

            let now = DispatchTime.now().uptimeNanoseconds
            if now - start > discoveryTimeout {
                return try finalSelection()
            }

            guard await Task.cancellableSleep(nanoseconds: 100_000_000) else {
                throw CancellationError()
            }
        }
    }

    private func finalSelection() throws(HandoffConnectionError) -> DiscoveredDevice {
        let discovered = getDiscoveredDevices()
        guard !discovered.isEmpty else {
            throw .noDeviceFound
        }

        switch Self.selection(from: discovered, target: target) {
        case .selected(let device):
            return device
        case .ambiguous(let matches):
            throw .ambiguousDeviceTarget(
                filter: target.diagnosticName,
                matches: matches.map(\.resolutionDiagnosticLabel)
            )
        case .missing:
            throw .noMatchingDevice(
                filter: target.diagnosticName,
                available: discovered.map(\.resolutionDiagnosticLabel)
            )
        }
    }

    private enum Selection {
        case selected(DiscoveredDevice)
        case missing
        case ambiguous([DiscoveredDevice])
    }

    private static func selection(
        from devices: [DiscoveredDevice],
        target: DeviceResolutionTarget
    ) -> Selection {
        switch target.kind {
        case .direct(let device):
            return .selected(device)
        case .automatic:
            switch devices.count {
            case 0:
                return .missing
            case 1:
                return .selected(devices[0])
            default:
                return .ambiguous(devices)
            }
        case .query(let query):
            let matches = devices.filter { $0.matches(resolutionQuery: query) }
            switch matches.count {
            case 0:
                return .missing
            case 1:
                return .selected(matches[0])
            default:
                return .ambiguous(matches)
            }
        }
    }
}
