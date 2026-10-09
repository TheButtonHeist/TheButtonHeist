import ThePlans
import Foundation

// MARK: - Wire Protocol Constants

/// Bonjour service type for discovery
public let buttonHeistServiceType = "_buttonheist._tcp"

/// Canonical product version shared by CLI, MCP, and the iOS server.
///
/// SemVer (`MAJOR.MINOR.PATCH`). There is no separate "wire protocol version"
/// — the handshake requires exact equality between
/// the server's and the client's `buttonHeistVersion`. Update this constant
/// only via `scripts/release.sh`. See `docs/WIRE-PROTOCOL.md` and
/// `VERSIONING.md` in bh-infra.
public let buttonHeistVersion: ButtonHeistVersion = "0.6.38"

/// Shared socket wire-framing limits.
public enum WireFrameLimits {
    /// JSON envelopes are newline-delimited on the socket.
    public static let newlineDelimiterByte: UInt8 = 0x0A
    public static let receiveChunkBytes: Int = 65_536

    /// Client-to-server frames preserve the server receive framer's current 10 MB cap.
    public static let clientToServerMaxBufferedBytes: Int = 10_000_000
    /// Server-to-client frames preserve the client's current 64 MiB buffer cap,
    /// intentionally larger than the client-to-server cap until the framer migration.
    public static let serverToClientMaxBufferedBytes: Int = 64 * 1024 * 1024
    /// Server-to-client writes preserve the current per-client pending-byte cap.
    public static let serverToClientMaxPendingSendBytes: Int = 20_000_000
}

/// Direction-specific JSON `type` discriminator shared by client and server wire enums.
public protocol DirectionalWireMessageType: RawRepresentable, Codable, CaseIterable, Sendable, CustomStringConvertible where RawValue == String {
    static var directionName: String { get }
}

extension DirectionalWireMessageType {
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let type = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported \(Self.directionName) wire message type: \(rawValue)"
            )
        }
        self = type
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Explicit client-to-server wire message discriminator used at JSON boundaries.
public enum ClientWireMessageType: String, DirectionalWireMessageType {
    public static let directionName = "client"

    case clientHello, authenticate, requestInterface, ping, mainThreadProbe, status
    case getPasteboard
    case getNotifications
    case requestScreen
    case runtimeAction
    case heistPlan
}

/// Explicit server-to-client wire message discriminator used at JSON boundaries.
public enum ServerWireMessageType: String, DirectionalWireMessageType {
    public static let directionName = "server"

    case serverHello, protocolMismatch, authRequired, info, interface
    case pong, mainThreadProbe, status, error, actionResult, heistResult, screen, sessionLocked
    case notifications
}

// MARK: - TXT Record Keys

/// Bonjour TXT record keys used for service advertisement and discovery.
public enum TXTRecordKey: String, Sendable {
    case simUDID = "simudid"
    case installationId = "installationid"
    case deviceName = "devicename"
    case instanceId = "instanceid"
    case transport = "transport"
}

extension TXTRecordKey: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - Environment Keys

/// Centralized environment variable names used across client and server.
public enum EnvironmentKey: String, Sendable {
    // Client
    case buttonheistDevice = "BUTTONHEIST_DEVICE"
    case buttonheistToken = "BUTTONHEIST_TOKEN"
    case buttonheistDriverId = "BUTTONHEIST_DRIVER_ID"
    case buttonheistResultsDir = "BUTTONHEIST_RESULTS_DIR"
    case buttonheistResultsMode = "BUTTONHEIST_RESULTS_MODE"
    case buttonheistSessionTimeout = "BUTTONHEIST_SESSION_TIMEOUT"
    case buttonheistConnectionTimeout = "BUTTONHEIST_CONNECTION_TIMEOUT"
    // Server
    case insideJobToken = "INSIDEJOB_TOKEN"
    case insideJobPort = "INSIDEJOB_PORT"
    case insideJobDisable = "INSIDEJOB_DISABLE"
    case insideJobId = "INSIDEJOB_ID"
    case insideJobScope = "INSIDEJOB_SCOPE"
    case insideJobSessionTimeout = "INSIDEJOB_SESSION_TIMEOUT"
    case insideJobFingerprints = "INSIDEJOB_FINGERPRINTS"
    case buttonheistFailureEvidence = "BUTTONHEIST_FAILURE_EVIDENCE"
}

extension EnvironmentKey: CustomStringConvertible {
    public var description: String { rawValue }
}

extension EnvironmentKey {
    public var value: String? { ProcessInfo.processInfo.environment[rawValue] }
}

// MARK: - DecodingError Helpers

extension DecodingError {
    /// Construct a `.keyNotFound` error for a missing wire message payload.
    static func missingPayload<T: DirectionalWireMessageType>(key: CodingKey, type: T, codingPath: [CodingKey] = []) -> DecodingError {
        .keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Missing payload for message type \(type.rawValue)"))
    }
}
