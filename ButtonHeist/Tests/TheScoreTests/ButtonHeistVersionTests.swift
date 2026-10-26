import Foundation
import Testing
import TheScore

struct ButtonHeistVersionTests {
    @Test(arguments: ["0.7.1", "0.7.0-a81d93c047e2", "0.7.0-0123456789ab", "0.7.0-abcdefabcdef"])
    func `release and development versions round trip exactly`(value: String) throws {
        let version = try ButtonHeistVersion(validating: value)
        let data = try JSONEncoder().encode(version)
        #expect(try JSONDecoder().decode(ButtonHeistVersion.self, from: data) == version)
        #expect(version.description == value)
    }

    @Test(arguments: [
        "0.7.0-", "0.7.0-abc", "0.7.0-A81D93C047E2", "0.7.0-a81d93c047eZ",
        "0.7.0-a81d93c047e2-extra", "0.7.0+a81d93c047e2", "0.07.0-a81d93c047e2",
        "0.7.0-a81d93c047e20", "0.7.0-a81d93c047é", "0.7.0-a81d93c04８", "０.7.0", "0.٧.0",
    ])
    func `malformed development versions fail at decoding`(value: String) throws {
        let data = try JSONEncoder().encode(value)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ButtonHeistVersion.self, from: data)
        }
    }

    @Test func `contract fingerprints remain part of exact version identity`() throws {
        let release = try ButtonHeistVersion(validating: "0.7.0")
        let first = try ButtonHeistVersion(validating: "0.7.0-a81d93c047e2")
        let second = try ButtonHeistVersion(validating: "0.7.0-b81d93c047e2")
        #expect(first != release)
        #expect(first != second)
    }
}
