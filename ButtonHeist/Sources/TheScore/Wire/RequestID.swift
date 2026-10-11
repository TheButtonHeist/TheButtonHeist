import Foundation

/// UUID identity used to correlate one wire request with its response.
public struct RequestID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(validating value: String) throws {
        guard let uuid = UUID(uuidString: value) else {
            throw ValidationError.invalidUUID
        }
        self.init(uuid)
    }

    public var description: String { rawValue.uuidString }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(validating: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "request identifier must be a UUID"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case invalidUUID

        public var errorDescription: String? {
            "request identifier must be a UUID"
        }
    }
}
