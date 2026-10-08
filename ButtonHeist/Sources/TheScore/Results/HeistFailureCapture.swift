import ThePlans

/// Terminal screenshot evidence captured after heist execution has failed.
package enum HeistFailureCapture: Codable, Sendable, Equatable {
    case captured(ScreenPayload)
    case unavailable(kind: ActionFailure.Kind, message: String?)

    private enum Kind: String, Codable {
        case captured
        case unavailable
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case payload
        case failureKind
        case message
    }

    package init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: CodingKeys.self, typeName: "heist failure capture")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .captured:
            try container.rejectIncompatibleFields(
                allowing: [.kind, .payload],
                typeName: "captured heist failure capture"
            )
            self = .captured(try container.decode(ScreenPayload.self, forKey: .payload))
        case .unavailable:
            try container.rejectIncompatibleFields(
                allowing: [.kind, .failureKind, .message],
                typeName: "unavailable heist failure capture"
            )
            self = .unavailable(
                kind: try container.decode(ActionFailure.Kind.self, forKey: .failureKind),
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .captured(let payload):
            try container.encode(Kind.captured, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .unavailable(let kind, let message):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(kind, forKey: .failureKind)
            try container.encodeIfPresent(message, forKey: .message)
        }
    }

    package var payload: ScreenPayload? {
        guard case .captured(let payload) = self else { return nil }
        return payload
    }

    package var message: String? {
        guard case .unavailable(_, let message) = self else { return nil }
        return message
    }

    package var failureKind: ActionFailure.Kind? {
        guard case .unavailable(let kind, _) = self else { return nil }
        return kind
    }
}
