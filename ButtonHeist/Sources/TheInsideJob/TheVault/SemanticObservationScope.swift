#if canImport(UIKit)
#if DEBUG
import Foundation

enum SemanticObservationScope: Int, Comparable, Sendable {
    case visible
    case discovery

    static func < (lhs: SemanticObservationScope, rhs: SemanticObservationScope) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

}

@MainActor
final class SemanticObservationLease<Value> {
    let value: Value
    private weak var stream: Observation.Stream?
    private let release: @MainActor (Observation.Stream) -> Void
    private var isCancelled = false

    init(
        value: Value,
        stream: Observation.Stream,
        release: @escaping @MainActor (Observation.Stream) -> Void
    ) {
        self.value = value
        self.stream = stream
        self.release = release
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        if let stream {
            release(stream)
        }
        stream = nil
    }

    deinit {
        MainActor.assumeIsolated {
            guard !isCancelled else { return }
            if let stream {
                release(stream)
            }
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
