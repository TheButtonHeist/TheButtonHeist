import Foundation
import ThePlans
import TheScore

/// Typed client environment projection used by configuration resolution.
public struct ButtonHeistEnvironment: Equatable, Sendable {
    public static let empty = ButtonHeistEnvironment()
    public static var current: ButtonHeistEnvironment {
        ButtonHeistEnvironment(rawValues: ProcessInfo.processInfo.environment)
    }

    private let values: [EnvironmentKey: String]

    public init(
        device: String? = nil,
        token: String? = nil,
        driverID: String? = nil,
        sessionTimeout: String? = nil,
        connectionTimeout: String? = nil
    ) {
        var values: [EnvironmentKey: String] = [:]
        values[.buttonheistDevice] = device
        values[.buttonheistToken] = token
        values[.buttonheistDriverId] = driverID
        values[.buttonheistSessionTimeout] = sessionTimeout
        values[.buttonheistConnectionTimeout] = connectionTimeout
        self.values = values
    }

    fileprivate init(rawValues: [String: String]) {
        self.values = Dictionary(uniqueKeysWithValues: [
            EnvironmentKey.buttonheistDevice,
            .buttonheistToken,
            .buttonheistDriverId,
            .buttonheistSessionTimeout,
            .buttonheistConnectionTimeout,
        ].compactMap { key in
            rawValues[key.rawValue].map { (key, $0) }
        })
    }

    var device: String? {
        values[.buttonheistDevice]
    }

    var token: String? {
        values[.buttonheistToken]
    }

    var driverID: String? {
        values[.buttonheistDriverId]
    }

    var sessionTimeout: String? {
        values[.buttonheistSessionTimeout]
    }

    var connectionTimeout: String? {
        values[.buttonheistConnectionTimeout]
    }
}

/// Typed timeout-configuration diagnostic emitted before a transport client is created.
public struct EnvironmentTimeoutConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Source: Sendable, Equatable {
        case explicit(Timeout)
        case environment(Timeout)
    }

    public enum Timeout: String, Sendable, Equatable {
        case session
        case connection
    }

    public let source: Source
    public let observed: String

    public var description: String {
        let timeout = switch source {
        case .explicit(let timeout), .environment(let timeout):
            timeout
        }
        let expected = switch timeout {
        case .session:
            "0 to disable it or a finite number greater than 0"
        case .connection:
            "a finite number greater than 0"
        }
        return "\(timeout.rawValue) timeout must be \(expected) (observed \(observed))"
    }
}

public enum SessionIdleTimeout: Sendable, Equatable {
    case disabled
    case after(HeistTimeout)

    public var seconds: TimeInterval? {
        switch self {
        case .disabled:
            nil
        case .after(let timeout):
            timeout.seconds
        }
    }
}

/// Resolved configuration from environment variables, config files, and explicit overrides.
/// Use `resolve()` to build this from the current environment, then access `.fenceConfiguration`
/// to create a `TheFence`.
public struct EnvironmentConfig: Sendable {
    let connectionTarget: DeviceResolutionTarget
    let token: SessionAuthToken?
    let driverID: DriverID?
    public let sessionTimeout: SessionIdleTimeout
    let connectionTimeout: TimeInterval
    let fileConfig: ButtonHeistFileConfig?
    let autoReconnect: Bool

    public var hasConnectionTarget: Bool { !connectionTarget.isAutomatic }

    /// Build a `TheFence.Configuration` from this resolved config.
    public var fenceConfiguration: TheFence.Configuration {
        .init(
            connectionTarget: connectionTarget,
            connectionTimeout: connectionTimeout,
            token: token,
            driverID: driverID,
            autoReconnect: autoReconnect,
            fileConfig: fileConfig
        )
    }

