import ThePlans
import Foundation
import AccessibilitySnapshotModel

// MARK: - Response Envelope

/// Wraps a server message with the echoed requestId for response correlation.
/// Push broadcasts (subscription updates) use requestId = nil.
public struct ResponseEnvelope: Codable, Sendable {
    /// Server's `buttonHeistVersion`. The handshake requires exact equality
    /// with the client's `buttonHeistVersion` — there is no separate wire
    /// protocol version.
    public let buttonHeistVersion: ButtonHeistVersion
    public let requestId: RequestID?
    public let message: ServerMessage

    public init(
        buttonHeistVersion: ButtonHeistVersion = TheScore.buttonHeistVersion,
        requestId: RequestID? = nil,
        message: ServerMessage
    ) {
        self.buttonHeistVersion = buttonHeistVersion
        self.requestId = requestId
        self.message = message
    }

    /// Encode this envelope to JSON data. Returns nil on encode failure.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

// MARK: - Server -> Client Messages

/// Messages sent from the Inside Job server to connected clients.
public enum ServerMessage: Codable, Sendable {
    /// Version-negotiation hello sent immediately on connection.
    case serverHello

    /// `buttonHeistVersion` mismatch between server and client.
    case protocolMismatch(ProtocolMismatchPayload)

    /// Server requires authentication (sent after successful hello handshake)
    case authRequired

    /// Server info on connection
    case info(ServerInfo)

    /// Interface (UI element hierarchy) response/update
    case interface(Interface)

    /// Pong response with cheap static app/server health facts.
    case pong(PongPayload)

    /// Result of an off-main main-thread responsiveness probe.
    case mainThreadProbe(MainThreadProbeResponse)

    /// Server-side error broadcast. `ServerError.kind` tags the category
    /// (auth failure, general) so clients can route without
    /// pattern-matching on message text.
    case error(ServerError)

    /// Result of an action command
    case actionResult(ActionResult)

    /// Complete result of a heist plan execution.
    case heistResult(HeistResult)

    /// Screen capture response with PNG data
    case screen(ScreenPayload)

    /// Canonical accessibility notifications retained by observation history.
    case notifications([Observation.Notification])

    /// Session is locked by another driver (sent before disconnect)
    case sessionLocked(SessionLockedPayload)

    /// Lightweight server health + identity snapshot.
    /// Returned in response to ClientMessage.status without acquiring a session.
    case status(StatusPayload)
}
