#if canImport(UIKit)
#if DEBUG

/// Subscription scope and active cadence demand for semantic observation.
struct SemanticObservationScopePressure {
    private var nextSubscriptionID: UInt64 = 0
    private var subscriptions: [UInt64: SemanticObservationScope] = [:]

    private(set) var activeDemandCount = 0

    var hasActiveDemand: Bool {
        activeDemandCount > 0
    }

    var demandedObservationScope: SemanticObservationScope? {
        subscriptions.values.max()
            ?? (hasActiveDemand ? .visible : nil)
    }

    mutating func addSubscription(scope: SemanticObservationScope) -> UInt64 {
        let id = nextSubscriptionID
        nextSubscriptionID += 1
        subscriptions[id] = scope
        return id
    }

    mutating func removeSubscription(_ id: UInt64) {
        subscriptions[id] = nil
    }

    mutating func addActiveDemand() {
        activeDemandCount += 1
    }

    mutating func removeActiveDemand() {
        precondition(activeDemandCount > 0, "Active observation demand count underflowed")
        activeDemandCount -= 1
    }

}

#endif // DEBUG
#endif // canImport(UIKit)
