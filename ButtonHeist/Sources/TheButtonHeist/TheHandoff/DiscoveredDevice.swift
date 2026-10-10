import Foundation

import ThePlans
import TheScore

public struct DiscoveryDeviceID: NonBlankStringValue, CustomDebugStringConvertible {
    private let value: String
    public init(validating value: String) throws { self.value = try validateNonBlank(value) }
    public var description: String { value }
    public var debugDescription: String { value }

    static func hostPort(host: String, port: UInt16) -> DiscoveryDeviceID {
        DiscoveryDeviceID(stringLiteral: "\(host):\(port)")
    }
}

enum DiscoveryIdentity: Hashable, Sendable {
    case installation(appName: String, id: InstallationID)
    case device(DiscoveryDeviceID)
}

private struct DiscoveryHostPortTarget: Equatable, Sendable {
    let host: String
    let port: UInt16

    var displayValue: String {
        "\(host):\(port)"
    }
}

public enum DiscoveredDeviceEndpoint: Hashable, Sendable {
    case hostPort(host: String, port: UInt16)
    case service(name: String, type: String, domain: String)
}

struct DiscoveryResolutionQuery: Equatable, Sendable, CustomStringConvertible {
    let rawValue: String
    let normalizedValue: String

    init?(_ value: String?) {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        rawValue = trimmed
        normalizedValue = trimmed.lowercased()
    }

    var description: String { rawValue }
}