    /// Resolve configuration with full precedence:
    /// 1. Explicit parameters (from CLI flags, etc.) — highest priority
    /// 2. Environment variables (`BUTTONHEIST_DEVICE`, `BUTTONHEIST_TOKEN`, etc.)
    /// 3. Config file (`.buttonheist.json` or `~/.config/buttonheist/config.json`)
    /// 4. Built-in defaults — lowest priority
    public static func resolve(
        deviceFilter: String? = nil,
        token: String? = nil,
        sessionTimeout: TimeInterval? = nil,
        connectionTimeout: TimeInterval? = nil,
        autoReconnect: Bool = true,
        configPath: String? = nil,
        environment: ButtonHeistEnvironment = .current
    ) throws -> EnvironmentConfig {
        let fileConfig = if let configPath {
            try TargetConfigResolver.loadConfig(from: configPath)
        } else {
            try TargetConfigResolver.loadConfig(searchPaths: TargetConfigResolver.searchPaths)
        }
        return try resolve(
            deviceFilter: deviceFilter,
            token: token,
            sessionTimeout: sessionTimeout,
            connectionTimeout: connectionTimeout,
            autoReconnect: autoReconnect,
            fileConfig: fileConfig,
            environment: environment
        )
    }

    static func resolve(
        deviceFilter: String?,
        token: String?,
        sessionTimeout: TimeInterval?,
        connectionTimeout: TimeInterval?,
        autoReconnect: Bool,
        fileConfig: ButtonHeistFileConfig?,
        environment: ButtonHeistEnvironment
    ) throws -> EnvironmentConfig {

        let envToken = environment.token
        let requestedDevice = deviceFilter ?? environment.device
        let defaultTargetName = fileConfig?.defaultTarget
        let configTarget = defaultTargetName.flatMap { fileConfig?.targets[$0] }

        let connectionTarget: DeviceResolutionTarget
        let resolvedToken: String?
        if let requestedDevice {
            connectionTarget = DeviceResolutionTarget(filter: requestedDevice)
            resolvedToken = token ?? envToken
        } else if let defaultTargetName, let configTarget {
            connectionTarget = DeviceResolutionTarget(config: configTarget, named: defaultTargetName)
            resolvedToken = token ?? envToken ?? configTarget.token
        } else {
            connectionTarget = DeviceResolutionTarget(filter: nil)
            resolvedToken = token ?? envToken
        }

        let resolvedSessionTimeoutSeconds = try TransportTimeout.resolve(
            explicit: sessionTimeout,
            environment: environment.sessionTimeout,
            defaultValue: 60,
            kind: .session,
            permitsZero: true
        )
        let resolvedSessionTimeout: SessionIdleTimeout = if resolvedSessionTimeoutSeconds == 0 {
            .disabled
        } else {
            .after(try HeistTimeout(validatingSeconds: resolvedSessionTimeoutSeconds))
        }

        let resolvedConnectionTimeout = try TransportTimeout.resolve(
            explicit: connectionTimeout,
            environment: environment.connectionTimeout,
            defaultValue: 30,
            kind: .connection,
            permitsZero: false
        )

        return EnvironmentConfig(
            connectionTarget: connectionTarget,
            token: try resolvedToken.map(SessionAuthToken.init(validating:)),
            driverID: try environment.driverID.map(DriverID.init(validating:)),
            sessionTimeout: resolvedSessionTimeout,
            connectionTimeout: resolvedConnectionTimeout,
            fileConfig: fileConfig,
            autoReconnect: autoReconnect
        )
    }
}

private enum TransportTimeout {
    static func resolve(
        explicit: TimeInterval?,
        environment: String?,
        defaultValue: TimeInterval,
        kind: EnvironmentTimeoutConfigurationError.Timeout,
        permitsZero: Bool
    ) throws -> TimeInterval {
        if let explicit {
            return try validated(
                explicit,
                source: .explicit(kind),
                observed: String(explicit),
                permitsZero: permitsZero
            )
        }
        if let environment {
            guard let parsed = Double(environment) else {
                throw EnvironmentTimeoutConfigurationError(
                    source: .environment(kind),
                    observed: environment
                )
            }
            return try validated(
                parsed,
                source: .environment(kind),
                observed: environment,
                permitsZero: permitsZero
            )
        }
        return defaultValue
    }

    private static func validated(
        _ value: TimeInterval,
        source: EnvironmentTimeoutConfigurationError.Source,
        observed: String,
        permitsZero: Bool
    ) throws -> TimeInterval {
        guard value.isFinite, value > 0 || permitsZero && value == 0 else {
            throw EnvironmentTimeoutConfigurationError(source: source, observed: observed)
        }
        return value
    }
}
