import Foundation
import XCTest

func assertRoundTrip<T: Codable & Equatable>(
    _ value: T,
    as type: T.Type = T.self,
    encoder: JSONEncoder = JSONEncoder(),
    decoder: JSONDecoder = JSONDecoder(),
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    let data = try encoder.encode(value)
    let decoded = try decoder.decode(type, from: data)
    XCTAssertEqual(decoded, value, file: file, line: line)
    return decoded
}
