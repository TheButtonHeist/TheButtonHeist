import Foundation
@testable import TheScore

package extension RequestID {
    /// Stable UUID identity for readable test scenarios.
    static func fixture(_ name: String) -> Self {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in name.utf8.enumerated() {
            let slot = index % bytes.count
            bytes[slot] = bytes[slot] &* 31 &+ byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return Self(UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )))
    }
}

package func testResponseEnvelopeData(
    _ message: ServerMessage,
    buttonHeistVersion version: ButtonHeistVersion = buttonHeistVersion
) throws -> Data {
    try JSONEncoder().encode(ResponseEnvelope(
        buttonHeistVersion: version,
        message: message
    ))
}
