import Foundation

/// Pure newline-delimited framing state shared by both socket directions.
///
/// Complete empty frames are ignored because an empty payload is not a Button Heist
/// wire message. The retained bytes are always the single suffix after the last
/// delimiter observed so far.
package struct NewlineDelimitedFramer: Equatable, Sendable {
    package enum Violation: Error, Equatable, LocalizedError, Sendable {
        case pendingBytesExceeded(observed: Int, maximum: Int)

        package var errorDescription: String? {
            switch self {
            case let .pendingBytesExceeded(observed, maximum):
                return "received frame buffer exceeded \(maximum) bytes (\(observed) bytes)"
            }
        }
    }

    private let maxPendingBytes: Int
    package private(set) var pendingData = Data()

    package init(maxPendingBytes: Int) {
        precondition(maxPendingBytes > 0)
        self.maxPendingBytes = maxPendingBytes
    }

    package mutating func append(_ content: Data) throws -> [Data] {
        guard !content.isEmpty else { return [] }

        let (observed, overflowed) = pendingData.count.addingReportingOverflow(content.count)
        guard !overflowed, observed <= maxPendingBytes else {
            throw Violation.pendingBytesExceeded(
                observed: overflowed ? .max : observed,
                maximum: maxPendingBytes
            )
        }

        var frames: [Data] = []
        var sawDelimiter = false
        var segmentStart = 0

        for index in content.indices where content[index] == WireFrameLimits.newlineDelimiterByte {
            var frame = sawDelimiter ? Data() : pendingData
            if index > segmentStart {
                frame.append(contentsOf: content[segmentStart..<index])
            }
            if !frame.isEmpty {
                frames.append(frame)
            }
            segmentStart = index + 1
            sawDelimiter = true
        }

        if sawDelimiter {
            pendingData = Data(content.suffix(from: segmentStart))
        } else {
            pendingData.append(content)
        }

        return frames
    }
}