/// A discovered iOS device running TheInsideJob.
///
/// `id` is the public endpoint identifier: a Bonjour service name or a
/// direct/named target identifier. `name` is
/// the advertised service label. Human-facing display text is derived separately
/// by `displayName(among:)` so target resolution does not depend on formatting.
public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    /// Stable discovery key for this advertised endpoint.
    public let id: DiscoveryDeviceID
    /// Advertised service label, usually `AppName#instanceId`.
    let name: String
    public let endpoint: DiscoveredDeviceEndpoint
    /// Simulator UDID from Bonjour TXT record (nil on physical devices)
    let simulatorUDID: SimulatorUDID?
    /// Stable installation identifier from Bonjour TXT record
    let installationId: InstallationID?
    /// Human-readable device name from Bonjour TXT record
    private let advertisedDeviceName: String?
    /// Instance identifier from Bonjour TXT record (human-readable label)
    let instanceId: InsideJobInstanceID?
    /// Connection scope advertised or inferred at discovery time.
    let connectionType: ConnectionScope

    public init(id: DiscoveryDeviceID, name: String, endpoint: DiscoveredDeviceEndpoint,
                simulatorUDID: SimulatorUDID? = nil,
                installationId: InstallationID? = nil,
                displayDeviceName: String? = nil,
                instanceId: InsideJobInstanceID? = nil,
                connectionType: ConnectionScope? = nil) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.simulatorUDID = simulatorUDID
        self.installationId = installationId
        self.advertisedDeviceName = displayDeviceName
        self.instanceId = instanceId
        self.connectionType = connectionType ?? Self.inferConnectionType(
            simulatorUDID: simulatorUDID
        )
    }

    /// Parse a "host:port" string and create a device. Returns nil on invalid input.
    static func fromHostPort(
        _ value: String,
        id: DiscoveryDeviceID? = nil,
        name: String? = nil
    ) -> DiscoveredDevice? {
        guard let target = parseHostPort(from: value) else { return nil }
        let resolvedId = id ?? DiscoveryDeviceID.hostPort(host: target.host, port: target.port)
        let resolvedName = name ?? target.displayValue
        return DiscoveredDevice(
            id: resolvedId,
            name: resolvedName,
            endpoint: .hostPort(host: target.host, port: target.port)
        )
    }

    /// Convenience init for direct host:port connections (no Bonjour).
    init(host: String, port: UInt16) {
        let deviceID = DiscoveryDeviceID.hostPort(host: host, port: port)
        self.init(
            id: deviceID,
            name: deviceID.description,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    /// Parse a direct loopback connection target from a filter string.
    /// Accepts `localhost`, `127.x.x.x`, and IPv6 loopback forms with a port.
    static func directConnectTarget(from filter: String?) -> DiscoveredDevice? {
        guard let filter else { return nil }
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = parseHostPort(from: trimmed), isLoopbackHost(target.host) else {
            return nil
        }
        return DiscoveredDevice(host: target.host, port: target.port)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }

    private static func parseHostPort(from value: String) -> DiscoveryHostPortTarget? {
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("["),
           let closingBracket = value.firstIndex(of: "]"),
           let separator = value.index(closingBracket, offsetBy: 1, limitedBy: value.endIndex),
           separator < value.endIndex,
           value[separator] == ":" {
            let host = String(value[value.index(after: value.startIndex)..<closingBracket])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let portString = String(value[value.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, let port = UInt16(portString), port > 0 else { return nil }
            return DiscoveryHostPortTarget(host: host, port: port)
        }

        guard let separator = value.lastIndex(of: ":") else { return nil }
        let host = String(value[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let portString = String(value[value.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = UInt16(portString), port > 0 else { return nil }
        return DiscoveryHostPortTarget(host: host, port: port)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Only trust IP addresses, not hostnames like "localhost" (spoofable via /etc/hosts).
        // Use 127.0.0.1 or ::1 instead.
        return normalized == "::1" ||
            normalized == "0:0:0:0:0:0:0:1" ||
            normalized.hasPrefix("127.")
    }

    private static func inferConnectionType(simulatorUDID: SimulatorUDID?) -> ConnectionScope {
        if simulatorUDID != nil { return .simulator }
        return .network
    }

    /// Instance ID parsed from service name suffix (e.g., "a1b2c3d4").
    /// Service name format: "AppName#instanceId".
    var shortId: InsideJobInstanceID? {
        guard let hashIndex = name.firstIndex(of: "#") else { return nil }
        let id = String(name[name.index(after: hashIndex)...])
        return try? InsideJobInstanceID(validating: id)
    }

    /// The name portion without the instance ID suffix
    private var nameWithoutId: String {
        if let hashIndex = name.firstIndex(of: "#") {
            return String(name[..<hashIndex])
        }
        return name
    }

    /// App name extracted from service name
    var appName: String {
        nameWithoutId
    }

    /// Device name advertised through the TXT record.
    var deviceName: String {
        advertisedDeviceName ?? ""
    }

    var discoveryIdentity: DiscoveryIdentity {
        if let installationId {
            return .installation(
                appName: appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                id: installationId
            )
        }

        return .device(id)
    }

    var resolutionDiagnosticLabel: String {
        guard !deviceName.isEmpty else { return name }
        return "\(name) (\(deviceName))"
    }

    func matches(resolutionQuery query: DiscoveryResolutionQuery) -> Bool {
        let nameMatches = [name, appName, deviceName]
            .contains { Self.label($0, matches: query) }

        let identifierMatches = [
            shortId?.description,
            installationId?.description,
            instanceId?.description,
            simulatorUDID?.description,
            id.description,
        ]
            .contains { Self.identifier($0, matches: query) }

        return nameMatches || identifierMatches
    }

    private static func label(_ value: String, matches query: DiscoveryResolutionQuery) -> Bool {
        value.lowercased().contains(query.normalizedValue)
    }

    private static func identifier(_ value: String?, matches query: DiscoveryResolutionQuery) -> Bool {
        guard let value else { return false }
        let normalizedValue = value.lowercased()
        return normalizedValue == query.normalizedValue || normalizedValue.hasPrefix(query.normalizedValue)
    }

    /// Compute display text with disambiguation when multiple discovered
    /// devices advertise the same app label.
    func displayName(among devices: [DiscoveredDevice]) -> String {
        let app = appName
        let deviceSuffix = deviceName.isEmpty ? "" : " (\(deviceName))"
        let sameAppDevices = devices.filter { $0.appName == app }

        guard sameAppDevices.count > 1 else { return app }

        let sameAppAndDevice = sameAppDevices.filter { $0.deviceName == deviceName }
        if sameAppAndDevice.count > 1, let shortId {
            return "\(app)\(deviceSuffix) [\(shortId)]"
        }
        return "\(app)\(deviceSuffix)"
    }
}
