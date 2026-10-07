import Foundation
import ThePlans
import TheScore

/// A named connection target: device address + optional auth token.
public struct TargetConfig: Codable, Sendable, Equatable {
    public let device: String
    public let token: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case device
        case token
    }

    public init(device: String, token: String? = nil) {
        self.device = device
        self.token = token
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: CodingKeys.self, typeName: "config")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try container.decode(String.self, forKey: .device)
        token = try container.decodeIfPresent(String.self, forKey: .token)
    }
}

/// Typed selector for a named target in `.buttonheist.json`.
public struct TargetName: RawRepresentable, Hashable, Sendable, Equatable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String {
        rawValue
    }
}

/// Config file schema for `.buttonheist.json` or `~/.config/buttonheist/config.json`.
/// Contains named targets and an optional default.
struct ButtonHeistFileConfig: Codable, Sendable, Equatable {
    let targets: [TargetName: TargetConfig]
    let defaultTarget: TargetName?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case targets
        case defaultTarget = "default"
    }

    init(targets: [TargetName: TargetConfig], defaultTarget: TargetName? = nil) {
        self.targets = targets
        self.defaultTarget = defaultTarget
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: CodingKeys.self, typeName: "config")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let targetContainer = try container.nestedContainer(keyedBy: TargetNameCodingKey.self, forKey: .targets)
        targets = try Dictionary(uniqueKeysWithValues: targetContainer.allKeys.map { key in
            (
                TargetName(rawValue: key.stringValue),
                try targetContainer.decode(TargetConfig.self, forKey: key)
            )
        })
        defaultTarget = try container.decodeIfPresent(String.self, forKey: .defaultTarget)
            .map(TargetName.init(rawValue:))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var targetContainer = container.nestedContainer(keyedBy: TargetNameCodingKey.self, forKey: .targets)
        for (name, target) in targets.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try targetContainer.encode(target, forKey: TargetNameCodingKey(stringValue: name.rawValue))
        }
        try container.encodeIfPresent(defaultTarget, forKey: .defaultTarget)
    }
}

private struct TargetNameCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

/// Diagnostic failure produced when a config path cannot be loaded.
public struct TargetConfigLoadError: Error, LocalizedError, Sendable {
    /// High-level loading phase that failed.
    public enum Kind: String, Sendable {
        case readFailed = "read_failed"
        case decodeFailed = "decode_failed"

        var failureCode: KnownFailureCode {
            switch self {
            case .readFailed:
                return .configReadFailed
            case .decodeFailed:
                return .configDecodeFailed
            }
        }

        /// Stable diagnostic error code for this load failure kind.
        public var errorCode: String {
            failureCode.rawValue
        }
    }

    /// Expanded filesystem path that failed to load.
    public let path: String
    /// Load failure kind used for diagnostics and machine-readable error codes.
    public let kind: Kind
    /// Human-readable description of the underlying file or JSON error.
    public let underlyingDescription: String

    /// User-facing diagnostic message.
    public var errorDescription: String? {
        switch kind {
        case .readFailed:
            return "Failed to read config at \(path): \(underlyingDescription)"
        case .decodeFailed:
            return "Failed to decode config at \(path): \(underlyingDescription)"
        }
    }

    /// Machine-readable failure metadata for formatted diagnostics.
    public var failureDetails: FailureDetails {
        FailureDetails(code: kind.failureCode)
    }
}

/// Resolves connection parameters from config files and environment variables.
/// Resolution order: env vars > config file targets.
enum TargetConfigResolver {

    /// Standard search paths for the config file, in priority order.
    static let searchPaths: [String] = [
        ".buttonheist.json",
        "~/.config/buttonheist/config.json",
    ]

    /// Load and parse the first config file found in the provided default search paths.
    static func loadConfig(searchPaths paths: [String]) throws -> ButtonHeistFileConfig? {
        for path in paths {
            let url = configURL(for: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            return try readConfig(at: url)
        }
        return nil
    }

    /// Load and parse a user-provided config path.
    static func loadConfig(from explicitPath: String) throws -> ButtonHeistFileConfig {
        let url = configURL(for: explicitPath)
        return try readConfig(at: url)
    }

    private static func readConfig(at url: URL) throws -> ButtonHeistFileConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TargetConfigLoadError(
                path: url.path,
                kind: .readFailed,
                underlyingDescription: error.localizedDescription
            )
        }

        do {
            return try JSONDecoder().decode(ButtonHeistFileConfig.self, from: data)
        } catch {
            throw TargetConfigLoadError(
                path: url.path,
                kind: .decodeFailed,
                underlyingDescription: error.localizedDescription
            )
        }
    }

    /// Resolve connection parameters with full precedence:
    /// 1. Env vars (BUTTONHEIST_DEVICE / BUTTONHEIST_TOKEN) override everything
    /// 2. Named target from config file
    /// 3. Default target from config file
    static func resolveEffective(
        targetName: TargetName? = nil,
        config: ButtonHeistFileConfig? = nil,
        environment: ButtonHeistEnvironment = .current
    ) -> TargetConfig? {
        let envDevice = environment.device
        let envToken = environment.token

        if let envDevice {
            return TargetConfig(device: envDevice, token: envToken)
        }

        guard let config else { return nil }

        let name = targetName ?? config.defaultTarget
        guard let name else { return nil }

        guard var target = config.targets[name] else { return nil }

        if let envToken {
            target = TargetConfig(device: target.device, token: envToken)
        }
        return target
    }

    private static func configURL(for path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded)
    }
}
