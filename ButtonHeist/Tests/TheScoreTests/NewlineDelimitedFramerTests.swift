import Foundation
import XCTest
@testable import TheScore

final class NewlineDelimitedFramerTests: XCTestCase {
    func testFragmentedFrameIsEmittedOnlyAfterDelimiterArrives() throws {
        var framer = NewlineDelimitedFramer(maxPendingBytes: 100)

        XCTAssertEqual(try framer.append(Data("fir".utf8)), [])
        XCTAssertEqual(utf8String(framer.pendingData), "fir")

        XCTAssertEqual(try framer.append(Data("st\nsec".utf8)).map(utf8String), ["first"])
        XCTAssertEqual(utf8String(framer.pendingData), "sec")
    }

    func testOneAppendReturnsEveryCompleteFrameInOrder() throws {
        var framer = NewlineDelimitedFramer(maxPendingBytes: 100)

        let frames = try framer.append(Data("first\nsecond\nthird\n".utf8))

        XCTAssertEqual(frames.map(utf8String), ["first", "second", "third"])
        XCTAssertEqual(framer.pendingData, Data())
    }

    func testEmptyFramesAreIgnored() throws {
        var framer = NewlineDelimitedFramer(maxPendingBytes: 100)

        let frames = try framer.append(Data("\n\nbody\n\n".utf8))

        XCTAssertEqual(frames.map(utf8String), ["body"])
        XCTAssertEqual(framer.pendingData, Data())
    }

    func testAppendRetainsOnlySuffixAfterFinalDelimiter() throws {
        var framer = NewlineDelimitedFramer(maxPendingBytes: 100)

        XCTAssertEqual(try framer.append(Data("first\nsecond\npartial".utf8)).map(utf8String), ["first", "second"])
        XCTAssertEqual(utf8String(framer.pendingData), "partial")

        XCTAssertEqual(try framer.append(Data()).map(utf8String), [])
        XCTAssertEqual(utf8String(framer.pendingData), "partial")
    }

    func testOversizedAppendIsRejectedWithoutChangingPendingData() throws {
        var framer = NewlineDelimitedFramer(maxPendingBytes: 10)
        _ = try framer.append(Data("partial".utf8))

        XCTAssertThrowsError(try framer.append(Data("more".utf8))) { error in
            XCTAssertEqual(
                error as? NewlineDelimitedFramer.Violation,
                .pendingBytesExceeded(observed: 11, maximum: 10)
            )
            XCTAssertEqual(
                error.localizedDescription,
                "received frame buffer exceeded 10 bytes (11 bytes)"
            )
        }
        XCTAssertEqual(framer.pendingData, Data("partial".utf8))
    }

    private func utf8String(_ data: Data) -> String {
        guard let string = String(bytes: data, encoding: .utf8) else {
            XCTFail("Expected UTF-8 data")
            return ""
        }
        return string
    }
}
